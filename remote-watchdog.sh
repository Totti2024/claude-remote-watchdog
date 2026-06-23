#!/bin/bash
# Claude Code Remote Control Watchdog
# Detects dead /remote-control sessions in tmux and auto-reconnects them.
#
# Usage: remote-watchdog.sh [--dry-run]
#
# Scope: only tmux sessions named "claude-rc-*" (the designated RC sessions).
#
# Classification per session (wording-robust — works with old AND new Claude
# Code status bars):
#   HEALTHY    : pane shows an "active" RC indicator
#                ("/rc active", "remote-control is active", "Remote Control active")
#   DEGRADED   : pane shows an RC indicator that is reconnecting/connecting
#                -> cycle via the Disconnect-menu dance (cycle_remote_control)
#   GONE       : live Claude pane but NO RC indicator at all (e.g. hard 401
#                "Please run /login") -> simple re-issue of /remote-control
#   (shell)    : no Claude status bar -> skipped, never touched
#
# Anything that is not HEALTHY uses a 2-check grace period (first hit = WARN,
# second consecutive = act) to avoid acting on transient boot/typing states.
#
# NOTE: A hard 401 needs the user to run /login first (refreshes the macOS
# Keychain credentials). This watchdog only re-establishes the RC connection
# afterwards; it cannot perform the login itself.
#
# State files: /tmp/claude-remote-watchdog-*.fail   (2-check grace period)
#
# History:
#   2026-06-20  added GONE (hard-401) detection
#   2026-06-21  Claude Code 2.1.185 renamed the status bar "Remote Control
#               active" -> "/rc active" / "/remote-control is active". Detection
#               rewritten to be wording-robust ("healthy or not").
#   2026-06-23  A CONNECTED session can show "/rc" WITHOUT "active" (seen on the
#               busy/high-effort egov session). The "healthy iff /rc active"
#               test thus misfired every busy tick: Ctrl+C killed live work and
#               the /remote-control overlay blocked input. Inverted the logic:
#               any live Claude TUI is healthy; act ONLY on a positive failure
#               signal (RC reconnecting/connecting, or a hard 401/login prompt).

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

STEP_WAIT=5  # seconds between tmux keystrokes (TUI needs time to render)

# RC indicator wording (case-insensitive). "." matches both space and hyphen,
# so it covers "Remote Control", "remote-control" and the short "/rc".
RC_TOKEN_RE='/rc |remote.control'
RC_HEALTHY_RE='active'           # kept for reference; no longer the health test
RC_DEGRADED_RE='reconnect|connecting'
# Positive failure signal: a hard 401 / expired login. This is the ONLY "gone"
# signal we trust (see History 2026-06-23).
LOGIN_RE='Please run /login|401 Invalid authentication|token has expired'
# Markers that prove a live Claude Code TUI is present (vs a crashed shell).
CLAUDE_BAR_RE='bypass permissions|for agents|\? for shortcuts|esc to interrupt|/effort|/rc '

# DEGRADED: RC stuck reconnecting -> cycle via the Disconnect menu dance.
cycle_remote_control() {
  local pane_id="$1" label="$2"
  if $DRY_RUN; then
    echo "[DRY-RUN] Would cycle /remote-control (menu dance) on $pane_id ($label)"
    return 0
  fi
  echo "[ACTION] Cycling /remote-control (menu dance) on $pane_id ($label)..."
  tmux send-keys -t "$pane_id" C-c; sleep 2
  tmux send-keys -t "$pane_id" C-u; sleep 1
  tmux send-keys -t "$pane_id" "/remote-control" Enter; sleep "$STEP_WAIT"
  # Navigate Up x2 to "Disconnect this session", select it, then reconnect.
  tmux send-keys -t "$pane_id" Up Up; sleep 1
  tmux send-keys -t "$pane_id" Enter; sleep "$STEP_WAIT"
  tmux send-keys -t "$pane_id" "/remote-control" Enter
  echo "[OK] Reconnect (menu dance) sent to $pane_id ($label)"
}

# GONE: RC absent entirely (hard 401) -> just (re)issue /remote-control.
# A fully disconnected session connects directly, no menu to navigate.
reconnect_dead_rc() {
  local pane_id="$1" label="$2"
  if $DRY_RUN; then
    echo "[DRY-RUN] Would (re)connect /remote-control on $pane_id ($label)"
    return 0
  fi
  echo "[ACTION] (Re)connecting /remote-control on $pane_id ($label)..."
  tmux send-keys -t "$pane_id" C-c; sleep 2
  tmux send-keys -t "$pane_id" C-u; sleep 1
  tmux send-keys -t "$pane_id" "/remote-control" Enter
  echo "[OK] Connect command sent to $pane_id ($label)"
}

# --- main ---

echo "=== Remote Control Watchdog $(date '+%H:%M:%S') ==="

FOUND_ANY=false
ALL_HEALTHY=true

while IFS= read -r line; do
  pane_id=$(echo "$line" | cut -d'|' -f1)
  sess_name=$(echo "$line" | cut -d'|' -f2)

  # Only the designated RC sessions.
  case "$sess_name" in
    claude-rc-*) ;;
    *) continue ;;
  esac

  pane_full=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null || true)
  state_file="/tmp/claude-remote-watchdog-${pane_id//[^a-zA-Z0-9]/_}.fail"

  # Last RC-indicator line = the status bar (earlier matches are scrollback).
  rc_line=$(echo "$pane_full" | grep -iE -- "$RC_TOKEN_RE" | tail -1 || true)

  # Classification (2026-06-23 rewrite): act ONLY on a positive failure signal.
  # A connected session on Claude Code 2.1.185 may show "/rc" WITHOUT the word
  # "active" (confirmed on the egov session, which is busy/at high effort). The
  # old test "healthy iff I see /rc active" therefore misfired on every busy
  # tick: it Ctrl+C'd live work and popped the /remote-control overlay (which
  # blocks input). We now treat any live Claude TUI as healthy and only
  # reconnect on (a) RC stuck reconnecting, or (b) a hard 401 / login prompt.

  # ---------- DEGRADED: RC indicator stuck reconnecting/connecting ----------
  if echo "$rc_line" | grep -qiE -- "$RC_DEGRADED_RE"; then
    FOUND_ANY=true; ALL_HEALTHY=false
    kind="degraded (reconnecting/connecting)"
  # ---------- GONE: hard 401 / login required ----------
  elif echo "$pane_full" | grep -qiE -- "$LOGIN_RE"; then
    FOUND_ANY=true; ALL_HEALTHY=false
    kind="gone (401 / login required)"
  # ---------- HEALTHY: live Claude TUI, no failure signal ----------
  elif echo "$pane_full" | grep -qiE -- "$CLAUDE_BAR_RE"; then
    FOUND_ANY=true
    $DRY_RUN || rm -f "$state_file" 2>/dev/null
    echo "[HEALTHY] $sess_name ($pane_id)"
    continue
  # ---------- SKIP: no Claude bar (crashed shell, or a menu/overlay is open) ----------
  else
    echo "[SKIP] $sess_name ($pane_id): no Claude status bar (shell/menu?) -- not touching"
    continue
  fi

  # 2-check grace period. In dry-run the state files are never written/removed,
  # so a probe run can never arm the real cron (this was a real footgun once).
  if [[ -f "$state_file" ]]; then
    $DRY_RUN || rm -f "$state_file"
    echo "[DEAD] $sess_name ($pane_id): $kind -- reconnecting"
    if echo "$rc_line" | grep -qiE -- "$RC_DEGRADED_RE"; then
      cycle_remote_control "$pane_id" "$sess_name"
    else
      reconnect_dead_rc "$pane_id" "$sess_name"
    fi
  else
    $DRY_RUN || touch "$state_file"
    echo "[WARN] $sess_name ($pane_id): $kind -- confirming next check"
  fi

done < <(tmux list-panes -a -F '#{pane_id}|#{session_name}' 2>/dev/null)

if ! $FOUND_ANY; then
  echo "[SKIP] No Remote Control sessions found"
elif $ALL_HEALTHY; then
  echo "[OK] All Remote Control sessions healthy"
fi
