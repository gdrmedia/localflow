#!/bin/zsh
# Rebuild CLI, run eval + bench + synthesized audio. Output in eval/results/phase3-*.log
set -o pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
CLI=build/DerivedData/Build/Products/Release/localflow-cli
MODEL="${1:-mlx-community/Qwen3-4B-Instruct-2507-4bit}"
SLUG="${MODEL//\//__}"
xcodebuild build -project LocalFlow.xcodeproj -scheme localflow-cli -configuration Release -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -quiet 2>&1 | grep -E "error:" | head -20
echo "=== EVAL $MODEL ==="
$CLI --eval eval/cases.jsonl --model "$MODEL" 2>&1 | tee "eval/results/phase3-eval-$SLUG.log" | tail -60
echo "=== BENCH $MODEL ==="
$CLI --bench --model "$MODEL" --runs 5 2>&1 | tee "eval/results/phase3-bench-$SLUG.log" | tail -12
if [[ "${2:-}" == "files" ]]; then
  echo "=== FILES ==="
  $CLI --file eval/audio/case-*.wav --model "$MODEL" 2>&1 | tee "eval/results/phase3-files-$SLUG.log" | grep -E "audio:|raw:|cleaned:|timing:|p50"
fi
