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
#   HEALTHY         : live Claude TUI AND an RC indicator is present somewhere
#                      in the pane (banner "remote-control is active" or the
#                      persistent footer "/rc" hint)
#   DEGRADED        : pane shows an RC indicator that is reconnecting/connecting
#                      -> cycle via the Disconnect-menu dance (cycle_remote_control)
#   GONE            : live Claude pane but NO RC indicator at all (e.g. hard 401
#                      "Please run /login") -> simple re-issue of /remote-control
#   NEVER-CONNECTED : live Claude TUI, but NO RC indicator anywhere and NO 401
#                      either -> the --rc flag's bridge registration itself
#                      never came up, even though the process/pane is otherwise
#                      perfectly healthy (this was previously misclassified as
#                      HEALTHY because "bypass permissions" etc. are RC-agnostic
#                      liveness markers -- see History 2026-07-17). Tier 1 =
#                      re-issue /remote-control in-place; if that doesn't clear
#                      it by the next cycle, tier 2 = full kill-session + fresh
#                      `claude --rc` restart via rc-restart.sh (the only fix
#                      that reliably worked on 2026-07-17).
#   (shell)         : no Claude status bar -> skipped, never touched
#
# Anything that is not HEALTHY uses a 2-check grace period (first hit = WARN,
# second consecutive = act) to avoid acting on transient boot/typing states.
#
# NOTE: A hard 401 needs the user to run /login first (refreshes the macOS
# Keychain credentials). This watchdog only re-establishes the RC connection
# afterwards; it cannot perform the login itself.
#
# State files: /tmp/claude-remote-watchdog-*.fail        (2-check grace period)
#              /tmp/claude-remote-watchdog-*.escalated    (never-connected tier-1->2)
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
#   2026-07-17  Found (manually) that 2 of 5 sessions restarted via rc-restart.sh
#               never got the "/remote-control is active" banner or the "/rc"
#               footer hint at all -- yet CLAUDE_BAR_RE ("bypass permissions"
#               etc.) matched fine, so the old logic reported them HEALTHY.
#               One session needed TWO full restarts before RC came up. Added
#               the NEVER-CONNECTED state (live TUI + zero RC token anywhere)
#               with its own tier-1 (in-place reconnect) / tier-2 (hard
#               kill-session restart via rc-restart.sh) escalation, and
#               tightened RC_TOKEN_RE to also match a trailing "/rc" with no
#               following space (the footer hint gets clipped at the pane's
#               right edge).

set -euo pipefail

# Härtung (2026-06-23): nicht auf die crontab-PATH-Zeile verlassen. Stellt
# sicher, dass tmux (/opt/homebrew/bin) gefunden wird, selbst wenn der Cron mit
# Default-PATH läuft — sonst scheiterte jeder bare `tmux`-Aufruf still.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

STEP_WAIT=5  # seconds between tmux keystrokes (TUI needs time to render)

# RC indicator wording (case-insensitive). "." matches both space and hyphen,
# so it covers "Remote Control", "remote-control" and the short "/rc". The
# "/rc" footer hint often sits flush against the pane's right edge with no
# trailing space -- match end-of-line or any non-word char after it too
# (2026-07-17: the plain "/rc " form silently missed that clipped case).
RC_TOKEN_RE='/rc([^a-zA-Z0-9_]|$)|remote.control'
RC_HEALTHY_RE='active'           # kept for reference; no longer the health test
RC_DEGRADED_RE='reconnect|connecting'
# Positive failure signal: a hard 401 / expired login. This is the ONLY "gone"
# signal we trust (see History 2026-06-23).
LOGIN_RE='Please run /login|401 Invalid authentication|token has expired'
# Markers that prove a live Claude Code TUI is present (vs a crashed shell).
# Deliberately RC-agnostic (no "/rc" here, see History 2026-07-17): this must
# stay true for a session whose RC bridge never connected at all, so that
# branch can be told apart from real HEALTHY by RC_TOKEN_RE separately.
CLAUDE_BAR_RE='bypass permissions|for agents|\? for shortcuts|esc to interrupt|/effort'

# --- Notification (added 2026-06-23) ----------------------------------------
# Bei einem harten 401 kann der Watchdog NICHT selbst heilen (nur der Mensch via
# /login). Damit Totti nicht erst beim nächsten Blick aufs Handy merkt, dass RC
# down ist, schicken wir EINMALIG pro 401-Episode eine Telegram-Warnung über den
# n8n-Webhook (URL in ~/.config/claude-rc-watchdog/notify.env, nicht im Repo).
NOTIFY_CFG="$HOME/.config/claude-rc-watchdog/notify.env"
[ -f "$NOTIFY_CFG" ] && . "$NOTIFY_CFG"
notify_totti() {
  local msg="$1"
  if $DRY_RUN; then echo "[DRY-RUN] Would notify Totti: $msg"; return 0; fi
  # Lokale Desktop-Meldung (greift, wenn jemand am Mac sitzt).
  osascript -e "display notification \"$msg\" with title \"RC-Watchdog\"" >/dev/null 2>&1 || true
  # Push aufs Handy via n8n-Webhook (greift auch unterwegs).
  if [ -n "${RC_NOTIFY_WEBHOOK:-}" ]; then
    curl -sS -m 15 -o /dev/null -X POST -H 'Content-Type: application/json' \
      --data "{\"message\":\"$msg\"}" "$RC_NOTIFY_WEBHOOK" >/dev/null 2>&1 \
      && echo "[NOTIFY] Telegram-Alert gesendet" \
      || echo "[NOTIFY] Webhook-Push fehlgeschlagen"
  fi
}

# --- Whole-server resurrection (added 2026-06-23) ---------------------------
# The classification logic above only repairs RC *inside* existing sessions.
# It is blind to the catastrophic case where the whole tmux server crashes
# (happened 2026-06-23 ~20:20): no server -> no panes -> the loop just reports
# "No Remote Control sessions found" and nothing comes back. The LaunchAgent has
# KeepAlive=false, so nothing else restarts it either. This preflight closes
# that gap: if the server is dead OR any expected claude-rc-* session is missing,
# we (re)launch them all via start-all-rc.sh (which is idempotent).
EXPECTED_SESSIONS=(claude-rc-1 claude-rc-2 claude-rc-3 claude-rc-4 claude-rc-egov)
START_ALL_SCRIPT="$HOME/remote-control-setup/start-all-rc.sh"
# Shared lock with the rc-keepalive LaunchAgent (which also resurrects, every
# ~60s). mkdir is atomic: whoever creates it first does the restart; the other
# skips to avoid two concurrent start-all-rc.sh racing on the same session.
RESURRECT_LOCK="/tmp/claude-rc-resurrect.lock"

resurrect_server() {
  local reason="$1"
  if $DRY_RUN; then
    echo "[DRY-RUN] Would resurrect tmux RC sessions ($reason) via $START_ALL_SCRIPT"
    return 0
  fi
  # Verwaistes Lock brechen: kein legitimer Halter braucht es länger als
  # start-all-rc.sh dauert (<30s). >3 Min = ein früherer Halter wurde mitten im
  # Resurrect hart gekillt (SIGKILL/launchctl unload/Hang). Ohne diese Notbremse
  # blockiert ein einziges verwaistes Lock BEIDE Schichten dauerhaft & lautlos.
  if [ -d "$RESURRECT_LOCK" ] && find "$RESURRECT_LOCK" -maxdepth 0 -mmin +3 2>/dev/null | grep -q .; then
    echo "[WARN] Breaking stale resurrect lock (>3 min old) -- previous holder was killed mid-resurrect"
    rmdir "$RESURRECT_LOCK" 2>/dev/null || rm -rf "$RESURRECT_LOCK" 2>/dev/null || true
  fi
  if ! mkdir "$RESURRECT_LOCK" 2>/dev/null; then
    echo "[SKIP] Resurrect already in progress (lock held by keepalive?) -- $reason"
    return 0
  fi
  # Lock auch bei vorzeitigem Skript-Ende/Signal freigeben (deckt EXIT/INT/TERM;
  # gegen SIGKILL hilft nur die Alters-Notbremse oben).
  trap 'rmdir "$RESURRECT_LOCK" 2>/dev/null || true' EXIT INT TERM
  echo "[ACTION] Resurrecting tmux RC sessions ($reason)..."
  # If no server is running, clear any stale socket left behind by the crash.
  if ! tmux list-sessions >/dev/null 2>&1; then
    rm -f "/private/tmp/tmux-$(id -u)/default" "/tmp/tmux-$(id -u)/default" 2>/dev/null || true
  fi
  if [[ -x "$START_ALL_SCRIPT" ]]; then
    "$START_ALL_SCRIPT" >/dev/null 2>&1 \
      && echo "[OK] start-all-rc.sh launched -- sessions will connect within seconds" \
      || echo "[ERR] start-all-rc.sh failed; will retry next run"
  else
    echo "[ERR] start-all-rc.sh not executable: $START_ALL_SCRIPT"
  fi
  rmdir "$RESURRECT_LOCK" 2>/dev/null || true
  trap - EXIT INT TERM
}

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

# NEVER-CONNECTED tier 2: the in-place reconnect_dead_rc above already ran
# once for this session and it is STILL never-connected on the next check --
# the RC bridge registration is stuck in a way that a slash command inside
# the process can't clear (confirmed 2026-07-17: session 3 needed this twice).
# Only a full kill-session + fresh `claude --rc` start reliably fixes it, so
# shell out to the same script Roman runs by hand for exactly this case.
RC_RESTART_SCRIPT="$HOME/rc-restart.sh"

restart_session_hard() {
  local sess_name="$1"
  if $DRY_RUN; then
    echo "[DRY-RUN] Would hard-restart $sess_name via $RC_RESTART_SCRIPT (never-connected tier-2)"
    return 0
  fi
  if [[ ! -x "$RC_RESTART_SCRIPT" ]]; then
    echo "[ERR] $RC_RESTART_SCRIPT not executable -- cannot hard-restart $sess_name"
    return 1
  fi
  echo "[ACTION] Hard-restarting $sess_name via rc-restart.sh (in-place reconnect already failed once)..."
  if "$RC_RESTART_SCRIPT" "$sess_name" >/dev/null 2>&1; then
    echo "[OK] $sess_name hard-restarted -- RC bridge should establish within seconds"
    notify_totti "RC-Session $sess_name: RC-Bridge kam nach Neustart nie hoch. Watchdog hat automatisch einen Hard-Restart via rc-restart.sh ausgeloest. Alter Verlauf per /resume in der Session holbar."
  else
    echo "[ERR] rc-restart.sh failed for $sess_name; will retry next cycle"
  fi
}

# --- main ---

echo "=== Remote Control Watchdog $(date '+%H:%M:%S') ==="

# Preflight: is the house even standing? If the tmux server is dead or any
# expected RC session is missing, resurrect them all and let the NEXT run verify
# the connections (freshly booted sessions would otherwise misfire the grace
# checks below). This is the only path that recovers a full server crash.
if ! tmux list-sessions >/dev/null 2>&1; then
  resurrect_server "tmux server dead"
  echo "[OK] Preflight done -- skipping per-session checks this run"
  exit 0
fi
missing=()
for s in "${EXPECTED_SESSIONS[@]}"; do
  tmux has-session -t "$s" 2>/dev/null || missing+=("$s")
done
if (( ${#missing[@]} > 0 )); then
  resurrect_server "missing sessions: ${missing[*]}"
  echo "[OK] Preflight done -- skipping per-session checks this run"
  exit 0
fi

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
  notify_file="/tmp/claude-remote-watchdog-${pane_id//[^a-zA-Z0-9]/_}.notified"
  esc_file="/tmp/claude-remote-watchdog-${pane_id//[^a-zA-Z0-9]/_}.escalated"

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
  # ---------- NEVER-CONNECTED: live TUI, but RC bridge absent entirely ----------
  # (no RC token anywhere in the pane, and it's not the 401 case either --
  # see History 2026-07-17)
  elif echo "$pane_full" | grep -qiE -- "$CLAUDE_BAR_RE" && [[ -z "$rc_line" ]]; then
    FOUND_ANY=true; ALL_HEALTHY=false
    kind="never-connected (live session, no RC bridge at all)"
  # ---------- HEALTHY: live Claude TUI, RC token present, no failure signal ----------
  elif echo "$pane_full" | grep -qiE -- "$CLAUDE_BAR_RE"; then
    FOUND_ANY=true
    # Wieder gesund -> alle Grace-/Notify-/Escalation-Marker löschen (re-arm:
    # ein späteres Problem löst dann wieder eine frische Warnung/Eskalation aus).
    $DRY_RUN || rm -f "$state_file" "$notify_file" "$esc_file" 2>/dev/null
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
    elif [[ "$kind" == never-connected* ]]; then
      if [[ -f "$esc_file" ]]; then
        # Tier 1 (in-place reconnect) already ran once and it's still down ->
        # escalate to a full session restart.
        restart_session_hard "$sess_name"
        $DRY_RUN || rm -f "$esc_file"
      else
        reconnect_dead_rc "$pane_id" "$sess_name"
        $DRY_RUN || touch "$esc_file"
      fi
    else
      reconnect_dead_rc "$pane_id" "$sess_name"
      # Harter 401: der Watchdog kann NICHT selbst heilen (nur /login durch
      # Totti). EINMALIG pro Episode warnen (Marker verhindert 5-Min-Spam;
      # wird bei [HEALTHY] wieder entfernt).
      if echo "$pane_full" | grep -qiE -- "$LOGIN_RE" && [ ! -f "$notify_file" ]; then
        notify_totti "🔴 RC-Session $sess_name: Login abgelaufen (401). Bitte am Mac /login ausführen — der Watchdog kann das nicht selbst."
        $DRY_RUN || touch "$notify_file"
      fi
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
