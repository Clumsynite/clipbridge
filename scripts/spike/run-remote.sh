#!/usr/bin/env bash
# Runs on the remote. Starts Claude Code in tmux, presses Ctrl+V, checks for [Image #1].
# Usage: run-remote.sh [--real]   (--real: no stub, real login-shell PATH)
set -u
MODE=${1:-stub}
for c in claude tmux python3; do command -v "$c" >/dev/null || { echo "missing $c"; exit 2; }; done
B=$HOME/.cache/cb-spike
mkdir -p "$B/bin" "$B/ws"
if [ "$MODE" != "--real" ]; then
  install -m 0755 "$B/stub-xclip" "$B/bin/xclip"
  CMD="env -u DISPLAY PATH=$B/bin:\$PATH $(command -v claude)"
else
  CMD="env -u DISPLAY \$SHELL -lic claude"
fi
S=cbspike-$$
tmux kill-session -t "$S" 2>/dev/null
tmux new-session -d -s "$S" -x 200 -y 50 -c "$B/ws" "$CMD"
pane() { tmux capture-pane -p -t "$S" 2>/dev/null; }
finish() {
  { echo "== mode $MODE exit $1"; echo "== pane"; pane; echo "== log"; cat "$B/log" 2>/dev/null; } > "$B/result-$S.txt"
  tmux send-keys -t "$S" Escape 2>/dev/null; sleep 0.3
  tmux send-keys -t "$S" C-c 2>/dev/null; sleep 0.3; tmux send-keys -t "$S" C-c 2>/dev/null; sleep 0.5
  tmux kill-session -t "$S" 2>/dev/null
  echo "RESULT $B/result-$S.txt"
  exit "$1"
}
trusted=0; ready=0
for _ in $(seq 1 40); do
  sleep 1
  p=$(pane)
  if [ -z "$p" ] && ! tmux has-session -t "$S" 2>/dev/null; then echo "session died"; finish 3; fi
  if echo "$p" | grep -qiE 'trust this folder|Quick safety check|Do you trust'; then
    if [ $trusted -eq 0 ]; then tmux send-keys -t "$S" Enter; trusted=1; fi
    continue
  fi
  if echo "$p" | grep -qiE 'Select login method|login|choose the text style|theme'; then
    echo "$p" | grep -qE '(│ >|^> |❯)' || finish 3
  fi
  if echo "$p" | grep -qE '(│ >|^ *> |❯)'; then ready=1; break; fi
done
[ $ready -eq 1 ] || finish 3
sleep 1
tmux send-keys -t "$S" C-v
for _ in $(seq 1 10); do
  sleep 1
  pane | grep -q '\[Image #1\]' && finish 0
done
finish 4
