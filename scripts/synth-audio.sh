#!/bin/zsh
# Render eval cases to 16 kHz mono Float32 WAV files with macOS `say` + `afconvert`.
# Output: eval/audio/case-<id>.wav (gitignored). Usage: scripts/synth-audio.sh [ids...]
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p eval/audio
EN_VOICE="${EN_VOICE:-Samantha}"
ES_VOICE="${ES_VOICE:-Paulina}"
say -v '?' | grep -q "^${EN_VOICE} " || EN_VOICE="Alex"
IDS=("$@")
[[ ${#IDS[@]} -eq 0 ]] && IDS=(1 2 3 7 8 9 10 11 13 15 17 21)
for id in "${IDS[@]}"; do
  line=$(grep "\"id\":${id}," eval/cases.jsonl || true)
  [[ -z "$line" ]] && { echo "no case $id"; continue; }
  text=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["input"])' "$line")
  voice="$EN_VOICE"
  echo "$line" | grep -q '"spanish"' && voice="$ES_VOICE"
  aiff="eval/audio/case-${id}.aiff"; wav="eval/audio/case-${id}.wav"
  say -v "$voice" -o "$aiff" "$text"
  afconvert -f WAVE -d LEF32@16000 -c 1 "$aiff" "$wav"
  rm -f "$aiff"
  dur=$(afinfo "$wav" | awk '/estimated duration/ {print $3}')
  echo "case-${id}.wav  ${dur}s  [$voice]  $text"
done
