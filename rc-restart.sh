#!/bin/bash
# Startet alle claude-rc-* tmux-Sessions frisch neu (z. B. nach einem
# `brew upgrade claude-code@latest`, damit die neue Claude-Binary geladen wird).
#
# WICHTIG: In diesen Sessions laeuft `claude` als ROOT-Prozess der tmux-Session
# (kein Shell drumherum). Ein `/exit` oder Ctrl-D wuerde daher die ganze Session
# beenden -> deshalb wird hier sauber per kill-session + new-session neu gestartet.
#
# RC ist nach dem Start sofort wieder aktiv (Flag --rc), kein separates
# /remote-control noetig. Verifizieren mit:  ~/.claude/scripts/remote-watchdog.sh
#
# Usage: rc-restart.sh [session ...]
#   ohne Argumente  -> alle Sessions
#   mit Argumenten  -> nur die genannten (z. B. rc-restart.sh claude-rc-egov)
set -u

OBS="/Users/romanmathismacmini/TottiObsidian/TottiObsidian"
EGOV="/Users/romanmathismacmini/Projekte/flowable-egov-apps"

# Session-Definition:  name | arbeitsverzeichnis | claude-startbefehl
DEFS=(
  "claude-rc-1|$OBS|claude --rc --name TottiObsidian-1"
  "claude-rc-2|$OBS|claude --rc --name TottiObsidian-2"
  "claude-rc-3|$OBS|claude --rc --name TottiObsidian-3"
  "claude-rc-4|$OBS|claude --rc --name TottiObsidian-4"
  "claude-rc-egov|$EGOV|claude --rc --dangerously-skip-permissions --name TottiEgov"
)

WANT=("$@")  # leer = alle

want_it() {
  [ ${#WANT[@]} -eq 0 ] && return 0
  local n
  for n in "${WANT[@]}"; do [ "$n" = "$1" ] && return 0; done
  return 1
}

# --- Bridge-Erkennung (2026-07-17) ------------------------------------------
# Eine Session gilt erst als "oben", wenn die RC-Bridge wirklich registriert
# ist: Banner "/remote-control is active" oder der "/rc"-Fusszeilen-Hinweis
# (mit Space oder am Zeilenende -- NICHT "/rc-..." aus Chat-Text). Der blosse
# tmux-/Prozess-Start reicht NICHT (17.07.2026: 2 von 5 Sessions liefen
# perfekt, aber die Bridge kam nie hoch -> unsichtbar auf claude.ai/code).
RC_UP_RE='/rc( |$)|remote.control is active'
BOOT_TIMEOUT=45   # Sekunden Maximum pro Session, bis die Bridge stehen muss
POLL_EVERY=3

bridge_up() {
  tmux capture-pane -p -t "$1" 2>/dev/null | grep -qiE -- "$RC_UP_RE"
}

wait_for_bridge() {
  local name="$1" waited=0
  while (( waited < BOOT_TIMEOUT )); do
    bridge_up "$name" && return 0
    sleep "$POLL_EVERY"; waited=$((waited + POLL_EVERY))
  done
  return 1
}

start_one() {
  local name="$1" cwd="$2" cmd="$3"
  tmux kill-session -t "$name" 2>/dev/null
  sleep 1   # der Control-Plane Zeit geben, die alte Bridge-Registrierung zu schliessen
  tmux new-session -d -s "$name" -c "$cwd" "$cmd"
}

# --- Gatekeeper-Preflight (2026-07-18) ---------------------------------------
# Nach `brew upgrade claude-code@latest` traegt die neue Binary das
# com.apple.quarantine-Attribut. Wird sie damit zum ersten Mal nicht-interaktiv
# gestartet, friert der Prozess bei _dyld_start ein (Gatekeeper-Assessment
# haengt), und der Stau klebt danach am PFAD: auch xattr -d + Ersetzen der
# Datei half nicht, erst mv-weg + sauberer Eintrag unter demselben Namen.
# Praevention: Quarantaene-Flag VOR dem ersten Start entfernen.
CLAUDE_REAL="$(readlink -f "$(command -v claude)" 2>/dev/null || command -v claude)"
if [ -n "$CLAUDE_REAL" ] && xattr -p com.apple.quarantine "$CLAUDE_REAL" >/dev/null 2>&1; then
  echo "⚠ Quarantaene-Flag auf $CLAUDE_REAL gefunden -- entferne es (Gatekeeper-Stau-Praevention)"
  xattr -d com.apple.quarantine "$CLAUDE_REAL" 2>/dev/null || true
fi

echo "=== RC-Restart $(date '+%H:%M:%S') · Claude $(claude --version 2>/dev/null) ==="
for def in "${DEFS[@]}"; do
  IFS='|' read -r name cwd cmd <<< "$def"
  want_it "$name" || continue
  echo "→ $name: neu starten ($cmd)"
  start_one "$name" "$cwd" "$cmd"
  # Stagger (2026-07-17): 5 gleichzeitige `claude --rc`-Boots + parallele
  # Bridge-Registrierungen beim selben Account sind die plausibelste Ursache
  # dafuer, dass am 17.07.2026 2 von 5 Bridges nie hochkamen. Kurze Pause
  # entzerrt Boot-Last und Registrierung.
  sleep 3
done

# --- Auf die Bridges warten, pro Session, mit EINEM automatischen Retry ------
FAILED=()
for def in "${DEFS[@]}"; do
  IFS='|' read -r name cwd cmd <<< "$def"
  want_it "$name" || continue
  if wait_for_bridge "$name"; then
    echo "✓ $name: RC-Bridge steht"
  else
    echo "⟳ $name: Bridge nach ${BOOT_TIMEOUT}s nicht oben -- automatischer Neustart-Retry"
    start_one "$name" "$cwd" "$cmd"
    if wait_for_bridge "$name"; then
      echo "✓ $name: RC-Bridge steht (nach Retry)"
    else
      echo "✗ $name: RC-Bridge auch nach Retry nicht oben -- manuell pruefen (tmux attach -t $name)"
      FAILED+=("$name")
    fi
  fi
done

# --- Sichtbarer Erkennungs-Text pro Session ---------------------------------
# Nach dem Boot bekommt jede neu gestartete Session einen Prompt, der Claude
# dazu bringt, eine eindeutige "bereit"-Zeile auszugeben. Diese Antwort ist
# sowohl im Terminal als auch auf claude.ai/code sichtbar -> Totti erkennt
# visuell, WELCHE Session das ist und dass sie lebt/antwortet.
echo "=== Sende Erkennungs-Text an jede Session ==="
for def in "${DEFS[@]}"; do
  IFS='|' read -r name cwd cmd <<< "$def"
  want_it "$name" || continue
  disp="${cmd##*--name }"              # z. B. "TottiObsidian-1" / "TottiEgov"
  # Text und Enter GETRENNT senden (mit Pause) -> sonst wird bei langem Text
  # + Emoji das Enter nicht sauber uebernommen und der Prompt bleibt haengen.
  tmux send-keys -t "$name" "Antworte NUR mit genau dieser einen Zeile, sonst nichts: === $disp bereit und einsatzbereit ==="
  sleep 1
  tmux send-keys -t "$name" Enter
done
sleep 12
echo "--- Antworten der Sessions ---"
for def in "${DEFS[@]}"; do
  IFS='|' read -r name cwd cmd <<< "$def"
  want_it "$name" || continue
  # Antwortzeile = die '⏺'-Zeile von Claude (nicht die '❯'-Eingabezeile)
  reply=$(tmux capture-pane -p -t "$name" 2>/dev/null | grep -E '^\s*⏺' | tail -1 | sed 's/^[[:space:]]*//')
  printf "  %-16s %s\n" "$name" "${reply:-(noch keine Antwort - kurz warten)}"
done

echo "=== Health-Check ==="
# Hinweis: Wird rc-restart.sh vom Watchdog selbst aufgerufen (Tier-2), haelt
# dieser den Run-Lock -> der Check hier meldet dann nur "[SKIP] Another
# watchdog run is in progress". Das ist gewollt (keine Rekursion).
"$HOME/.claude/scripts/remote-watchdog.sh" 2>&1 | grep -E '\[HEALTHY\]|\[WARN\]|\[DEAD\]|\[SKIP\]|\[OK\]' || true
if (( ${#FAILED[@]} > 0 )); then
  echo "FEHLGESCHLAGEN: ${FAILED[*]} -- Exit 1"
  exit 1
fi
echo "Fertig. (Hinweis: frischer Start = leere Verlaeufe; alte per /resume holbar.)"
