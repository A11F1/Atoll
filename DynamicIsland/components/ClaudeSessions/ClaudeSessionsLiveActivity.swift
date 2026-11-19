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

/// Closed-notch wings while Claude Code is working or waiting for approval.
struct ClaudeSessionsLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var manager = ClaudeSessionManager.shared
    @State private var isExpanded = false

    private var wingHeight: CGFloat { vm.effectiveClosedNotchHeight - 12 }

    private var phase: ClaudeSessionPhase {
        manager.needsAttention ? .waitingForApproval : .thinking
    }

    private var countText: String {
        if manager.needsAttention {
            return manager.attentionCount > 1 ? "\(manager.attentionCount) waiting" : "Approve?"
        }
        return manager.workingCount > 1 ? "\(manager.workingCount)" : ""
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: Claude mark
            Color.clear
                .background {
                    if isExpanded {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(claudeAccent.opacity(0.16))
                            Image(systemName: "sparkle")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(claudeAccent)
                        }
                        .frame(width: wingHeight, height: wingHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
                .frame(width: isExpanded ? max(0, vm.effectiveClosedNotchHeight - 12) : 0,
                       height: wingHeight)

            // Centre: the physical notch
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width + 20)

            // Right: status
            Color.clear
                .background {
                    if isExpanded {
                        HStack(spacing: 5) {
                            if !countText.isEmpty {
                                Text(countText)
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(manager.needsAttention ? claudeAccent : .secondary)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            ClaudeStatusDot(phase: phase)
                                .id(manager.needsAttention)
                        }
                        .padding(.trailing, 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    }
                }
                .frame(width: isExpanded ? (manager.needsAttention ? 72 : max(36, vm.effectiveClosedNotchHeight)) : 0,
                       height: wingHeight)
                .animation(.smooth(duration: 0.25), value: manager.needsAttention)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .onAppear {
            withAnimation(.smooth(duration: 0.35)) { isExpanded = true }
        }
    }
}
