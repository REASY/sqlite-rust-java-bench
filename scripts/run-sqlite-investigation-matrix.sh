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
#   RUSTC                   rustc binary, default rustc
#   GRADLE_BIN              gradle binary, default gradle
#
# Fast prerequisite check:
#   scripts/run-sqlite-investigation-matrix.sh --preflight

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

  local preflight_only=0
  if [[ "${1:-}" == "--preflight" ]]; then
    preflight_only=1
    shift
  fi
  if (( $# > 0 )); then
    echo "usage: $0 [--preflight]" >&2
    return 2
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
  rustc_bin="${RUSTC:-rustc}"
  gradle_bin="${GRADLE_BIN:-gradle}"

  mkdir -p "$base" "$compile_options_dir"
  preflight
  if (( preflight_only )) || [[ "${RUNNER_PREFLIGHT_ONLY:-}" == "1" ]]; then
    printf "runner preflight ok\n"
    return
  fi

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
      run_logged "$base/${commit}-worktree.log" git -C "$repo" worktree add --detach "$wt" "$commit"
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
  local rust_build_log="$base/${commit}-rust-build.log"
  local java_build_log="$base/${commit}-java-build.log"

  run_logged "$rust_build_log" bash -c '
    set -euo pipefail
    cd "$1"
    "$2" clean
    "$2" build --release
  ' bash "$wt/rust" "$cargo_bin"

  run_logged "$java_build_log" bash -c '
    set -euo pipefail
    cd "$1"
    "$2" clean installDist
  ' bash "$wt/java" "$gradle_bin"
}

run_logged() {
  local log="$1"
  shift
  if ! "$@" > "$log" 2>&1; then
    echo "command failed: $*" >&2
    echo "log: $log" >&2
    cat "$log" >&2
    return 1
  fi
}

preflight() {
  local failed=0

  require_command git "git" || failed=1
  require_command awk "awk" || failed=1
  require_command "$cargo_bin" "cargo" || failed=1
  require_command "$rustc_bin" "rustc" || failed=1
  require_command "$gradle_bin" "gradle" || failed=1

  if (( failed )); then
    cat >&2 <<EOF

Install the missing tools, or point the runner at custom binaries:
  CARGO=/path/to/cargo
  RUSTC=/path/to/rustc
  GRADLE_BIN=/path/to/gradle
EOF
    return 1
  fi

  "$cargo_bin" --version >/dev/null
  "$rustc_bin" --version >/dev/null
  "$gradle_bin" --version >/dev/null
  check_java25_toolchain
}

require_command() {
  local command_name="$1"
  local display_name="$2"

  if ! command -v -- "$command_name" >/dev/null 2>&1; then
    echo "missing required tool: $display_name ($command_name)" >&2
    return 1
  fi
}

check_java25_toolchain() {
  local toolchains_log="$base/java-toolchains.log"

  if ! "$gradle_bin" -p "$repo/java" -q javaToolchains > "$toolchains_log" 2>&1; then
    cat >&2 <<EOF
gradle is installed, but Gradle could not list Java toolchains.
See: $toolchains_log
EOF
    return 1
  fi

  if ! has_java25_azul_toolchain "$toolchains_log"; then
    cat >&2 <<EOF
Gradle does not see an Azul Java 25 toolchain, but java/build.gradle.kts requires:
  languageVersion = 25
  vendor = Azul

Install an Azul/Zulu JDK 25 and make sure Gradle can discover it.
You can inspect detected toolchains with:
  $gradle_bin -p "$repo/java" -q javaToolchains

Full toolchain report:
  $toolchains_log
EOF
    return 1
  fi
}

has_java25_azul_toolchain() {
  local toolchains_log="$1"

  awk '
    /^\+/ {
      if (language25 && vendor_azul) {
        found = 1
      }
      language25 = 0
      vendor_azul = 0
    }
    /Language Version:[[:space:]]*25/ {
      language25 = 1
    }
    /Vendor:[[:space:]]*.*(Azul|Zulu)/ {
      vendor_azul = 1
    }
    END {
      if (language25 && vendor_azul) {
        found = 1
      }
      exit found ? 0 : 1
    }
  ' "$toolchains_log"
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

  cat > "$tmp/java-toolchains-ok.log" <<'EOF'
+ Azul Zulu JDK 25.0.1
    | Vendor:             Azul Systems
    | Language Version:   25
EOF
  has_java25_azul_toolchain "$tmp/java-toolchains-ok.log"

  cat > "$tmp/java-toolchains-missing.log" <<'EOF'
+ Debian JDK 21
    | Vendor:             Debian
    | Language Version:   21
EOF
  ! has_java25_azul_toolchain "$tmp/java-toolchains-missing.log"

  local fake_bin
  fake_bin="$tmp/bin"
  mkdir -p "$fake_bin" "$tmp/repo/java" "$tmp/base"
  cat > "$fake_bin/cargo" <<'EOF'
#!/usr/bin/env bash
echo "cargo 1.0.0"
EOF
  cat > "$fake_bin/rustc" <<'EOF'
#!/usr/bin/env bash
echo "rustc 1.0.0"
EOF
  cat > "$fake_bin/gradle" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"javaToolchains"* ]]; then
  cat "$FAKE_JAVA_TOOLCHAINS"
else
  echo "Gradle 1.0"
fi
EOF
  chmod +x "$fake_bin/cargo" "$fake_bin/rustc" "$fake_bin/gradle"

  repo="$tmp/repo"
  base="$tmp/base"
  cargo_bin="$fake_bin/cargo"
  rustc_bin="$fake_bin/rustc"
  gradle_bin="$fake_bin/gradle"
  FAKE_JAVA_TOOLCHAINS="$tmp/java-toolchains-ok.log" preflight

  cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
echo "git operational output"
EOF
  chmod +x "$fake_bin/git"
  [[ -z "$(run_logged "$tmp/worktree.log" "$fake_bin/git" worktree add)" ]]
  [[ -s "$tmp/worktree.log" ]]

  rm -rf "$tmp"
  printf "runner portability self-test ok\n"
}

main "$@"
