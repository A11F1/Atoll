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
 */

import SwiftUI
import Defaults

/// Brand-ish orange used for Claude indicators.
let claudeAccent = Color(red: 0.85, green: 0.47, blue: 0.34)

struct NotchClaudeSessionsView: View {
    @ObservedObject private var manager = ClaudeSessionManager.shared
    @Default(.enableClaudeSessions) private var enabled

    var body: some View {
        Group {
            if !enabled {
                placeholder(icon: "sparkles", title: "Claude sessions are off",
                            detail: "Turn them on in Settings → Stats → Claude Code Sessions.")
            } else if manager.sessions.isEmpty && manager.hookStatus != .installed {
                placeholder(icon: "link", title: "Hooks not installed",
                            detail: "Install the Claude Code hooks in Settings → Stats → Claude Code Sessions.")
            } else if manager.sessions.isEmpty {
                placeholder(icon: "sparkles", title: "No active sessions",
                            detail: "Start `claude` in a terminal and it will show up here.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(manager.sessions) { session in
                            SessionCard(session: session)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(claudeAccent)
            Text(title).font(.headline)
            Text(LocalizedStringKey(detail))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionCard: View {
    let session: ClaudeSession
    @ObservedObject private var manager = ClaudeSessionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ClaudeStatusDot(phase: session.displayPhase)
                Text(session.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let mode = modeBadge {
                    Text(mode)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(session.displayPhase.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(session.needsAttention ? claudeAccent : .secondary)
                    .lineLimit(1)
                Button {
                    manager.focusTerminal(for: session.id)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show this session's terminal")
            }

            if let request = session.pendingPermissions.first {
                PermissionPrompt(sessionId: session.id, request: request,
                                 extraCount: session.pendingPermissions.count - 1)
            } else if let text = detailText {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(session.needsAttention ? 0.1 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(claudeAccent.opacity(session.needsAttention ? 0.6 : 0), lineWidth: 1)
        )
        .contextMenu {
            Button("Show Terminal") { manager.focusTerminal(for: session.id) }
            Button("Hide Session") { manager.dismiss(sessionId: session.id) }
        }
    }

    private var detailText: String? {
        if let notice = session.notice { return notice }
        if session.displayPhase.isWorking, let prompt = session.lastPrompt { return "› " + prompt }
        return session.lastMessage ?? session.lastPrompt.map { "› " + $0 }
    }

    private var modeBadge: String? {
        switch session.permissionMode {
        case "plan": return "PLAN"
        case "acceptEdits": return "ACCEPT EDITS"
        case "bypassPermissions": return "BYPASS"
        case "auto": return "AUTO"
        default: return nil
        }
    }
}

private struct PermissionPrompt: View {
    let sessionId: String
    let request: ClaudePermissionRequest
    let extraCount: Int
    @ObservedObject private var manager = ClaudeSessionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(claudeAccent)
                Text("Allow \(request.tool)?")
                    .font(.system(size: 12, weight: .semibold))
                if extraCount > 0 {
                    Text("+\(extraCount) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            if let summary = request.summary {
                Text(summary)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Button("Deny") { manager.deny(sessionId: sessionId, requestId: request.id) }
                    .buttonStyle(ClaudeButtonStyle(kind: .secondary))
                Button("Terminal") { manager.answerInTerminal(sessionId: sessionId, requestId: request.id) }
                    .buttonStyle(ClaudeButtonStyle(kind: .secondary))
                    .help("Answer this in Claude Code's own prompt")
                Spacer(minLength: 0)
                if request.canAlwaysAllow {
                    Button("Always") { manager.approve(sessionId: sessionId, requestId: request.id, always: true) }
                        .buttonStyle(ClaudeButtonStyle(kind: .secondary))
                        .help("Allow, and don't ask again for this")
                }
                Button("Allow") { manager.approve(sessionId: sessionId, requestId: request.id) }
                    .buttonStyle(ClaudeButtonStyle(kind: .primary))
            }
        }
    }
}

struct ClaudeButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(kind == .primary ? Color.black : Color.white)
            .background(
                Capsule().fill(kind == .primary ? claudeAccent : Color.white.opacity(0.14))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Small status light: orange pulse for approval, spinning arc while working.
struct ClaudeStatusDot: View {
    let phase: ClaudeSessionPhase
    @State private var pulse = false
    @State private var spin = false

    var body: some View {
        ZStack {
            switch phase {
            case .waitingForApproval:
                Circle()
                    .fill(claudeAccent)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 1.25 : 0.85)
                    .opacity(pulse ? 1 : 0.6)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
            case .thinking, .runningTool, .compacting:
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(claudeAccent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .frame(width: 9, height: 9)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            case .waitingForInput:
                Circle()
                    .fill(Color.green.opacity(0.85))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: 12, height: 12)
    }
}
