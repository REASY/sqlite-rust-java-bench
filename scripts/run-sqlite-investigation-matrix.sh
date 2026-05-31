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
# warm-up. Resource metrics are process-level values from the platform time
# tool, so they include process startup, row generation, and warm-up.
#
# Outputs:
#   ${SQLITE_BENCH_RUN_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/sqlite-rust-java-bench/runs}/results.tsv
#
# Optional overrides:
#   SQLITE_BENCH_REPO       repository root to use
#   SQLITE_BENCH_RUN_DIR    directory for worktrees, logs, DBs, and results
#   SQLITE_BENCH_CACHE_DIR  cache root for default run and Cargo target dirs
#   SQLITE_BENCH_CARGO_TARGET_ROOT
#                           root for per-commit Cargo target dirs
#   SQLITE_BENCH_CARGO_HOME optional Cargo home override
#   SQLITE_BENCH_CARGO_CLEAN=1
#                           run cargo clean before each release build
#   SQLITE_BENCH_TIME_BIN   time binary, default /usr/bin/time
#   SQLITE_BENCH_TIME_STYLE bsd or gnu, otherwise auto-detected
#   CARGO                   cargo binary, default cargo
#   RUSTC                   rustc binary, default rustc
#   GRADLE_BIN              gradle binary, default gradle
#
# Fast prerequisite check:
#   scripts/run-sqlite-investigation-matrix.sh --preflight
#
# To move all heavy run artifacts off the default cache path, set
# SQLITE_BENCH_CACHE_DIR. SQLITE_BENCH_CARGO_TARGET_ROOT only moves Cargo
# target directories; worktrees, logs, DBs, and results stay under
# SQLITE_BENCH_RUN_DIR or SQLITE_BENCH_CACHE_DIR/runs.

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
  cache_root="${SQLITE_BENCH_CACHE_DIR:-$(default_cache_root)/sqlite-rust-java-bench}"
  base="${SQLITE_BENCH_RUN_DIR:-$cache_root/runs}"
  base="${base%/}"
  out="$base/results.tsv"
  compile_options_dir="$base/compile-options"
  cargo_target_root="${SQLITE_BENCH_CARGO_TARGET_ROOT:-$cache_root/cargo-targets}"
  cargo_home="${SQLITE_BENCH_CARGO_HOME:-${CARGO_HOME:-}}"
  cargo_clean="${SQLITE_BENCH_CARGO_CLEAN:-0}"
  time_bin="${SQLITE_BENCH_TIME_BIN:-/usr/bin/time}"
  time_style="${SQLITE_BENCH_TIME_STYLE:-$(detect_time_style)}"
  cargo_bin="${CARGO:-cargo}"
  rustc_bin="${RUSTC:-rustc}"
  gradle_bin="${GRADLE_BIN:-gradle}"

  mkdir -p "$base" "$compile_options_dir" "$cargo_target_root"
  preflight
  if (( preflight_only )) || [[ "${RUNNER_PREFLIGHT_ONLY:-}" == "1" ]]; then
    printf "runner preflight ok\n"
    return
  fi

  results_header > "$out"
  results_header

  local item
  for item in "${commits[@]}"; do
    commit="${item%%:*}"
    label="${item#*:}"
    wt="$base/$commit"
    ensure_worktree "$commit" "$wt" "$base/${commit}-worktree.log"
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
    run_timed "$log" "$(rust_binary_path "$commit")" \
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
  local elapsed_seconds=""
  local user_seconds=""
  local system_seconds=""
  local cpu_percent=""
  local minor_page_faults=""
  local major_page_faults=""
  local voluntary_context_switches=""
  local involuntary_context_switches=""
  local file_system_inputs=""
  local file_system_outputs=""
  writes="$(awk -F'[()]' '/wrote/ { split($2, a, " "); print a[1]; exit }' "$log")"
  p50="$(awk -F'p50_us=' '/read probe:/ { split($2, a, /[^0-9]/); print a[1]; exit }' "$log")"
  p75="$(awk -F'p75_us=' '/read probe:/ { split($2, a, /[^0-9]/); print a[1]; exit }' "$log")"
  p90="$(awk -F'p90_us=' '/read probe:/ { split($2, a, /[^0-9]/); print a[1]; exit }' "$log")"
  p95="$(awk -F'p95_us=' '/read probe:/ { split($2, a, /[^0-9]/); print a[1]; exit }' "$log")"
  p99="$(awk -F'p99_us=' '/read probe:/ { split($2, a, /[^0-9]/); print a[1]; exit }' "$log")"
  rss="$(parse_rss_bytes "$log")"

  local metric
  local metric_index=0
  while IFS= read -r metric; do
    case "$metric_index" in
      0) elapsed_seconds="$metric" ;;
      1) user_seconds="$metric" ;;
      2) system_seconds="$metric" ;;
      3) cpu_percent="$metric" ;;
      4) minor_page_faults="$metric" ;;
      5) major_page_faults="$metric" ;;
      6) voluntary_context_switches="$metric" ;;
      7) involuntary_context_switches="$metric" ;;
      8) file_system_inputs="$metric" ;;
      9) file_system_outputs="$metric" ;;
    esac
    metric_index=$((metric_index + 1))
  done < <(parse_time_metrics "$log")

  emit_row "$commit" "$label" "$lang" "$writes" "$p50" "$p75" "$p90" "$p95" "$p99" "$rss" "$elapsed_seconds" "$user_seconds" "$system_seconds" "$cpu_percent" "$minor_page_faults" "$major_page_faults" "$voluntary_context_switches" "$involuntary_context_switches" "$file_system_inputs" "$file_system_outputs" "$compile_options_file"
}

emit_row() {
  local row=""
  local value
  for value in "$@"; do
    if [[ -n "$row" ]]; then
      row+=$'\t'
    fi
    row+="$value"
  done
  printf "%s\n" "$row" | tee -a "$out"
}

results_header() {
  printf "%b\n" "commit\tlabel\tlanguage\twrites_per_s\tread_p50_us\tread_p75_us\tread_p90_us\tread_p95_us\tread_p99_us\tmax_rss_bytes\telapsed_seconds\tuser_seconds\tsystem_seconds\tcpu_percent\tminor_page_faults\tmajor_page_faults\tvoluntary_context_switches\tinvoluntary_context_switches\tfile_system_inputs\tfile_system_outputs\tcompile_options_file"
}

dump_compile_options() {
  local commit="$1"
  local lang="$2"
  local wt="$base/$commit"
  local compile_options_file="$compile_options_dir/${commit}-${lang}.txt"

  if [[ "$lang" == "rust" ]]; then
    "$(rust_binary_path "$commit")" \
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
  local cargo_target_dir
  cargo_target_dir="$(rust_target_dir "$commit")"
  local cargo_env=("CARGO_TARGET_DIR=$cargo_target_dir")
  if [[ -n "$cargo_home" ]]; then
    cargo_env+=("CARGO_HOME=$cargo_home")
  fi

  run_logged "$rust_build_log" env "${cargo_env[@]}" bash -c '
    set -euo pipefail
    cd "$1"
    if [[ "$3" == "1" ]]; then
      "$2" clean
    fi
    "$2" build --release
  ' bash "$wt/rust" "$cargo_bin" "$cargo_clean"

  run_logged "$java_build_log" bash -c '
    set -euo pipefail
    cd "$1"
    "$2" clean installDist
  ' bash "$wt/java" "$gradle_bin"
}

rust_binary_path() {
  local commit="$1"
  printf "%s/release/sqlite-build-flags-bench" "$(rust_target_dir "$commit")"
}

rust_target_dir() {
  local commit="$1"
  printf "%s/%s" "$cargo_target_root" "$commit"
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

ensure_worktree() {
  local commit="$1"
  local wt="$2"
  local log="$3"

  if [[ -e "$wt/.git" ]]; then
    return
  fi

  run_logged "$log" git -C "$repo" worktree prune
  run_logged "$log" git -C "$repo" worktree add --detach "$wt" "$commit"
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

default_cache_root() {
  if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    printf "%s\n" "$XDG_CACHE_HOME"
  elif [[ -n "${HOME:-}" ]]; then
    printf "%s/.cache\n" "$HOME"
  else
    printf "%s\n" "${TMPDIR:-/tmp}"
  fi
}

detect_time_style() {
  if [[ ! -x "$time_bin" ]]; then
    echo "time binary is not executable: $time_bin" >&2
    return 1
  fi
  if "$time_bin" -l true >/dev/null 2>&1; then
    printf "bsd\n"
  elif "$time_bin" -pv true >/dev/null 2>&1; then
    printf "gnu\n"
  else
    echo "$time_bin supports neither BSD -l nor GNU -pv output" >&2
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
      "$time_bin" -pv "$@" > "$log" 2>&1
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

parse_time_metrics() {
  local log="$1"
  awk '
    function duration_seconds(value, parts, n) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      n = split(value, parts, ":")
      if (n == 3) {
        return parts[1] * 3600 + parts[2] * 60 + parts[3]
      }
      if (n == 2) {
        return parts[1] * 60 + parts[2]
      }
      return value + 0
    }
    /^[[:space:]]*[0-9.]+[[:space:]]+real[[:space:]]+[0-9.]+[[:space:]]+user[[:space:]]+[0-9.]+[[:space:]]+sys/ {
      elapsed = $1
      user = $3
      sys_seconds = $5
    }
    /^real[[:space:]]+/ {
      elapsed = $2
    }
    /^user[[:space:]]+/ {
      user = $2
    }
    /^sys[[:space:]]+/ {
      sys_seconds = $2
    }
    /User time \(seconds\):/ {
      user = $NF
    }
    /System time \(seconds\):/ {
      sys_seconds = $NF
    }
    /Percent of CPU this job got:/ {
      cpu = $NF
      gsub(/%/, "", cpu)
    }
    /Elapsed \(wall clock\) time.*:/ {
      elapsed = duration_seconds($NF)
    }
    /Minor \(reclaiming a frame\) page faults:/ {
      minor = $NF
    }
    /Major \(requiring I\/O\) page faults:/ {
      major = $NF
    }
    /Voluntary context switches:/ {
      voluntary = $NF
    }
    /Involuntary context switches:/ {
      involuntary = $NF
    }
    /File system inputs:/ {
      fs_inputs = $NF
    }
    /File system outputs:/ {
      fs_outputs = $NF
    }
    /^[[:space:]]*[0-9]+[[:space:]]+page reclaims/ {
      minor = $1
    }
    /^[[:space:]]*[0-9]+[[:space:]]+page faults/ {
      major = $1
    }
    /^[[:space:]]*[0-9]+[[:space:]]+voluntary context switches/ {
      voluntary = $1
    }
    /^[[:space:]]*[0-9]+[[:space:]]+involuntary context switches/ {
      involuntary = $1
    }
    /^[[:space:]]*[0-9]+[[:space:]]+file system inputs/ {
      fs_inputs = $1
    }
    /^[[:space:]]*[0-9]+[[:space:]]+file system outputs/ {
      fs_outputs = $1
    }
    END {
      if (cpu == "" && elapsed != "" && elapsed > 0 && user != "" && sys_seconds != "") {
        cpu = sprintf("%.2f", ((user + sys_seconds) / elapsed) * 100)
      }
      print elapsed
      print user
      print sys_seconds
      print cpu
      print minor
      print major
      print voluntary
      print involuntary
      print fs_inputs
      print fs_outputs
    }
  ' "$log"
}

join_lines() {
  awk '
    {
      if (NR > 1) {
        printf " "
      }
      printf "%s", $0
    }
    END {
      printf "\n"
    }
  '
}

self_test() {
  local tmp
  local metrics
  local row
  tmp="$(mktemp -d)"

  [[ "$(results_header | awk -F'\t' '{ print NF }')" == "21" ]]
  [[ "$(results_header)" == *$'\telapsed_seconds\tuser_seconds\tsystem_seconds\tcpu_percent\tminor_page_faults\tmajor_page_faults\tvoluntary_context_switches\tinvoluntary_context_switches\tfile_system_inputs\tfile_system_outputs\t'* ]]

  out="$tmp/results.tsv"
  row="$(emit_row c l rust 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 file)"
  [[ "$(awk -F'\t' '{ print NF }' "$out")" == "21" ]]
  [[ "$row" == "$(awk '{ print }' "$out")" ]]

  printf "123456  maximum resident set size\n" > "$tmp/bsd-time.log"
  [[ "$(parse_rss_bytes "$tmp/bsd-time.log")" == "123456" ]]

  printf "Maximum resident set size (kbytes): 789\n" > "$tmp/gnu-time.log"
  [[ "$(parse_rss_bytes "$tmp/gnu-time.log")" == "807936" ]]

  cat > "$tmp/gnu-time-metrics.log" <<'EOF'
real 35.25
user 31.50
sys 2.75
	User time (seconds): 31.50
	System time (seconds): 2.75
	Percent of CPU this job got: 97%
	Elapsed (wall clock) time (h:mm:ss or m:ss): 0:35.25
	Minor (reclaiming a frame) page faults: 1234
	Major (requiring I/O) page faults: 5
	Voluntary context switches: 67
	Involuntary context switches: 89
	File system inputs: 101
	File system outputs: 202
EOF
  metrics="$(parse_time_metrics "$tmp/gnu-time-metrics.log" | join_lines)"
  [[ "$metrics" == "35.25 31.50 2.75 97 1234 5 67 89 101 202" ]]

  cat > "$tmp/bsd-time-metrics.log" <<'EOF'
       40.00 real        30.00 user         5.00 sys
              1234  page reclaims
                 5  page faults
                67  voluntary context switches
                89  involuntary context switches
               101  file system inputs
               202  file system outputs
EOF
  metrics="$(parse_time_metrics "$tmp/bsd-time-metrics.log" | join_lines)"
  [[ "$metrics" == "40.00 30.00 5.00 87.50 1234 5 67 89 101 202" ]]

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
if [[ "${1:-}" == "--version" ]]; then
  echo "cargo 1.0.0"
  exit 0
fi
echo "$1:${CARGO_TARGET_DIR:-}:${CARGO_HOME:-}" >> "$FAKE_CARGO_ENV_LOG"
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
  cargo_target_root="$tmp/cargo-targets"
  cargo_home="$tmp/cargo-home"
  cargo_clean=0
  cargo_bin="$fake_bin/cargo"
  rustc_bin="$fake_bin/rustc"
  gradle_bin="$fake_bin/gradle"
  FAKE_JAVA_TOOLCHAINS="$tmp/java-toolchains-ok.log" preflight

  mkdir -p "$base/fake/rust" "$base/fake/java"
  FAKE_CARGO_ENV_LOG="$tmp/cargo-env.log" build_commit "fake"
  grep -q "^build:$cargo_target_root/fake:$cargo_home$" "$tmp/cargo-env.log"
  ! grep -q "^clean:" "$tmp/cargo-env.log"

  cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${FAKE_GIT_LOG:-}" ]]; then
  printf "%s\n" "$*" >> "$FAKE_GIT_LOG"
fi
echo "git operational output"
EOF
  chmod +x "$fake_bin/git"
  PATH="$fake_bin:$PATH" FAKE_GIT_LOG="$tmp/git.log" ensure_worktree "abc1234" "$base/abc1234" "$tmp/worktree.log"
  grep -q -- "^-C $repo worktree prune$" "$tmp/git.log"
  grep -q -- "^-C $repo worktree add --detach $base/abc1234 abc1234$" "$tmp/git.log"

  [[ -z "$(run_logged "$tmp/worktree.log" "$fake_bin/git" worktree add)" ]]
  [[ -s "$tmp/worktree.log" ]]

  rm -rf "$tmp"
  printf "runner portability self-test ok\n"
}

main "$@"
