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
import os.log

private let logger = os.Logger(subsystem: "com.ebullioscopic.Atoll", category: "ClaudeHooks")

/// One event sent by the hook script.
struct ClaudeHookEvent: Sendable {
    let sessionId: String
    let event: String
    let cwd: String
    let transcriptPath: String?
    let permissionMode: String?
    let pid: Int32?
    let tool: String?
    let toolUseId: String?
    /// `tool_input` re-encoded as JSON (sorted keys), used for display and matching.
    let toolInputJSON: String?
    /// One-line summary of the tool input, e.g. the command or file path.
    let toolSummary: String?
    /// `permission_suggestions` as raw JSON, passed back for "Always allow".
    let permissionSuggestionsJSON: Data?
    let notificationType: String?
    let message: String?
    /// Set for permission requests that are waiting for an answer.
    let requestId: UUID?

    init?(json: [String: Any], requestId: UUID?) {
        guard let sessionId = json["session_id"] as? String, !sessionId.isEmpty,
              let event = json["event"] as? String else { return nil }
        self.sessionId = sessionId
        self.event = event
        self.cwd = json["cwd"] as? String ?? ""
        self.transcriptPath = json["transcript_path"] as? String
        self.permissionMode = json["permission_mode"] as? String
        self.pid = (json["pid"] as? NSNumber).map { Int32(truncating: $0) }
        self.tool = json["tool"] as? String
        self.toolUseId = json["tool_use_id"] as? String
        self.notificationType = json["notification_type"] as? String
        self.message = (json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestId = requestId

        if let input = json["tool_input"], !(input is NSNull),
           let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]) {
            self.toolInputJSON = String(data: data, encoding: .utf8)
            self.toolSummary = Self.summary(tool: json["tool"] as? String, input: input as? [String: Any])
        } else {
            self.toolInputJSON = nil
            self.toolSummary = nil
        }

        if let suggestions = json["permission_suggestions"] as? [Any], !suggestions.isEmpty {
            self.permissionSuggestionsJSON = try? JSONSerialization.data(withJSONObject: suggestions)
        } else {
            self.permissionSuggestionsJSON = nil
        }
    }

    private static func summary(tool: String?, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in ["command", "file_path", "path", "url", "pattern", "query", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty {
                let firstLine = value.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? value
                return firstLine
            }
        }
        return nil
    }
}

/// Unix socket server that receives events from the hook script and, for
/// permission requests, keeps the connection open until the user answers.
final class ClaudeHookSocketServer: @unchecked Sendable {
    static let socketPath = "/tmp/atoll-claude.sock"

    typealias EventHandler = @Sendable (ClaudeHookEvent) -> Void
    /// Called when a waiting hook goes away without an answer from us
    /// (answered in the terminal, timed out, or Claude quit).
    typealias ClosedHandler = @Sendable (UUID) -> Void

    private let acceptQueue = DispatchQueue(label: "atoll.claude.socket.accept", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "atoll.claude.socket.client", qos: .userInitiated, attributes: .concurrent)

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var onEvent: EventHandler?
    private var onClosed: ClosedHandler?

    private struct Pending {
        let fd: Int32
        let watcher: DispatchSourceRead
    }
    private var pending: [UUID: Pending] = [:]
    private let lock = NSLock()

    var isRunning: Bool { acceptQueue.sync { serverSocket >= 0 } }

    func start(onEvent: @escaping EventHandler, onClosed: @escaping ClosedHandler) {
        acceptQueue.async { [self] in
            guard serverSocket < 0 else { return }
            self.onEvent = onEvent
            self.onClosed = onClosed
            openSocket()
        }
    }

    func stop() {
        acceptQueue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            if serverSocket >= 0 {
                close(serverSocket)
                serverSocket = -1
            }
            unlink(Self.socketPath)
        }
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        for (_, item) in all {
            item.watcher.cancel()
        }
    }

    /// Sends `reply` to a waiting hook and closes it. A nil reply closes the
    /// connection without an answer, so Claude Code asks in the terminal.
    func respond(to requestId: UUID, reply: Data?) {
        lock.lock()
        let item = pending.removeValue(forKey: requestId)
        lock.unlock()
        guard let item else { return }

        if let reply {
            reply.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = write(item.fd, base.advanced(by: offset), buffer.count - offset)
                    if written <= 0 {
                        logger.error("Permission reply write failed: \(errno)")
                        break
                    }
                    offset += written
                }
            }
        }
        // The watcher's cancel handler closes the descriptor.
        item.watcher.cancel()
    }

    // MARK: - Socket setup

    private func openSocket() {
        unlink(Self.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger.error("socket() failed: \(errno)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(Self.socketPath.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (index, byte) in pathBytes.prefix(raw.count - 1).enumerated() {
                raw[index] = UInt8(bitPattern: byte)
            }
        }

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            logger.error("bind() failed: \(errno)")
            close(fd)
            return
        }
        chmod(Self.socketPath, 0o600)

        guard listen(fd, 16) == 0 else {
            logger.error("listen() failed: \(errno)")
            close(fd)
            unlink(Self.socketPath)
            return
        }

        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        serverSocket = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.resume()
        acceptSource = source
        logger.info("Listening on \(Self.socketPath, privacy: .public)")
    }

    private func acceptClients() {
        while true {
            let client = accept(serverSocket, nil, nil)
            guard client >= 0 else { return }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            clientQueue.async { [weak self] in self?.handle(client) }
        }
    }

    // MARK: - Clients

    private func handle(_ fd: Int32) {
        // Blocking read with a timeout, up to the newline that ends the message.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let maxSize = 4 * 1024 * 1024
        while data.count < maxSize, !data.contains(UInt8(ascii: "\n")) {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        if let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = data.prefix(upTo: newline)
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let eventName = json["event"] as? String else {
            close(fd)
            return
        }

        guard eventName == "PermissionRequest" else {
            close(fd)
            if let event = ClaudeHookEvent(json: json, requestId: nil) { onEvent?(event) }
            return
        }

        let requestId = UUID()
        guard let event = ClaudeHookEvent(json: json, requestId: requestId) else {
            close(fd)
            return
        }

        // Watch for the hook going away before we answer.
        let watcher = DispatchSource.makeReadSource(fileDescriptor: fd, queue: clientQueue)
        // The hook sends nothing more after its one line, so readable means
        // it closed (EOF) or errored. Stray bytes are drained and ignored.
        watcher.setEventHandler { [weak self] in
            var scratch = [UInt8](repeating: 0, count: 1024)
            let count = recv(fd, &scratch, scratch.count, MSG_DONTWAIT)
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                self?.hookWentAway(requestId)
            }
        }
        watcher.setCancelHandler { close(fd) }

        lock.lock()
        pending[requestId] = Pending(fd: fd, watcher: watcher)
        lock.unlock()
        watcher.resume()

        onEvent?(event)
    }

    private func hookWentAway(_ requestId: UUID) {
        lock.lock()
        let item = pending.removeValue(forKey: requestId)
        lock.unlock()
        guard let item else { return }
        item.watcher.cancel()
        onClosed?(requestId)
    }
}
