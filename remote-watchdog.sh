#!/bin/bash
# Claude Code Remote Control Watchdog
# Detects dead /remote-control sessions in tmux and auto-reconnects them.
#
# Usage: remote-watchdog.sh [--dry-run]
#
# How it works:
#   1. Scans all tmux panes for Claude Code status bar text
#   2. Skips panes without Remote Control enabled
#   3. If "Remote Control reconnecting" is detected:
#      - First detection: marks as warning (grace period)
#      - Second consecutive detection: triggers auto-reconnect
#   4. Auto-reconnect sends tmux keystrokes to cycle /remote-control:
#      Ctrl+C → /remote-control → Disconnect → /remote-control (reconnect)
#
# Requirements: tmux, Claude Code CLI with /remote-control
#
# State files: /tmp/claude-remote-watchdog-*.fail (2-check grace period)

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

STEP_WAIT=5  # seconds between tmux keystrokes (TUI needs time to render)

cycle_remote_control() {
  local pane_id="$1"
  local win_name="$2"

  if $DRY_RUN; then
    echo "[DRY-RUN] Would cycle /remote-control on pane $pane_id ($win_name)"
    return 0
  fi

  echo "[ACTION] Cycling /remote-control on pane $pane_id ($win_name)..."

  # Ctrl+C to interrupt anything in progress, then clear input line
  tmux send-keys -t "$pane_id" C-c
  sleep 2
  tmux send-keys -t "$pane_id" C-u
  sleep 1

  # Step 1: /remote-control → TUI appears with 3 options:
  #   Disconnect this session
  #   Show QR code
  # ❯ Continue                  ← cursor starts here
  tmux send-keys -t "$pane_id" "/remote-control" Enter
  sleep "$STEP_WAIT"

  # Step 2: Navigate Up×2 to "Disconnect this session", select it
  tmux send-keys -t "$pane_id" Up Up
  sleep 1
  tmux send-keys -t "$pane_id" Enter
  sleep "$STEP_WAIT"

  # Step 3: /remote-control again → auto-connects to a fresh bridge session
  # (no TUI menu this time, it connects directly)
  tmux send-keys -t "$pane_id" "/remote-control" Enter

  echo "[OK] Reconnect sequence sent to pane $pane_id ($win_name)"
}

# --- main ---

echo "=== Remote Control Watchdog $(date '+%H:%M:%S') ==="

FOUND_ANY=false
ALL_HEALTHY=true

while IFS= read -r line; do
  pane_id=$(echo "$line" | cut -d'|' -f1)
  win_name=$(echo "$line" | cut -d'|' -f2)

  # Grab the LAST line in the pane that mentions "Remote Control" — that is
  # the status bar. Earlier occurrences ("⎿ Remote Control connecting…") are
  # scrollback from prior /remote-control invocations and would cause false
  # WARN/DEAD readings if matched.
  pane_content=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null | grep "Remote Control" | tail -1 || true)

  # Skip panes without Remote Control in the status bar
  if ! echo "$pane_content" | grep -q "Remote Control"; then
    continue
  fi

  FOUND_ANY=true
  state_file="/tmp/claude-remote-watchdog-${pane_id//[^a-zA-Z0-9]/_}.fail"

  if echo "$pane_content" | grep -q "Remote Control reconnecting\|Remote Control connecting"; then
    ALL_HEALTHY=false
    # Both "reconnecting" and "connecting" can be stuck states.
    # Use 2-check grace period: first hit = warn, second consecutive = auto-reconnect.
    if [[ -f "$state_file" ]]; then
      rm -f "$state_file"
      rc_state=$(echo "$pane_content" | grep -o "Remote Control [a-z]*" | tail -1 | awk '{print $3}')
      echo "[DEAD] $win_name ($pane_id): stuck on '$rc_state' — auto-reconnecting"
      cycle_remote_control "$pane_id" "$win_name"
    else
      touch "$state_file"
      rc_state=$(echo "$pane_content" | grep -o "Remote Control [a-z]*" | tail -1 | awk '{print $3}')
      echo "[WARN] $win_name ($pane_id): '$rc_state' — confirming next check"
    fi
  else
    # "Remote Control active", "Remote Control at ...", etc.
    rm -f "$state_file" 2>/dev/null
    echo "[HEALTHY] $win_name ($pane_id)"
  fi

done < <(tmux list-panes -a -F '#{pane_id}|#{window_name}' 2>/dev/null)

if ! $FOUND_ANY; then
  echo "[SKIP] No Remote Control sessions found"
elif $ALL_HEALTHY; then
  echo "[OK] All Remote Control sessions healthy"
fi
