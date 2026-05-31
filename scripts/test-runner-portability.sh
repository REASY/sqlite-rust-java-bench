#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runner="$script_dir/run-sqlite-investigation-matrix.sh"

if grep -Eq '"/Users/abalaian|="/private/tmp|db="/private/tmp' "$runner"; then
  echo "runner still contains machine-specific absolute paths" >&2
  exit 1
fi

RUNNER_SELF_TEST=1 "$runner"
