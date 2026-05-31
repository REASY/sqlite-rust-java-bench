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
# warm-up. RSS is still process-level max RSS from the platform time tool.
#
# Outputs:
#   ${SQLITE_BENCH_RUN_DIR:-${TMPDIR:-/tmp}/sqlite-build-flags-bench-runs}/results.tsv
#
# Optional overrides:
#   SQLITE_BENCH_REPO       repository root to use
#   SQLITE_BENCH_RUN_DIR    directory for worktrees, logs, DBs, and results
#   SQLITE_BENCH_TIME_BIN   time binary, default /usr/bin/time
#   SQLITE_BENCH_TIME_STYLE bsd or gnu, otherwise auto-detected
#   CARGO                   cargo binary, default cargo
#   GRADLE_BIN              gradle binary, default gradle

commits=(
  "f6c2aae:initial"
  "22a17e9:diagnostics"
  "053bf0f:rust_build_parity"
  "d81712c:shared_values"
)

main() {
  if [[ "${RUNNER_SELF_TEST:-}" == "1" ]]; then
    self_test
    return
  fi

  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  repo="${SQLITE_BENCH_REPO:-$(git -C "$script_dir/.." rev-parse --show-toplevel)}"
  base="${SQLITE_BENCH_RUN_DIR:-${TMPDIR:-/tmp}/sqlite-build-flags-bench-runs}"
  base="${base%/}"
  out="$base/results.tsv"
  compile_options_dir="$base/compile-options"
  time_bin="${SQLITE_BENCH_TIME_BIN:-/usr/bin/time}"
  time_style="${SQLITE_BENCH_TIME_STYLE:-$(detect_time_style)}"
  cargo_bin="${CARGO:-cargo}"
  gradle_bin="${GRADLE_BIN:-gradle}"

  mkdir -p "$base" "$compile_options_dir"

  local header
  header="commit\tlabel\tlanguage\twrites_per_s\tread_p50_us\tread_p75_us\tread_p90_us\tread_p95_us\tread_p99_us\tmax_rss_bytes\tcompile_options_file"
  printf "%b\n" "$header" > "$out"
  printf "%b\n" "$header"

  local item
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
}

run_one() {
  local commit="$1"
  local label="$2"
  local lang="$3"
  local wt="$base/$commit"
  local db="$base/sqlite-bench-${commit}-${lang}-$$.sqlite"
  local log="$base/${commit}-${lang}.log"
  local compile_options_file="$compile_options_dir/${commit}-${lang}.txt"

  if [[ "$lang" == "rust" ]]; then
    run_timed "$log" "$wt/rust/target/release/sqlite-build-flags-bench" \
      --db-path "$db" \
      --rows 500000 \
      --value-bytes 5700 \
      --batch-size 20000 \
      --read-threads 10 \
      --read-interval-us 1000 \
      --duration-secs 30 \
      --warmup-secs 5 \
      --read-mode value
  else
    run_timed "$log" "$wt/java/build/install/sqlite-build-flags-bench-java/bin/sqlite-build-flags-bench-java" \
      --db-path "$db" \
      --rows 500000 \
      --value-bytes 5700 \
      --batch-size 20000 \
      --read-threads 10 \
      --read-interval-us 1000 \
      --duration-secs 30 \
      --warmup-secs 5 \
      --read-mode value
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
  rss="$(parse_rss_bytes "$log")"
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
    "$cargo_bin" clean
    "$cargo_bin" build --release
  )

  (
    cd "$wt/java"
    "$gradle_bin" clean installDist
  )
}

detect_time_style() {
  if [[ ! -x "$time_bin" ]]; then
    echo "time binary is not executable: $time_bin" >&2
    return 1
  fi
  if "$time_bin" -l true >/dev/null 2>&1; then
    printf "bsd\n"
  elif "$time_bin" -v true >/dev/null 2>&1; then
    printf "gnu\n"
  else
    echo "$time_bin supports neither BSD -l nor GNU -v output" >&2
    return 1
  fi
}

run_timed() {
  local log="$1"
  shift
  case "$time_style" in
    bsd)
      "$time_bin" -l "$@" > "$log" 2>&1
      ;;
    gnu)
      "$time_bin" -v "$@" > "$log" 2>&1
      ;;
    *)
      echo "unsupported time style: $time_style" >&2
      return 1
      ;;
  esac
}

parse_rss_bytes() {
  local log="$1"
  awk '
    /maximum resident set size/ {
      print $1
      found = 1
      exit
    }
    /Maximum resident set size \(kbytes\):/ {
      printf "%.0f\n", $6 * 1024
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$log"
}

self_test() {
  local tmp
  tmp="$(mktemp -d)"

  printf "123456  maximum resident set size\n" > "$tmp/bsd-time.log"
  [[ "$(parse_rss_bytes "$tmp/bsd-time.log")" == "123456" ]]

  printf "Maximum resident set size (kbytes): 789\n" > "$tmp/gnu-time.log"
  [[ "$(parse_rss_bytes "$tmp/gnu-time.log")" == "807936" ]]

  rm -rf "$tmp"
  printf "runner portability self-test ok\n"
}

main "$@"
