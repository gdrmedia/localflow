#!/bin/zsh
# Privacy check: list every network socket owned by LocalFlow / localflow-cli processes.
# Run while dictating (or while `localflow-cli --file` runs). Expected output: nothing.
set -u
pids=$(pgrep -f -i "localflow" | tr '\n' ',' | sed 's/,$//')
if [[ -z "$pids" ]]; then echo "no LocalFlow process running"; exit 0; fi
echo "LocalFlow pids: $pids"
out=$(lsof -a -i -P -n -p "$pids" 2>/dev/null)
if [[ -z "$out" ]]; then echo "OK: zero network sockets"; else echo "$out"; exit 1; fi
