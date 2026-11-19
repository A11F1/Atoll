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

import AppKit
import Combine
import Defaults
import Foundation

enum ClaudeSessionPhase: Equatable {
    case waitingForInput
    case thinking
    case runningTool(String)
    case waitingForApproval
    case compacting

    var label: String {
        switch self {
        case .waitingForInput: return "Waiting for you"
        case .thinking: return "Thinking"
        case .runningTool(let tool): return "Running \(tool)"
        case .waitingForApproval: return "Needs approval"
        case .compacting: return "Compacting"
        }
    }

    var isWorking: Bool {
        switch self {
        case .thinking, .runningTool, .compacting: return true
        case .waitingForInput, .waitingForApproval: return false
        }
    }
}

struct ClaudePermissionRequest: Identifiable, Equatable {
    let id: UUID
    let tool: String
    let summary: String?
    let inputJSON: String?
    let suggestionsJSON: Data?
    let receivedAt: Date

    var canAlwaysAllow: Bool { ClaudeSessionManager.firstAllowSuggestion(suggestionsJSON) != nil }
}

struct ClaudeSession: Identifiable, Equatable {
    let id: String
    var cwd: String
    var pid: Int32?
    var phase: ClaudeSessionPhase = .waitingForInput
    var permissionMode: String?
    var lastPrompt: String?
    var lastMessage: String?
    var notice: String?
    var pendingPermissions: [ClaudePermissionRequest] = []
    var startedAt: Date
    var lastActivity: Date

    var projectName: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? "Claude" : name
    }

    var needsAttention: Bool { !pendingPermissions.isEmpty }

    /// The phase to show: a pending permission always wins.
    var displayPhase: ClaudeSessionPhase {
        pendingPermissions.isEmpty ? phase : .waitingForApproval
    }
}

@MainActor
final class ClaudeSessionManager: ObservableObject {
    static let shared = ClaudeSessionManager()

    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var hookStatus: ClaudeHookInstaller.Status = .notInstalled
    @Published private(set) var lastError: String?

    var needsAttention: Bool { sessions.contains { $0.needsAttention } }
    var workingCount: Int { sessions.filter { $0.displayPhase.isWorking }.count }
    var attentionCount: Int { sessions.filter { $0.needsAttention }.count }

    private let server = ClaudeHookSocketServer()
    private var store: [String: ClaudeSession] = [:]
    private var livenessTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    /// Called once at launch; follows the feature toggle from then on.
    func configure() {
        guard !started else { return }
        started = true
        hookStatus = ClaudeHookInstaller.status()
        ClaudeHookInstaller.refreshScriptIfInstalled()

        Defaults.publisher(.enableClaudeSessions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                if change.newValue { self?.startListening() } else { self?.stopListening() }
            }
            .store(in: &cancellables)
    }

    func shutdown() {
        stopListening()
    }

    private func startListening() {
        server.start(
            onEvent: { event in
                Task { @MainActor in ClaudeSessionManager.shared.handle(event) }
            },
            onClosed: { requestId in
                Task { @MainActor in ClaudeSessionManager.shared.dropPermission(requestId, reply: false) }
            }
        )
        livenessTimer?.invalidate()
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in ClaudeSessionManager.shared.pruneDeadSessions() }
        }
    }

    private func stopListening() {
        livenessTimer?.invalidate()
        livenessTimer = nil
        server.stop()
        store.removeAll()
        publish()
    }

    // MARK: - Hooks

    func installHooks() {
        do {
            try ClaudeHookInstaller.install()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        hookStatus = ClaudeHookInstaller.status()
    }

    func uninstallHooks() {
        do {
            try ClaudeHookInstaller.uninstall()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        hookStatus = ClaudeHookInstaller.status()
    }

    // MARK: - Events

    private func handle(_ event: ClaudeHookEvent) {
        let now = Date()
        var session = store[event.sessionId] ?? ClaudeSession(
            id: event.sessionId,
            cwd: event.cwd,
            pid: event.pid,
            startedAt: now,
            lastActivity: now
        )
        if !event.cwd.isEmpty { session.cwd = event.cwd }
        if let pid = event.pid { session.pid = pid }
        if let mode = event.permissionMode { session.permissionMode = mode }
        session.lastActivity = now

        switch event.event {
        case "SessionStart":
            session.phase = .waitingForInput
        case "SessionEnd":
            closeAllPermissions(of: &session)
            store.removeValue(forKey: event.sessionId)
            publish()
            return
        case "UserPromptSubmit":
            closeAllPermissions(of: &session)
            session.phase = .thinking
            session.notice = nil
            if let prompt = event.message, !prompt.isEmpty { session.lastPrompt = prompt }
        case "PreToolUse":
            session.phase = .runningTool(event.tool ?? "tool")
        case "PostToolUse", "PostToolUseFailure":
            // A tool that ran was approved somewhere, possibly in the terminal.
            closePermission(matching: event, in: &session)
            session.phase = .thinking
        case "PermissionRequest":
            if let requestId = event.requestId {
                session.pendingPermissions.append(ClaudePermissionRequest(
                    id: requestId,
                    tool: event.tool ?? "Tool",
                    summary: event.toolSummary,
                    inputJSON: event.toolInputJSON,
                    suggestionsJSON: event.permissionSuggestionsJSON,
                    receivedAt: now
                ))
                announcePermission()
            }
        case "PermissionDenied":
            session.phase = .thinking
            session.notice = event.message.map { "Blocked: \($0)" }
        case "Notification":
            if event.notificationType == "idle_prompt" {
                session.phase = .waitingForInput
            } else if let message = event.message, !message.isEmpty {
                session.notice = message
            }
        case "Stop":
            closeAllPermissions(of: &session)
            session.phase = .waitingForInput
            if let message = event.message, !message.isEmpty { session.lastMessage = message }
        case "StopFailure":
            closeAllPermissions(of: &session)
            session.phase = .waitingForInput
            session.notice = event.message.map { "Stopped: \($0)" } ?? "Stopped with an error"
        case "PreCompact":
            session.phase = .compacting
        case "PostCompact":
            session.phase = .thinking
        default:
            break
        }

        store[event.sessionId] = session
        publish()
    }

    // MARK: - Permission answers

    func approve(sessionId: String, requestId: UUID, always: Bool = false) {
        guard let request = request(sessionId, requestId) else { return }
        var decision: [String: Any] = ["behavior": "allow"]
        if always, let suggestion = Self.firstAllowSuggestion(request.suggestionsJSON) {
            decision["updatedPermissions"] = [suggestion]
        }
        send(decision, for: requestId, in: sessionId, nextPhase: .runningTool(request.tool))
    }

    func deny(sessionId: String, requestId: UUID) {
        let decision: [String: Any] = ["behavior": "deny", "message": "Denied from the Atoll notch"]
        send(decision, for: requestId, in: sessionId, nextPhase: .thinking)
    }

    /// Hands the question back to Claude Code's own prompt in the terminal.
    func answerInTerminal(sessionId: String, requestId: UUID) {
        dropPermission(requestId, reply: true)
        focusTerminal(for: sessionId)
    }

    private func send(_ decision: [String: Any], for requestId: UUID, in sessionId: String, nextPhase: ClaudeSessionPhase) {
        let reply: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision
            ]
        ]
        let data = try? JSONSerialization.data(withJSONObject: reply)
        server.respond(to: requestId, reply: data)
        guard var session = store[sessionId] else { return }
        session.pendingPermissions.removeAll { $0.id == requestId }
        if session.pendingPermissions.isEmpty { session.phase = nextPhase }
        store[sessionId] = session
        publish()
    }

    /// Removes a pending request. With `reply`, also closes the hook so Claude
    /// Code falls back to the terminal prompt.
    fileprivate func dropPermission(_ requestId: UUID, reply: Bool) {
        if reply { server.respond(to: requestId, reply: nil) }
        for (id, var session) in store where session.pendingPermissions.contains(where: { $0.id == requestId }) {
            session.pendingPermissions.removeAll { $0.id == requestId }
            store[id] = session
        }
        publish()
    }

    private func closePermission(matching event: ClaudeHookEvent, in session: inout ClaudeSession) {
        guard let index = session.pendingPermissions.firstIndex(where: {
            $0.tool == event.tool && $0.inputJSON == event.toolInputJSON
        }) else { return }
        let request = session.pendingPermissions.remove(at: index)
        server.respond(to: request.id, reply: nil)
    }

    private func closeAllPermissions(of session: inout ClaudeSession) {
        for request in session.pendingPermissions {
            server.respond(to: request.id, reply: nil)
        }
        session.pendingPermissions.removeAll()
    }

    private func request(_ sessionId: String, _ requestId: UUID) -> ClaudePermissionRequest? {
        store[sessionId]?.pendingPermissions.first { $0.id == requestId }
    }

    nonisolated static func firstAllowSuggestion(_ data: Data?) -> [String: Any]? {
        guard let data,
              let suggestions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return suggestions.first { ($0["behavior"] as? String) == "allow" }
    }

    /// When the notch is closed, point it at the sessions tab so hovering
    /// opens straight onto the approval.
    private func announcePermission() {
        guard Defaults[.enableClaudeSessions], Defaults[.showClaudeSessionsTab] else { return }
        let coordinator = DynamicIslandViewCoordinator.shared
        if coordinator.currentView != .claudeSessions {
            coordinator.currentView = .claudeSessions
        }
    }

    // MARK: - Session housekeeping

    func dismiss(sessionId: String) {
        guard var session = store[sessionId] else { return }
        closeAllPermissions(of: &session)
        store.removeValue(forKey: sessionId)
        publish()
    }

    private func pruneDeadSessions() {
        let now = Date()
        var changed = false
        for (id, var session) in store {
            let dead: Bool
            if let pid = session.pid {
                dead = kill(pid, 0) != 0 && errno == ESRCH
            } else {
                // Without a pid, forget sessions that have been quiet for a long time.
                dead = now.timeIntervalSince(session.lastActivity) > 2 * 3600
            }
            if dead {
                closeAllPermissions(of: &session)
                store.removeValue(forKey: id)
                changed = true
            }
        }
        if changed { publish() }
    }

    private func publish() {
        sessions = store.values.sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    // MARK: - Jump to terminal

    /// Brings forward the app that owns the session's process (Terminal,
    /// iTerm2, Ghostty, VS Code, …) by walking up its parent processes.
    func focusTerminal(for sessionId: String) {
        guard var pid = store[sessionId]?.pid else { return }
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                app.activate()
                return
            }
            guard let parent = Self.parentPID(of: pid), parent > 1 else { return }
            pid = parent
        }
    }

    private nonisolated static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
