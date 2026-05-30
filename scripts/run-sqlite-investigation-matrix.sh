#!/usr/bin/env bash
set -euo pipefail

# Runs the article's commit-by-commit SQLite investigation matrix.
#
# Each benchmark process performs an in-process warm-up before the measured
# interval:
#
#   --warmup-secs 5
#
# The app-level writes/s timer excludes process startup, row generation, and
# warm-up. RSS is still process-level max RSS from /usr/bin/time -l.
#
# Outputs:
#   /private/tmp/sqlite-build-flags-bench-runs/results.tsv
#
# macOS is assumed because RSS is collected with /usr/bin/time -l.

repo="/Users/abalaian/github/REASY/sqlite-build-flags-bench"
base="/private/tmp/sqlite-build-flags-bench-runs"
out="$base/results.tsv"
compile_options_dir="$base/compile-options"
mkdir -p "$base"
mkdir -p "$compile_options_dir"

header="commit\tlabel\tlanguage\twrites_per_s\tread_p50_us\tread_p75_us\tread_p90_us\tread_p95_us\tread_p99_us\tmax_rss_bytes\tcompile_options_file"
printf "%b\n" "$header" > "$out"
printf "%b\n" "$header"

commits=(
  "f6c2aae:initial"
  "22a17e9:diagnostics"
  "053bf0f:rust_build_parity"
  "d81712c:shared_values"
)

run_one() {
  local commit="$1"
  local label="$2"
  local lang="$3"
  local wt="$base/$commit"
  local db="/private/tmp/sqlite-bench-${commit}-${lang}-$$.sqlite"
  local log="$base/${commit}-${lang}.log"
  local compile_options_file="$compile_options_dir/${commit}-${lang}.txt"

  if [[ "$lang" == "rust" ]]; then
    /usr/bin/time -l "$wt/rust/target/release/sqlite-build-flags-bench" \
      --db-path "$db" \
      --rows 500000 \
      --value-bytes 5700 \
      --batch-size 20000 \
      --read-threads 10 \
      --read-interval-us 1000 \
      --duration-secs 30 \
      --warmup-secs 5 \
      --read-mode value > "$log" 2>&1
  else
    /usr/bin/time -l "$wt/java/build/install/sqlite-build-flags-bench-java/bin/sqlite-build-flags-bench-java" \
      --db-path "$db" \
      --rows 500000 \
      --value-bytes 5700 \
      --batch-size 20000 \
      --read-threads 10 \
      --read-interval-us 1000 \
      --duration-secs 30 \
      --warmup-secs 5 \
      --read-mode value > "$log" 2>&1
  fi

  local writes
  local p50
  local p75
  local p90
  local p95
  local p99
  local rss
  writes="$(awk -F'[()]' '/wrote/ { split($2, a, " "); print a[1]; exit }' "$log")"
  p50="$(awk -F'p50_us=' '/read probe:/ { split($2, a, /[^0-9]/); print a[1]; exit }' "$log")"
  p75="$(awk -F'p75_us=' '/read probe:/ { split($2, a, /[^0-9]/); print a[1]; exit }' "$log")"
  p90="$(awk -F'p90_us=' '/read probe:/ { split($2, a, /[^0-9]/); print a[1]; exit }' "$log")"
  p95="$(awk -F'p95_us=' '/read probe:/ { split($2, a, /[^0-9]/); print a[1]; exit }' "$log")"
  p99="$(awk -F'p99_us=' '/read probe:/ { split($2, a, /[^0-9]/); print a[1]; exit }' "$log")"
  rss="$(awk '/maximum resident set size/ { print $1; exit }' "$log")"
  emit_row "$commit" "$label" "$lang" "$writes" "$p50" "$p75" "$p90" "$p95" "$p99" "$rss" "$compile_options_file"
}

emit_row() {
  local row
  printf -v row "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" "$@"
  printf "%s\n" "$row" | tee -a "$out"
}

dump_compile_options() {
  local commit="$1"
  local lang="$2"
  local wt="$base/$commit"
  local compile_options_file="$compile_options_dir/${commit}-${lang}.txt"

  if [[ "$lang" == "rust" ]]; then
    "$wt/rust/target/release/sqlite-build-flags-bench" \
      --dump-sqlite-compile-options > "$compile_options_file"
  else
    "$wt/java/build/install/sqlite-build-flags-bench-java/bin/sqlite-build-flags-bench-java" \
      --dump-sqlite-compile-options > "$compile_options_file"
  fi
}

build_commit() {
  local commit="$1"
  local wt="$base/$commit"

  (
    cd "$wt/rust"
    cargo clean
    cargo build --release
  )

  (
    cd "$wt/java"
    gradle clean installDist
  )
}

for item in "${commits[@]}"; do
  commit="${item%%:*}"
  label="${item#*:}"
  wt="$base/$commit"
  if [[ ! -e "$wt/.git" ]]; then
    git -C "$repo" worktree add --detach "$wt" "$commit"
  fi
  build_commit "$commit"
  dump_compile_options "$commit" "rust"
  dump_compile_options "$commit" "java"
  run_one "$commit" "$label" "rust"
  run_one "$commit" "$label" "java"
done
