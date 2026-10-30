#!/bin/bash
# Times every downloaded Parakeet model on one recording: load, a cold and a warm pass, memory and the words.
# Usage: tests/evals/speech_bench.sh <audio file> [model ...]   (models: v3 ultra redux v2; default: all four)
# The same recording on an otherwise idle Mac compares models and Macs. Models download in Settings → Dictation.
set -e
audio=${1:?usage: tests/evals/speech_bench.sh <audio file> [model ...]}; shift
helper=${AUREL_PARAKEET:-$HOME/Applications/Aurel.app/Contents/MacOS/aurel-parakeet}
[ -x "$helper" ] || { echo "No Parakeet helper at $helper. Run ./build.sh first."; exit 1; }
for model in "${@:-v3 ultra redux v2}"; do
  for m in $model; do
    [ -f "${AUREL_DIR:-$HOME/.config/aurel}/parakeet/$m" ] || { echo "== $m: not downloaded"; continue; }
    echo "== $m"; "$helper" bench "$m" "$audio" || true
  done
done
