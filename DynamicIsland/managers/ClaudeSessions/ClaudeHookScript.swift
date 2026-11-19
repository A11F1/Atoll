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

/// The hook script Claude Code runs for each session event.
///
/// It is installed to `~/Library/Application Support/Atoll/atoll-claude-hook.py`
/// and registered in `~/.claude/settings.json` by `ClaudeHookInstaller`.
///
/// - Exits at once when Atoll's socket is missing, so it costs almost nothing
///   while Atoll is not running.
/// - Sends one JSON object per event to the socket.
/// - For `PermissionRequest` it waits for Atoll's answer and prints it to
///   stdout, which Claude Code reads as the hook decision. If Atoll never
///   answers, it prints nothing and Claude Code shows its own prompt.
enum ClaudeHookScript {
    /// Every command we register contains this, so install and uninstall only
    /// ever touch our own entries.
    static let marker = "atoll-claude-hook"

    static let fileName = "atoll-claude-hook.py"

    static let text: String = #"""
#!/usr/bin/env python3
# atoll-claude-hook.py: sends Claude Code session events to Atoll.
# Installed and managed by Atoll. Reinstalling overwrites this file.
import json
import os
import socket
import subprocess
import sys

SOCKET_PATH = "/tmp/atoll-claude.sock"
# Must stay below the hook timeout Atoll registers for PermissionRequest.
PERMISSION_WAIT_SECONDS = 290
MAX_TEXT = 400


def find_claude_pid():
    """Walk up the parent chain to the claude process (hooks run under a shell)."""
    try:
        out = subprocess.run(
            ["/bin/ps", "-axo", "pid=,ppid=,comm="],
            capture_output=True, text=True, timeout=2,
        ).stdout
    except Exception:
        return None
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        try:
            table[int(parts[0])] = (int(parts[1]), parts[2])
        except ValueError:
            continue
    pid = os.getppid()
    for _ in range(8):
        entry = table.get(pid)
        if entry is None:
            return None
        ppid, comm = entry
        if "claude" in os.path.basename(comm).lower():
            return pid
        if ppid <= 1:
            return None
        pid = ppid
    return None


def clip(value):
    if isinstance(value, str) and len(value) > MAX_TEXT:
        return value[:MAX_TEXT] + "…"
    return value


def main():
    if not os.path.exists(SOCKET_PATH):
        return
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    if not isinstance(data, dict):
        return

    event = data.get("hook_event_name", "")
    if event == "Notification" and data.get("notification_type") == "permission_prompt":
        # PermissionRequest already covers this, with more detail.
        return

    payload = {
        "session_id": data.get("session_id", ""),
        "event": event,
        "cwd": data.get("cwd", ""),
        "transcript_path": data.get("transcript_path"),
        "permission_mode": data.get("permission_mode"),
        "pid": find_claude_pid(),
    }
    if event in ("PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied"):
        payload["tool"] = data.get("tool_name")
        payload["tool_input"] = data.get("tool_input")
        payload["tool_use_id"] = data.get("tool_use_id")
    if event == "PermissionRequest":
        payload["permission_suggestions"] = data.get("permission_suggestions")
    if event == "UserPromptSubmit":
        payload["message"] = clip(data.get("prompt"))
    if event in ("Stop", "SubagentStop"):
        payload["message"] = clip(data.get("last_assistant_message"))
    if event in ("Notification", "StopFailure", "PostToolUseFailure", "PermissionDenied"):
        payload["notification_type"] = data.get("notification_type")
        payload["message"] = clip(data.get("message") or data.get("error") or data.get("reason"))

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect(SOCKET_PATH)
        # One line per event: the newline marks the end of the message, and
        # keeping the socket fully open lets Atoll notice if this hook exits.
        sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
    except Exception:
        return

    if event != "PermissionRequest":
        sock.close()
        return

    # Wait for the answer from the notch. Atoll replies with the exact JSON
    # Claude Code expects, or closes without a reply to fall back to the terminal.
    try:
        sock.settimeout(PERMISSION_WAIT_SECONDS)
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
        reply = b"".join(chunks).decode("utf-8", "replace").strip()
        if reply:
            sys.stdout.write(reply)
            sys.stdout.flush()
    except Exception:
        pass
    finally:
        sock.close()


try:
    main()
except Exception:
    pass
sys.exit(0)
"""#
}
