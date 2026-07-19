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
#   /tmp/claude-remote-watchdog-<sess>.draft      (stuck-draft grace: sig+mtime)
#   /tmp/claude-remote-watchdog-<sess>.draftnotified (stuck-draft alert dedup)
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
#   2026-07-18b Added the STUCK-DRAFT watch (handle_stuck_draft). Symptom
#               diagnosed live: the /remote-control relay delivers a phone-typed
#               message into the input box as a DRAFT but the submit never fires
#               -- the text just sits there unsent, the session stays HEALTHY
#               (RC connected) and silently never answers. Confirmed it is the
#               relay's submit, not tmux/watchdog/login: a locally typed Enter
#               submits fine, but a bare Enter on the relay-owned draft does not
#               -- only Ctrl+U clear -> retype -> Enter reliably submits it, and
#               that is exactly what the auto-drain does. The health check was
#               blind because it only verifies the RC *connection* indicator,
#               not that input submits. SAFETY: auto-drain fires ONLY for a
#               single-line plain-TEXT draft, idle & unchanged >= DRAFT_STUCK_MIN
#               min, re-checked immediately before sending; slash/bang commands,
#               multi-line/wrapped drafts (capture may be truncated) and menu
#               selections are NEVER auto-sent, only alerted once. Gotcha found
#               in test: the "empty" input box is ❯ + NBSP padding, and under the
#               cron C locale [:space:] does NOT strip NBSP -- so the draft
#               parser now strips NBSP/ZWSP/BOM explicitly (locale-independent)
#               before the emptiness test, else every idle box looked like a
#               2-space text draft and would have been auto-drained.
#   2026-07-19  TRUNCATION guard for the stuck-draft watch. Incident 19.07.2026
#               ~20:40: a LONG single-line draft ("kannst du die Kuendigungs-
#               frist ... der liegt in iCloud unter Dokumente/Arbeitsvertrag")
#               was horizontally clipped by the TUI (input box scrolls long
#               lines and renders an ellipsis at the clipped edge). The capture
#               held only the visible FRAGMENT ("...der liegt…"), DR_LINES was
#               1, so the multiline guard did not fire and the auto-drain sent
#               the cut-off fragment as a real prompt; the clipped tail ("in
#               iCloud unter Dokumente/Arbeitsvertrag") surfaced as a NEW draft
#               one tick later. Fix: a draft whose text carries the ellipsis
#               char (U+2026) at either end, or whose raw ❯-line fills the pane
#               width, is classified DR_KIND=truncated -> alert-only, never
#               auto-drained (same safe path as cmd/menu/multiline).
#   2026-07-19b AUTO-DRAIN DISABLED BY DEFAULT (RC_DRAFT_AUTODRAIN, default 0).
#               Second ghost incident the same evening: the relay drip-feeds a
#               QUEUE of old/never-sent inputs into the rc-2 box -- each time
#               the box empties, the next item appears ('/update obsidian'
#               resurfaced an hour after it had already run). Auto-drain then
#               submitted queue items as real prompts that Roman never sent
#               ("Ja, bau den Fix..." triggered a repo commit + a read of his
#               employment contract). The core assumption "whatever sits in
#               the box was meant to be sent" is disproven -> the watchdog now
#               only ALERTS on stuck drafts (Telegram) and never submits them
#               unless RC_DRAFT_AUTODRAIN=1 is set explicitly in notify.env.
#   2026-07-19c AUTO-CLEAR stuck drafts (RC_DRAFT_AUTOCLEAR, default 1).
#               Third ghost incident: a draft appeared that answered Claude's
#               latest question, phrased in Roman's voice, which Roman never
#               wrote; in parallel rc-1 held a draft matching ITS session
#               context. Working hypothesis: the claude.ai client generates
#               suggested replies and a relay bug deposits them into the input
#               box. Roman confirmed these drafts are INVISIBLE in the client
#               UI -- he can neither see nor delete them from his phone, and a
#               stray Enter would submit them on a bypass-permissions session.
#               New behavior: alert with the FULL text (up to 200 chars), then
#               race-guarded Ctrl+U clear + verify; genuine stuck messages can
#               be retyped from the alert.

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

# --- Stuck-draft watch (added 2026-07-18) -----------------------------------
# The /remote-control input relay sometimes delivers a phone-typed message into
# the input box as a DRAFT but the submit never fires -- the message just sits
# there unsent, so the session looks HEALTHY (RC connected) yet silently never
# answers (diagnosed 2026-07-18: local tmux Enter submits fine, so it is the
# relay's submit, not tmux/watchdog/login). The health check is blind to it
# because it only verifies the RC *connection* indicator, not that input
# actually submits. This watch catches a stuck draft and, for the SAFE case
# only, auto-submits it (the proven manual fix: Ctrl+U clear -> retype -> Enter).
#
# SAFETY (these sessions run with bypass-permissions, so an auto-submit runs as
# a real prompt): auto-drain fires ONLY for a single-line plain-TEXT draft that
# has been idle & byte-for-byte unchanged for >= DRAFT_STUCK_MIN minutes, with a
# fresh re-check immediately before sending (race guard vs. the user mid-typing).
# Anything else -- a slash/bang command, a multi-line/wrapped draft (capture may
# be truncated -> retyping would send the WRONG text), a horizontally clipped
# draft (TUI scrolls long lines, renders "…" at the clipped edge -- the capture
# is a fragment; bit us live on 19.07.2026), or a menu selection -- is
# NEVER auto-sent; it only raises a one-shot Telegram alert. Grace + dedup use
# the same session-keyed /tmp state-file idiom as the RC remediation above.
DRAFT_STUCK_MIN="${RC_DRAFT_STUCK_MIN:-9}"   # act once a draft is unchanged >= N min
# Master switch for the auto-submit path. 0 (default) = alert-only: NEVER
# auto-send a stuck draft, regardless of kind. Set RC_DRAFT_AUTODRAIN=1 in
# notify.env to re-enable the old behavior. Default flipped to 0 on 2026-07-19
# after two ghost-message incidents (see changelog 2026-07-19b): the relay
# turned out to drip-feed a queue of stale inputs into the box, so box content
# does NOT reliably represent what the user wants sent.
DRAFT_AUTODRAIN="${RC_DRAFT_AUTODRAIN:-0}"
# Auto-CLEAR stuck drafts (2026-07-19c, third ghost incident): after the
# Telegram alert (which carries the full text), the watchdog deletes the
# stuck draft from the input box via Ctrl+U. Rationale: ghost drafts are
# invisible in the claude.ai client (Roman can neither see nor delete them
# remotely) and would be submitted by any stray Enter on these
# bypass-permissions sessions. A genuine stuck message can be retyped from
# the alert text. RC_DRAFT_AUTOCLEAR=0 restores pure alert-only.
DRAFT_AUTOCLEAR="${RC_DRAFT_AUTOCLEAR:-1}"

# Populate DR_* globals from a live capture of the pane.
#   DR_IDLE=<0|1>  DR_KIND=<empty|text|cmd|menu|multiline>  DR_DRAFTABLE=<0|1>
#   DR_TEXT=<draft>  DR_LINES=<non-empty lines inside the input box>
_dr_extract() {  # $1 = pane_id
  local pane_id="$1" full bnums top bot region draftline d
  DR_IDLE=1; DR_KIND=empty; DR_DRAFTABLE=0; DR_TEXT=""; DR_LINES=0
  full=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null || true)
  [ -z "$full" ] && return 0
  # Busy iff the footer (last few lines) shows the interrupt hint.
  if printf '%s\n' "$full" | tail -4 | grep -q 'esc to interrupt'; then DR_IDLE=0; fi
  # The input box is bounded by the last two long ─ border lines; the footer is
  # below the lower border. The draft is the ❯-line strictly between them.
  bnums=$(printf '%s\n' "$full" | grep -nE '─────' | cut -d: -f1 || true)
  top=$(printf '%s\n' "$bnums" | tail -2 | head -1)
  bot=$(printf '%s\n' "$bnums" | tail -1)
  { [ -n "$top" ] && [ -n "$bot" ] && [ "$bot" -gt "$top" ]; } || return 0
  region=$(printf '%s\n' "$full" | sed -n "$((top+1)),$((bot-1))p")
  DR_LINES=$(printf '%s\n' "$region" | grep -c . || true)
  draftline=$(printf '%s\n' "$region" | grep -m1 '^❯' || true)
  [ -n "$draftline" ] || return 0
  d=${draftline#❯}
  # The "empty" input box is NOT really empty: it renders as ❯ + a few
  # placeholder chars (NBSP U+00A0, occasionally ZWSP/BOM). Strip those and any
  # ASCII whitespace LOCALE-INDEPENDENTLY. Cron runs in the C locale, where
  # [:space:] does NOT cover NBSP -- so the old [:space:] trim left the padding
  # in place, misread an empty box as a text draft, and would eventually have
  # auto-drained garbage. printf builds the exact multibyte sequences so we
  # never chop a legit char (ä/é/à share bytes with NBSP) apart.
  local nbsp zwsp bom
  nbsp=$(printf '\302\240'); zwsp=$(printf '\342\200\213'); bom=$(printf '\357\273\277')
  d=${d//$nbsp/ }; d=${d//$zwsp/}; d=${d//$bom/}
  d=$(printf '%s' "$d" | LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  DR_TEXT="$d"
  [ -z "$d" ] && { DR_KIND=empty; return 0; }
  case "$d" in
    [0-9].*|[0-9][0-9].*) DR_KIND=menu ;;   # "1. Yes" style selection cursor
    /*|'!'*)              DR_KIND=cmd  ;;   # slash command / bash-bang
    *)                    DR_KIND=text ;;
  esac
  if [ "${DR_LINES:-0}" -gt 1 ]; then DR_KIND=multiline; fi   # wrapped/multiline
  # Horizontal-truncation guard (2026-07-19): the TUI scrolls a long one-line
  # draft horizontally and renders an ellipsis (U+2026) at the clipped edge, so
  # the capture holds only a FRAGMENT while DR_LINES stays 1. Auto-draining
  # that fragment submits a wrong, cut-off prompt (incident 19.07.2026 -- the
  # clipped tail then resurfaced as a "new" draft one tick later). A draft with
  # the ellipsis char at either end, or whose raw ❯-line fills the pane width,
  # is truncation risk -> alert-only. The width test counts chars via wc -m,
  # which under the cron C locale counts BYTES and thus overshoots for
  # umlauts -- that errs toward "truncated", i.e. toward NOT sending: safe.
  local ell pw dlen
  ell=$(printf '\342\200\246')
  case "$d" in
    "$ell"*|*"$ell") DR_KIND=truncated ;;
  esac
  if [ "$DR_KIND" = text ]; then
    pw=$(tmux display-message -p -t "$pane_id" '#{pane_width}' 2>/dev/null || echo 0)
    dlen=$(printf '%s' "$draftline" | wc -m | tr -d '[:space:]')
    if [ "${pw:-0}" -gt 0 ] 2>/dev/null && [ "${dlen:-0}" -ge $((pw - 1)) ] 2>/dev/null; then
      DR_KIND=truncated
    fi
  fi
  if [ "$DR_KIND" = text ]; then DR_DRAFTABLE=1; fi
  return 0
}

# Grace-period + (safe) remediation for a stuck input draft on a HEALTHY session.
handle_stuck_draft() {  # $1 = pane_id   $2 = sess_name
  local pane_id="$1" sess="$2" key sig prev safe
  key="${sess//[^a-zA-Z0-9]/_}"
  local draft_file="/tmp/claude-remote-watchdog-${key}.draft"
  local dnote_file="/tmp/claude-remote-watchdog-${key}.draftnotified"

  _dr_extract "$pane_id"
  # Box empty or session busy -> nothing stuck; clear grace + dedup (re-arm).
  if [ "$DR_IDLE" != "1" ] || [ "$DR_KIND" = empty ] || [ -z "$DR_TEXT" ]; then
    $DRY_RUN || rm -f "$draft_file" "$dnote_file" 2>/dev/null || true
    return 0
  fi

  sig="$DR_KIND|$DR_TEXT"
  prev=""
  [ -f "$draft_file" ] && prev=$(head -1 "$draft_file" 2>/dev/null || true)
  if [ "$prev" != "$sig" ]; then
    # First sighting, or the draft changed (user is editing) -> (re)start grace.
    $DRY_RUN || printf '%s\n' "$sig" > "$draft_file"
    echo "[DRAFT] $sess: unsent draft seen ($DR_KIND) -- grace started: '${DR_TEXT:0:60}'"
    return 0
  fi
  # Signature unchanged: only act once the grace file is >= DRAFT_STUCK_MIN old.
  if ! find "$draft_file" -maxdepth 0 -mmin +"$DRAFT_STUCK_MIN" 2>/dev/null | grep -q .; then
    echo "[DRAFT] $sess: draft within grace (<${DRAFT_STUCK_MIN} min) -- '${DR_TEXT:0:60}'"
    return 0
  fi

  safe=${DR_TEXT//\\/}; safe=${safe//\"/}   # sanitise for the JSON/osascript alert
  if [ "$DR_DRAFTABLE" = 1 ] && [ "$DRAFT_AUTODRAIN" = "1" ]; then
    if $DRY_RUN; then
      echo "[DRY-RUN][DRAFT] Would auto-drain on $sess: '$DR_TEXT'"
      return 0
    fi
    # Race guard: re-capture right before sending; abort if it changed/moved.
    _dr_extract "$pane_id"
    if [ "$DR_DRAFTABLE" != 1 ] || [ "$DR_IDLE" != "1" ] || [ "$DR_KIND|$DR_TEXT" != "$sig" ]; then
      printf '%s\n' "$DR_KIND|$DR_TEXT" > "$draft_file"
      echo "[DRAFT] $sess: draft moved just before auto-drain -- reconfirming next check"
      return 0
    fi
    echo "[ACTION][DRAFT] Auto-draining stuck message on $sess: '$DR_TEXT'"
    # The proven manual fix: clear the relay-owned draft, retype locally, submit.
    # || true throughout: a pane that vanishes mid-sequence must not abort the run.
    tmux send-keys -t "$pane_id" C-u 2>/dev/null || true; sleep 1
    tmux send-keys -t "$pane_id" -l "$DR_TEXT" 2>/dev/null || true; sleep 1
    tmux send-keys -t "$pane_id" Enter 2>/dev/null || true
    notify_totti "📤 RC-Watchdog: Session $sess hatte eine ungesendete Nachricht (Remote-Submit-Bug) haengen und ich habe sie automatisch abgeschickt: „$safe“"
    rm -f "$draft_file" 2>/dev/null || true   # box empties; next tick re-arms dedup
  else
    # Alert + auto-CLEAR path (2026-07-19c). Ghost drafts (relay-injected,
    # AI-suggested texts the user never typed -- see changelog) are INVISIBLE
    # in the claude.ai client, so Roman cannot see, send, or delete them from
    # his phone; they exist only in the tmux input box. Leaving them there
    # means any stray Enter on a bypass-permissions session submits them as a
    # real prompt. So: alert Totti with the FULL text first (nothing is lost
    # -- a genuine stuck message can be retyped from the alert), then clear
    # the box with Ctrl+U. RC_DRAFT_AUTOCLEAR=0 in notify.env restores pure
    # alert-only. Never cleared in dry-run.
    if [ ! -f "$dnote_file" ]; then
      if [ "$DRAFT_AUTOCLEAR" = "1" ]; then
        notify_totti "⚠️ RC-Watchdog: Session $sess hat seit >${DRAFT_STUCK_MIN} min eine ungesendete Eingabe ($DR_KIND), die ich NICHT sende, sondern aus der Eingabebox LOESCHE: „${safe:0:200}“. Falls die Nachricht echt von dir war: bitte neu senden."
      else
        notify_totti "⚠️ RC-Watchdog: Session $sess hat seit >${DRAFT_STUCK_MIN} min eine ungesendete Eingabe ($DR_KIND), die ich NICHT automatisch sende: „${safe:0:120}“. Bitte am Geraet pruefen und selbst abschicken oder loeschen."
      fi
      $DRY_RUN || touch "$dnote_file"
    fi
    if [ "$DRAFT_AUTOCLEAR" = "1" ]; then
      if $DRY_RUN; then
        echo "[DRY-RUN][DRAFT] Would auto-clear on $sess: '${DR_TEXT:0:60}'"
        return 0
      fi
      # Race guard: re-capture right before clearing; abort if the draft
      # changed or the session went busy (user might be typing right now).
      _dr_extract "$pane_id"
      if [ "$DR_IDLE" != "1" ] || [ "$DR_KIND|$DR_TEXT" != "$sig" ]; then
        printf '%s\n' "$DR_KIND|$DR_TEXT" > "$draft_file"
        echo "[DRAFT] $sess: draft moved just before auto-clear -- reconfirming next check"
        return 0
      fi
      tmux send-keys -t "$pane_id" C-u 2>/dev/null || true; sleep 1
      # Verify: if text is still in the box (e.g. multi-line draft where C-u
      # only cleared one line), say so instead of pretending it is gone.
      _dr_extract "$pane_id"
      if [ "$DR_KIND" = empty ] || [ -z "$DR_TEXT" ]; then
        echo "[ACTION][DRAFT] Auto-cleared stuck draft on $sess (text was alerted via Telegram)"
        rm -f "$draft_file" 2>/dev/null || true   # box empty; next tick re-arms dedup
      else
        echo "[WARN][DRAFT] $sess: C-u did not fully clear the draft -- remaining: '${DR_TEXT:0:60}'"
        printf '%s\n' "$DR_KIND|$DR_TEXT" > "$draft_file"
      fi
    elif [ "$DR_DRAFTABLE" = 1 ]; then
      echo "[DRAFT] $sess: stuck ($DR_KIND) -- auto-drain disabled, alert only"
    else
      echo "[DRAFT] $sess: stuck but not auto-drainable ($DR_KIND) -- alert only"
    fi
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
    # A HEALTHY session (RC connected) can still be silently stuck on an unsent
    # relay draft -- detect + safely auto-submit it (see Stuck-draft watch).
    handle_stuck_draft "$pane_id" "$sess_name"
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
