# Benchmark Notes

This repo is intentionally small and sanitized. It uses generated keys and
deterministic value bytes rather than production data.

## Baseline

Rust uses bundled SQLite through `rusqlite`.
Java uses xerial SQLite JDBC.

Initial result to investigate: Rust appears slower than Java under the same
workload shape.
