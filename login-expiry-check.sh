#!/bin/bash
# Warnt rechtzeitig, bevor der Claude-Code-Login ablaeuft (angelegt 13.09.2026).
#
# Warum zwei Quellen:
#   1. Schluesselbund "Claude Code-credentials" -> Feld expiresAt. Das ist der
#      ACCESS-Token und kurzlebig (13.09.2026 gemessen: laeuft noch am selben Tag
#      ab, waehrend die Sitzung "expires in 1 day" anzeigte). Er wird normalerweise
#      still per Refresh-Token erneuert. Als Wochen-Vorwarnung taugt er NICHT --
#      hier dient er nur als Beleg fuer den Fall "abgelaufen und NICHT erneuert".
#   2. Die Fusszeile der laufenden Sitzungen ("Your login expires in N days").
#      Das ist Claude Codes eigene Rechnung auf den echten Login-Horizont und
#      damit die einzige brauchbare Quelle fuer eine Vorwarnung.
#
# Das Skript liest aus dem Schluesselbund NUR das Ablaufdatum, nie einen Token.
#
# Usage: login-expiry-check.sh [--dry-run]
set -u

THRESHOLD_DAYS=7
STATE="$HOME/.claude/.login-expiry-state"
TREND="$HOME/.claude/.login-expiry-trend.log"
TMUX_BIN="$(command -v tmux || echo /opt/homebrew/bin/tmux)"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# Webhook-Adresse aus derselben Quelle wie der Watchdog (nicht im Repo, nie im Log).
NOTIFY_CFG="$HOME/.config/claude-rc-watchdog/notify.env"
[ -f "$NOTIFY_CFG" ] && . "$NOTIFY_CFG"

notify() {
  local msg="$1"
  echo "[LOGIN-WARN] $msg"
  [ "$DRY" -eq 1 ] && return 0
  osascript - "$msg" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
  display notification (item 1 of argv) with title "Claude-Login laeuft ab" sound name "Basso"
end run
APPLESCRIPT
  # Push aufs Handy, falls der n8n-Webhook gesetzt ist (gleiche Variable wie im Watchdog).
  if [ -n "${RC_NOTIFY_WEBHOOK:-}" ]; then
    local payload
    payload=$(python3 -c 'import json,sys; print(json.dumps({"message": sys.argv[1]}))' "$msg" 2>/dev/null) || return 0
    curl -sS -m 15 -o /dev/null -X POST -H 'Content-Type: application/json' \
      --data "$payload" "$RC_NOTIFY_WEBHOOK" >/dev/null 2>&1 \
      && echo "[LOGIN-WARN] Push gesendet" || echo "[LOGIN-WARN] Push fehlgeschlagen"
  fi
}

# --- Quelle 1: Schluesselbund, nur das Datum -------------------------------
ACCESS_LEFT_H=""
raw=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || raw=""
if [ -n "$raw" ]; then
  ACCESS_LEFT_H=$(printf '%s' "$raw" | python3 -c '
import json,sys,time
try:
    e = json.load(sys.stdin)["claudeAiOauth"]["expiresAt"]/1000
    print(round((e - time.time())/3600, 1))
except Exception:
    pass
' 2>/dev/null)
fi
unset raw
[ -n "$ACCESS_LEFT_H" ] && printf '%s\taccess_token_rest_h=%s\n' "$(date '+%Y-%m-%d %H:%M')" "$ACCESS_LEFT_H" >> "$TREND"

# --- Quelle 2: Fusszeile der Sitzungen -------------------------------------
# Beispiele: "Your login expires in 1 day", "... in 5 days", "... in 3 hours"
DAYS_LEFT=""
for s in $("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-rc-'); do
  line=$("$TMUX_BIN" capture-pane -p -S -200 -t "$s" 2>/dev/null | grep -iE "login expires in" | tail -1)
  [ -n "$line" ] || continue
  n=$(printf '%s' "$line" | sed -nE 's/.*expires in ([0-9]+) *(day|hour).*/\1 \2/ip' | head -1)
  [ -n "$n" ] || continue
  num=${n%% *}; unit=${n##* }
  case "$unit" in hour*|Hour*) d=0 ;; *) d=$num ;; esac
  if [ -z "$DAYS_LEFT" ] || [ "$d" -lt "$DAYS_LEFT" ]; then DAYS_LEFT=$d; fi
done

# --- Bewerten ---------------------------------------------------------------
TODAY=$(date '+%Y-%m-%d')
already=$(cat "$STATE" 2>/dev/null || echo "")

msg=""
if [ -n "$DAYS_LEFT" ] && [ "$DAYS_LEFT" -le "$THRESHOLD_DAYS" ]; then
  if [ "$DAYS_LEFT" -eq 0 ]; then
    msg="Claude-Login laeuft HEUTE ab. Am Mac im Terminal:  claude auth login"
  else
    msg="Claude-Login laeuft in $DAYS_LEFT Tag(en) ab. Am Mac im Terminal:  claude auth login"
  fi
elif [ -n "$ACCESS_LEFT_H" ] && [ "${ACCESS_LEFT_H%%.*}" -lt 0 ] 2>/dev/null; then
  # Access-Token abgelaufen und offenbar nicht erneuert -> Vorbote eines harten 401
  msg="Claude-Zugang: Token seit $((0-${ACCESS_LEFT_H%%.*}))h abgelaufen und nicht erneuert. Pruefen:  claude auth status"
fi

if [ -z "$msg" ]; then
  echo "[OK] Kein Handlungsbedarf (Fusszeile: ${DAYS_LEFT:-keine Angabe}, Access-Token noch ${ACCESS_LEFT_H:-?}h)"
  exit 0
fi

if [ "$already" = "$TODAY" ] && [ "$DRY" -eq 0 ]; then
  echo "[SKIP] Heute schon gewarnt ($TODAY)"
  exit 0
fi

notify "$msg"
[ "$DRY" -eq 0 ] && printf '%s' "$TODAY" > "$STATE"
exit 0
