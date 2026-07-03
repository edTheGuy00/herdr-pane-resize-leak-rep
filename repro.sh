#!/usr/bin/env bash
# In-container harness: reproduces the herdr direct-attach resize-lock leak.
#
# Topology: one "desktop" herdr TUI client (200x50, in tmux) + one small wire
# client (20x40) that attaches terminal A, re-points to terminal B on the SAME
# connection (AttachTerminal { takeover: true } — what any multiplexing/mobile
# relay does when its user navigates panes), then disconnects.
#
# Expected on a FIXED herdr: pane A returns to the desktop layout size once the
# wire client leaves it (and certainly after it disconnects).
# Actual on herdr <= 0.7.1 / master: pane A stays at 20x40 forever.
#
# Exit code: 1 when the bug reproduces (A stuck small), 0 when behavior is
# correct — so this doubles as a regression test.
set -euo pipefail

SMALL_ROWS=${SMALL_ROWS:-20}
SMALL_COLS=${SMALL_COLS:-40}
DESK_COLS=${DESK_COLS:-200}
DESK_ROWS=${DESK_ROWS:-50}

echo ">> herdr version: $(herdr --version)"
echo ">> starting desktop herdr TUI client (${DESK_COLS}x${DESK_ROWS}) in tmux"
tmux new-session -d -s desk -x "$DESK_COLS" -y "$DESK_ROWS" herdr

CLIENT_SOCK="$HOME/.config/herdr/herdr-client.sock"
for _ in $(seq 1 100); do [ -S "$CLIENT_SOCK" ] && break; sleep 0.2; done
[ -S "$CLIENT_SOCK" ] || { echo "!! herdr client socket never appeared"; exit 2; }
sleep 1.5

echo ">> creating a second tab (terminal B)"
herdr tab create >/dev/null
sleep 1

mapfile -t TERMS < <(herdr pane list | grep -oE 'term_[0-9a-f]+')
[ "${#TERMS[@]}" -ge 2 ] || { echo "!! expected 2 panes, got: ${TERMS[*]:-none}"; exit 2; }
TERM_A=${TERMS[0]} TERM_B=${TERMS[1]}
echo ">> terminal A=$TERM_A (tab 1)   terminal B=$TERM_B (tab 2)"

# Pane shells are children of the herdr server, in spawn (pid) order: A then B.
SRV=$(pgrep -f 'herdr server' | head -1)
for _ in $(seq 1 50); do
  mapfile -t SHELLS < <(ps --ppid "$SRV" -o pid= | sort -n)
  [ "${#SHELLS[@]}" -ge 2 ] && break; sleep 0.2
done
[ "${#SHELLS[@]}" -ge 2 ] || { echo "!! expected 2 pane shells under server pid $SRV"; exit 2; }
PTY_A=$(readlink "/proc/$(echo "${SHELLS[0]}" | tr -d ' ')/fd/0")
PTY_B=$(readlink "/proc/$(echo "${SHELLS[1]}" | tr -d ' ')/fd/0")
echo ">> pane PTYs: A=$PTY_A  B=$PTY_B"

sz() { stty -F "$1" size | awk '{print $1"x"$2}'; }
measure() { printf '   %-32s A=%-8s B=%s\n' "$1" "$(sz "$PTY_A")" "$(sz "$PTY_B")"; }

FIFO=/tmp/repro.in; OUT=/tmp/repro.out
mkfifo "$FIFO"
herdr-pane-resize-leak-rep "$CLIENT_SOCK" "$TERM_A" "$TERM_B" "$SMALL_ROWS" "$SMALL_COLS" \
  < "$FIFO" > "$OUT" 2>&1 &
exec 9>"$FIFO"

echo
echo ">> phases (small client is ${SMALL_ROWS}x${SMALL_COLS}):"
BASE_A=$(sz "$PTY_A")
measure "baseline"
for phase in ATTACHED_A SWITCHED_TO_B DISCONNECTED; do
  for _ in $(seq 1 100); do grep -q "PHASE:$phase" "$OUT" 2>/dev/null && break; sleep 0.2; done
  grep -q "PHASE:$phase" "$OUT" || { echo "!! wire client never reached $phase"; cat "$OUT"; exit 2; }
  sleep 1.5   # let the server settle / desktop re-render
  case $phase in
    ATTACHED_A)    measure "small client attached to A" ;;
    SWITCHED_TO_B) measure "small client switched A -> B" ;;
    DISCONNECTED)  measure "small client disconnected" ;;
  esac
  echo >&9
done
exec 9>&-
wait || true

FINAL_A=$(sz "$PTY_A")
echo
if [ "$FINAL_A" != "$BASE_A" ]; then
  echo "❌ BUG REPRODUCED: pane A is stuck at $FINAL_A (baseline $BASE_A) after the"
  echo "   attach client left it and disconnected. Its direct_attach_resize_locks /"
  echo "   terminal_attach_owners entries leaked, so the desktop layout resize pass"
  echo "   will skip it forever (until something re-attaches + detaches exactly A)."
  exit 1
else
  echo "✅ behavior correct: pane A restored to $BASE_A after the attach client moved away."
  exit 0
fi
