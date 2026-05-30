# SQLite Build Flags Bench

A small, sanitized companion repo for investigating why SQLite initially
looked slower through Rust than through Java.

The workload is intentionally generic:

- deterministic cache keys
- fixed-size value buffers
- SQLite WAL mode
- batched upserts
- concurrent point-read probes

The interesting part of this repo is the commit history. Each commit
represents one step in the investigation.
