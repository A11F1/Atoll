/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 * Portions adapted from Vibe Notch (Claude Island) by Farouq Aldori,
 * licensed under the Apache License, Version 2.0. See NOTICE.
 */

import Foundation

/// Adds and removes Atoll's hook in `~/.claude/settings.json`.
///
/// Only entries whose command contains `ClaudeHookScript.marker` are ever
/// added or removed; everything else in the file is kept. The original file is
/// copied to `settings.json.atoll-backup` before the first change.
enum ClaudeHookInstaller {
    enum InstallerError: LocalizedError {
        case unreadableSettings(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadableSettings(let path):
                return "Could not read \(path) as JSON, so it was left unchanged."
            case .writeFailed(let path):
                return "Could not write \(path)."
            }
        }
    }

    enum Status: Equatable {
        case notInstalled
        case installed
    }

    static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }

    static var backupURL: URL { claudeDir.appendingPathComponent("settings.json.atoll-backup") }

    static var scriptURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Atoll", isDirectory: true)
            .appendingPathComponent(ClaudeHookScript.fileName)
    }

    /// Shell command registered for every event.
    private static var command: String {
        "/usr/bin/python3 '\(scriptURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    // MARK: - Status

    static func status() -> Status {
        guard let root = try? readSettings(),
              let hooks = root["hooks"] as? [String: Any] else { return .notInstalled }
        let found = hooks.values.contains { value in
            guard let groups = value as? [[String: Any]] else { return false }
            return groups.contains(where: groupContainsMarker)
        }
        return found ? .installed : .notInstalled
    }

    // MARK: - Install / uninstall

    static func install() throws {
        try writeScript()

        var root = try readSettings() ?? [:]
        try backupOnce()

        var hooks = stripOurHooks(from: root["hooks"] as? [String: Any] ?? [:])
        for (event, groups) in eventGroups(for: detectClaudeCodeVersion()) {
            let existing = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = existing + groups
        }
        root["hooks"] = hooks
        try writeSettings(root)
    }

    static func uninstall() throws {
        if var root = try readSettings(), let hooks = root["hooks"] as? [String: Any] {
            let cleaned = stripOurHooks(from: hooks)
            if cleaned.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = cleaned
            }
            try writeSettings(root)
        }
        try? FileManager.default.removeItem(at: scriptURL)
    }

    /// Rewrites the script on launch so it stays in step with the app version.
    static func refreshScriptIfInstalled() {
        guard status() == .installed else { return }
        try? writeScript()
    }

    // MARK: - Events

    /// Claude Code rejects unknown hook names, so newer events are only added
    /// when the installed version is known to support them.
    private static func eventGroups(for version: ClaudeCodeVersion?) -> [(String, [[String: Any]])] {
        let plain: [[String: Any]] = [["hooks": [entry()]]]
        let anyTool: [[String: Any]] = [["matcher": "*", "hooks": [entry()]]]
        // The hook waits up to 290 s for an answer from the notch.
        let permission: [[String: Any]] = [["matcher": "*", "hooks": [entry(timeout: 300)]]]
        let compact: [[String: Any]] = [
            ["matcher": "auto", "hooks": [entry()]],
            ["matcher": "manual", "hooks": [entry()]]
        ]

        var events: [(String, [[String: Any]])] = [
            ("SessionStart", plain),
            ("SessionEnd", plain),
            ("UserPromptSubmit", plain),
            ("PreToolUse", anyTool),
            ("PostToolUse", anyTool),
            ("PermissionRequest", permission),
            ("Notification", anyTool),
            ("Stop", plain),
            ("SubagentStop", plain),
            ("PreCompact", compact)
        ]
        guard let version else { return events }
        if version >= ClaudeCodeVersion(2, 0, 0) { events.append(("PostToolUseFailure", anyTool)) }
        if version >= ClaudeCodeVersion(2, 1, 76) { events.append(("PostCompact", compact)) }
        if version >= ClaudeCodeVersion(2, 1, 78) { events.append(("StopFailure", plain)) }
        if version >= ClaudeCodeVersion(2, 1, 88) { events.append(("PermissionDenied", anyTool)) }
        return events
    }

    private static func entry(timeout: Int? = nil) -> [String: Any] {
        var entry: [String: Any] = ["type": "command", "command": command]
        if let timeout { entry["timeout"] = timeout }
        return entry
    }

    // MARK: - Helpers

    private static func groupContainsMarker(_ group: [String: Any]) -> Bool {
        guard let inner = group["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String)?.contains(ClaudeHookScript.marker) == true }
    }

    /// Removes our commands from every event; drops groups and events left empty.
    private static func stripOurHooks(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = inner.filter {
                    ($0["command"] as? String)?.contains(ClaudeHookScript.marker) != true
                }
                if remaining.isEmpty { return nil }
                var copy = group
                copy["hooks"] = remaining
                return copy
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    /// Returns nil when the file does not exist; throws when it exists but is
    /// not a JSON object, so we never overwrite a file we could not parse.
    private static func readSettings() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        guard let data = try? Data(contentsOf: settingsURL) else {
            throw InstallerError.unreadableSettings(settingsURL.path)
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallerError.unreadableSettings(settingsURL.path)
        }
        return object
    }

    private static func writeSettings(_ root: [String: Any]) throws {
        do {
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            throw InstallerError.writeFailed(settingsURL.path)
        }
    }

    private static func backupOnce() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: backupURL.path) else { return }
        try fm.copyItem(at: settingsURL, to: backupURL)
    }

    private static func writeScript() throws {
        let dir = scriptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ClaudeHookScript.text.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    // MARK: - Claude Code version

    struct ClaudeCodeVersion: Comparable {
        let major: Int, minor: Int, patch: Int
        init(_ major: Int, _ minor: Int, _ patch: Int) {
            self.major = major; self.minor = minor; self.patch = patch
        }
        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    static func detectClaudeCodeVersion() -> ClaudeCodeVersion? {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
              let match = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        let parts = output[match].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return ClaudeCodeVersion(parts[0], parts[1], parts[2])
    }
}
