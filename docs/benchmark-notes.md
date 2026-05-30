# Benchmark Notes

This repo is intentionally small and sanitized. It uses generated keys and
deterministic value bytes rather than production data.

## Baseline

Rust uses bundled SQLite through `rusqlite`.
Java uses xerial SQLite JDBC.

Initial result to investigate: Rust appears slower than Java under the same
workload shape.

## Added Measurements

The benchmark now has read modes:

- `exists`: `SELECT 1`
- `metadata`: `SELECT expires_at_ms`
- `value`: `SELECT value`

The important observation is whether the gap exists even when SQLite does
not need to materialize the blob. If it does, blob copying is not the main
read-latency cause.


    ## Raw Rust Read Probe

    Replacing `query_row` with raw bind/query is a useful control. If this does
    not close the gap, the wrapper path is not the primary issue.
    

    ## SQLite Compile Options

    Both binaries expose `--dump-sqlite-compile-options`, which prints runtime
    `PRAGMA compile_options`.

    This is the key diagnostic step: compare the actual SQLite C libraries, not
    just the Rust and Java wrapper code.
    

    ## Rust Build Parity

    Rust's bundled SQLite can be rebuilt with flags closer to xerial's hot-path
    behavior, and the Rust release profile can use single-codegen-unit fat LTO:

    ```toml
    [env]
    LIBSQLITE3_FLAGS = "-DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DISABLE_PAGECACHE_OVERFLOW_STATS -USQLITE_ENABLE_API_ARMOR -USQLITE_ENABLE_MEMORY_MANAGEMENT"

    [profile.release]
    lto = "fat"
    codegen-units = 1
    panic = "abort"
    ```

    After this change, Rust and Java should converge if the root cause was the
    SQLite C build rather than the wrapper language.
    