#!/usr/bin/env bash
# Build an ACPF token profile from a GGUF tokenizer using the offline builder. The
# defaults target Qwen3.5/3.6 (shared tokenizer); override the env vars below to drive
# the same script for other tokenizer families.
#
#     FAMILY=qwen3-v151936     # label stamped into the profile header
#     GGUF=...                 # source GGUF path (default: ModelContainer.modelURL())
#     OUT=...                  # output .acpf.bin path (default: profileURL(family:))
#
# The output lives under ~/Library/Application Support/KeyType/Models/, never inside
# the repo. The builder runs ProfileSelfCheck against the produced file before exiting.

set -euo pipefail

FAMILY="${FAMILY:-qwen3-v151936}"
DEFAULT_GGUF="$HOME/Library/Application Support/KeyType/Models/Qwen3.5-2B-Base-Q4_K_M.gguf"
GGUF="${GGUF:-$DEFAULT_GGUF}"
OUT="${OUT:-$HOME/Library/Application Support/KeyType/Models/${FAMILY}.acpf.bin}"

cd "$(dirname "$0")/.."

if [[ ! -f "$GGUF" ]]; then
    echo "Source GGUF not found at: $GGUF" 1>&2
    echo "Set GGUF=/path/to/model.gguf or place the file at the default location." 1>&2
    exit 1
fi

swift run -c release --package-path Packages/ProfileBuilder acpf-build \
    --family "$FAMILY" \
    --gguf "$GGUF" \
    --output "$OUT" \
    --force

echo "Wrote $OUT"
