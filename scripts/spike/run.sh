#!/usr/bin/env bash
# Mac side: copy the harness to the remote, run it, fetch the result.
# Usage: run.sh <ssh-alias> [--real]
set -euo pipefail
H=${1:?alias}; MODE=${2:-}
here=$(cd "$(dirname "$0")" && pwd)
ssh -o BatchMode=yes "$H" 'mkdir -p ~/.cache/cb-spike && : > ~/.cache/cb-spike/log'
scp -q -o BatchMode=yes "$here/stub-xclip" "$here/run-remote.sh" "$H:.cache/cb-spike/"
set +e
out=$(ssh -o BatchMode=yes "$H" "chmod +x ~/.cache/cb-spike/run-remote.sh; \"\$SHELL\" -lc '~/.cache/cb-spike/run-remote.sh $MODE'")
rc=$?
set -e
echo "$out"
r=$(echo "$out" | sed -n 's/^RESULT //p')
[ -n "$r" ] && scp -q -o BatchMode=yes "$H:$r" "$here/result-$(date +%Y%m%d-%H%M%S)${MODE:+-real}.txt"
exit $rc
