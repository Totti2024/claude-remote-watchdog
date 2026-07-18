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
# State files (keyed by session name since 2026-07-17b, NOT pane_id):
#   /tmp/claude-remote-watchdog-<sess>.fail       (2-check grace period)
#   /tmp/claude-remote-watchdog-<sess>.notified   (401-Telegram dedup)
#   /tmp/claude-remote-watchdog-<sess>.escalated  (never-connected tier-1->2)
#   /tmp/claude-remote-watchdog-<sess>.t2last     (tier-2 30-min cooldown)
#   /tmp/claude-remote-watchdog.running           (whole-script run lock)
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
#   2026-07-17b Hardening pass after a 4-agent audit of the whole RC stack:
#               (1) all remediation tmux calls and the tier-2 invocation are
#               now set-e-safe (a vanished pane or missing rc-restart.sh no
#               longer aborts the whole run mid-loop, skipping later sessions);
#               (2) state files are keyed by SESSION NAME, not pane_id --
#               pane ids restart at %0 after a server crash, so a stale
#               .escalated marker could have hard-restarted the WRONG session;
#               (3) narrowed "/rc" in RC_TOKEN_RE to require a space or EOL
#               after it (chat text like "~/rc-restart.sh" matched the old
#               pattern and masked a genuinely dead bridge as HEALTHY); the
#               "↯" glyph was evaluated and deliberately REJECTED as a token
#               (it showed on the never-connected sessions too); (4) the GONE/401
#               branch now also requires an ABSENT RC token -- conversation
#               text quoting "Please run /login" on a healthy session no
#               longer triggers a false 401 remediation; (5) whole-script
#               run lock (stale-broken at >4 min) so overlapping cron ticks
#               can't send keystrokes to the same pane concurrently -- also
#               keeps the health-check watchdog call at the end of a
#               tier-2-invoked rc-restart.sh from re-entering this run;
#               (6) tier-2 hard restarts are rate-limited to one per session
#               per 30 min (a structurally broken bridge no longer gets its
#               session killed + Telegram-spammed every ~20 min); (7) a
#               failed resurrect now notifies Totti instead of only logging.
#   2026-07-18  Added a PASSIVE RAM watch (check_ram): warns Totti via Telegram
#               (dedup 1x/h) when free memory drops to/below RC_RAM_FREE_MIN_PCT%
#               or swap used reaches RC_RAM_SWAP_MAX_MB MB. Read-only by design
#               (Memory rule "backup/system infra: analyse only") -- it NEVER
#               kills or restarts anything on low RAM. Rationale: the prime
#               suspect for the 2026-06-23 whole-server crash was a creeping
#               memory squeeze (4-agent audit 2026-07-17 measured ~247 MB free
#               + heavy swap), so this catches the squeeze BEFORE it crashes,
#               instead of only resurrecting AFTER. Thresholds overridable in
#               notify.env (RC_RAM_FREE_MIN_PCT / RC_RAM_SWAP_MAX_MB).

set -euo pipefail

# Härtung (2026-06-23): nicht auf die crontab-PATH-Zeile verlassen. Stellt
# sicher, dass tmux (/opt/homebrew/bin) gefunden wird, selbst wenn der Cron mit
# Default-PATH läuft — sonst scheiterte jeder bare `tmux`-Aufruf still.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

STEP_WAIT=5  # seconds between tmux keystrokes (TUI needs time to render)

# --- Whole-script run lock (added 2026-07-17b) -------------------------------
# Two overlapping runs (slow tick + next cron tick, or the health-check call at
# the end of a tier-2-invoked rc-restart.sh) must never both send keystrokes to
# the same pane. mkdir is atomic; a lock older than 4 min is stale (no
# legitimate run takes that long) and gets broken. Dry-run is read-only and
# skips the lock entirely so a manual probe never blocks the real cron.
RUN_LOCK="/tmp/claude-remote-watchdog.running"
RUN_LOCK_HELD=0
RESURRECT_HELD=0
cleanup_locks() {
  [ "$RUN_LOCK_HELD" = "1" ] && rmdir "$RUN_LOCK" 2>/dev/null
  [ "$RESURRECT_HELD" = "1" ] && rmdir "$RESURRECT_LOCK" 2>/dev/null
  return 0
}
if ! $DRY_RUN; then
  if [ -d "$RUN_LOCK" ] && find "$RUN_LOCK" -maxdepth 0 -mmin +4 2>/dev/null | grep -q .; then
    echo "[WARN] Breaking stale run lock (>4 min old)"
    rmdir "$RUN_LOCK" 2>/dev/null || rm -rf "$RUN_LOCK" 2>/dev/null || true
  fi
  if ! mkdir "$RUN_LOCK" 2>/dev/null; then
    echo "[SKIP] Another watchdog run is in progress -- exiting"
    exit 0
  fi
  RUN_LOCK_HELD=1
  trap cleanup_locks EXIT INT TERM
fi

# RC indicator wording (case-insensitive). "." matches both space and hyphen,
# so it covers "Remote Control", "remote-control" and the short "/rc".
# "/rc" must be followed by a space or end-of-line: the footer hint is either
# "/rc " mid-line or clipped flush at the pane's right edge (EOL). Anything
# looser bites back -- "[^a-zA-Z0-9_]" also matched the hyphen in chat text
# like "~/rc-restart.sh", masking a dead bridge as HEALTHY (2026-07-17b).
# NOTE: the "↯" separator glyph is deliberately NOT a token -- it was present
# on the 2026-07-17 never-connected sessions too (it means "--rc flag on",
# not "bridge registered") and would mask exactly that failure again.
RC_TOKEN_RE='/rc( |$)|remote.control'
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
  # Freigabe bei vorzeitigem Skript-Ende/Signal übernimmt der zentrale
  # cleanup_locks-Trap (2026-07-17b: die früheren lokalen trap/untrap-Zeilen
  # hier hätten den Run-Lock-Release des Haupt-Traps überschrieben bzw.
  # gelöscht -- ein Signal nach dem `trap -` hätte den Run-Lock verwaist).
  RESURRECT_HELD=1
  echo "[ACTION] Resurrecting tmux RC sessions ($reason)..."
  # If no server is running, clear any stale socket left behind by the crash.
  if ! tmux list-sessions >/dev/null 2>&1; then
    rm -f "/private/tmp/tmux-$(id -u)/default" "/tmp/tmux-$(id -u)/default" 2>/dev/null || true
  fi
  # Fehler-Benachrichtigung maximal 1x/Stunde (der Cron laeuft alle 5 Min --
  # ohne Drossel waere ein dauerhaft kaputter Resurrect 12 Telegram-Pings/h).
  local resurrect_notified="/tmp/claude-remote-watchdog-resurrect.notified"
  if [[ -x "$START_ALL_SCRIPT" ]]; then
    if "$START_ALL_SCRIPT" >/dev/null 2>&1; then
      echo "[OK] start-all-rc.sh launched -- sessions will connect within seconds"
      rm -f "$resurrect_notified" 2>/dev/null || true
    else
      echo "[ERR] start-all-rc.sh failed; will retry next run"
      if ! find "$resurrect_notified" -maxdepth 0 -mmin -60 2>/dev/null | grep -q .; then
        notify_totti "🔴 RC-Watchdog: Resurrect fehlgeschlagen ($reason) -- start-all-rc.sh Fehler. Naechster Cron-Lauf versucht es erneut; bitte bei Wiederholung manuell pruefen."
        touch "$resurrect_notified"
      fi
    fi
  else
    echo "[ERR] start-all-rc.sh not executable: $START_ALL_SCRIPT"
    if ! find "$resurrect_notified" -maxdepth 0 -mmin -60 2>/dev/null | grep -q .; then
      notify_totti "🔴 RC-Watchdog: start-all-rc.sh nicht ausfuehrbar -- automatische Wiederbelebung unmoeglich, bitte manuell pruefen."
      touch "$resurrect_notified"
    fi
  fi
  rmdir "$RESURRECT_LOCK" 2>/dev/null || true
  RESURRECT_HELD=0
}

# DEGRADED: RC stuck reconnecting -> cycle via the Disconnect menu dance.
cycle_remote_control() {
  local pane_id="$1" label="$2"
  if $DRY_RUN; then
    echo "[DRY-RUN] Would cycle /remote-control (menu dance) on $pane_id ($label)"
    return 0
  fi
  echo "[ACTION] Cycling /remote-control (menu dance) on $pane_id ($label)..."
  # Jeder send-keys mit || true (2026-07-17b): verschwindet die Pane zwischen
  # Klassifikation und Remediation, wuerde set -e sonst das GANZE Skript mitten
  # in der Tastatursequenz abbrechen -- spaetere Sessions blieben ungeprueft.
  tmux send-keys -t "$pane_id" C-c 2>/dev/null || true; sleep 2
  tmux send-keys -t "$pane_id" C-u 2>/dev/null || true; sleep 1
  tmux send-keys -t "$pane_id" "/remote-control" Enter 2>/dev/null || true; sleep "$STEP_WAIT"
  # Navigate Up x2 to "Disconnect this session", select it, then reconnect.
  tmux send-keys -t "$pane_id" Up Up 2>/dev/null || true; sleep 1
  tmux send-keys -t "$pane_id" Enter 2>/dev/null || true; sleep "$STEP_WAIT"
  tmux send-keys -t "$pane_id" "/remote-control" Enter 2>/dev/null || true
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
  # || true: siehe cycle_remote_control (set-e-Schutz bei verschwundener Pane).
  tmux send-keys -t "$pane_id" C-c 2>/dev/null || true; sleep 2
  tmux send-keys -t "$pane_id" C-u 2>/dev/null || true; sleep 1
  tmux send-keys -t "$pane_id" "/remote-control" Enter 2>/dev/null || true
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

# --- Passive RAM watch (added 2026-07-18) -----------------------------------
# Warn-only. NEVER acts on the system (no kill, no restart) -- see History
# 2026-07-18 and the Memory rule "backup/system infra: analyse only". Reads two
# cheap, sudo-free signals: system-wide free-RAM % (memory_pressure -Q) and swap
# used in MB (sysctl vm.swapusage). If either crosses its threshold, Totti gets
# ONE Telegram warning per hour (same dedup pattern as the 401/resurrect alerts).
RAM_FREE_MIN_PCT="${RC_RAM_FREE_MIN_PCT:-5}"    # warn when free% <= this
RAM_SWAP_MAX_MB="${RC_RAM_SWAP_MAX_MB:-1800}"   # warn when swap used MB >= this
RAM_NOTIFIED="/tmp/claude-remote-watchdog-ram.notified"

check_ram() {
  local free_pct swap_used_mb
  free_pct=$(memory_pressure -Q 2>/dev/null \
    | awk -F': ' '/free percentage/{gsub(/%/,"",$2); print int($2); exit}')
  swap_used_mb=$(sysctl -n vm.swapusage 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="used"){v=$(i+2); gsub(/[Mm]/,"",v); print int(v); exit}}')

  # If either probe couldn't be parsed, skip silently rather than false-alarm.
  if [[ -z "$free_pct" || -z "$swap_used_mb" ]]; then
    echo "[RAM] skipped (could not read memory stats)"
    return 0
  fi

  local msgs=()
  if (( free_pct <= RAM_FREE_MIN_PCT )); then
    msgs+=("nur ${free_pct}% RAM frei (Schwelle ${RAM_FREE_MIN_PCT}%)")
  fi
  if (( swap_used_mb >= RAM_SWAP_MAX_MB )); then
    msgs+=("Swap ${swap_used_mb} MB belegt (Schwelle ${RAM_SWAP_MAX_MB} MB)")
  fi

  if (( ${#msgs[@]} > 0 )); then
    local detail; detail=$(printf '%s; ' "${msgs[@]}"); detail=${detail%; }
    echo "[WARN][RAM] $detail"
    if ! $DRY_RUN && ! find "$RAM_NOTIFIED" -maxdepth 0 -mmin -60 2>/dev/null | grep -q .; then
      notify_totti "🟠 RC-Watchdog: RAM knapp, $detail. Kein Auto-Eingriff (nur Analyse). Tipp: nicht gebrauchte Sessions per /clear leeren oder ~/rc-restart.sh, Fremd-Apps (Safari, mysqld) schliessen."
      touch "$RAM_NOTIFIED"
    fi
  else
    echo "[RAM] ok (${free_pct}% frei, Swap ${swap_used_mb} MB)"
    $DRY_RUN || rm -f "$RAM_NOTIFIED" 2>/dev/null || true
  fi
  return 0
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
  # State-Files nach SESSION-NAME, nicht pane_id (2026-07-17b): Pane-IDs
  # starten nach einem Server-Crash wieder bei %0 -- ein verwaister
  # .escalated-Marker der alten %0 haette die NEUE Session, die zufaellig %0
  # bekommt, direkt auf Tier-2 (Hard-Restart) eskaliert, ohne dass je Tier 1
  # lief. Session-Namen sind stabil (claude-rc-1..4, claude-rc-egov).
  state_file="/tmp/claude-remote-watchdog-${sess_name//[^a-zA-Z0-9]/_}.fail"
  notify_file="/tmp/claude-remote-watchdog-${sess_name//[^a-zA-Z0-9]/_}.notified"
  esc_file="/tmp/claude-remote-watchdog-${sess_name//[^a-zA-Z0-9]/_}.escalated"
  t2_file="/tmp/claude-remote-watchdog-${sess_name//[^a-zA-Z0-9]/_}.t2last"

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
  # Zusatzbedingung -z rc_line (2026-07-17b): Bei einem ECHTEN harten 401 ist
  # der RC-Indikator komplett weg (dokumentiert 2026-06-20). Steht der
  # RC-Indikator noch, ist "Please run /login" nur zitierter GESPRAECHSTEXT
  # in einer gesunden Session -- ohne diese Bedingung wuerde der Watchdog dort
  # Ctrl+C senden und laufende Arbeit abschiessen (False Positive).
  elif [[ -z "$rc_line" ]] && echo "$pane_full" | grep -qiE -- "$LOGIN_RE"; then
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
        # escalate to a full session restart. Rate-limited to one hard restart
        # per session per 30 min (2026-07-17b): a structurally broken bridge
        # would otherwise get killed + Telegram-notified every ~20 min forever.
        # The esc_file stays in place during cooldown so the retry happens as
        # soon as the window expires. || true: set-e-safe (a missing
        # rc-restart.sh returns 1 and must not abort the whole run).
        if find "$t2_file" -maxdepth 0 -mmin -30 2>/dev/null | grep -q .; then
          echo "[SKIP] $sess_name: tier-2 cooldown active (last hard restart <30 min ago) -- retrying later"
        else
          restart_session_hard "$sess_name" || true
          $DRY_RUN || { touch "$t2_file"; rm -f "$esc_file"; }
        fi
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

# Passive RAM watch runs every tick regardless of session health (read-only).
check_ram
