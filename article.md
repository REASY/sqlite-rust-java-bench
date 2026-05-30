# Why SQLite Looked Slower in Rust Than Java

I was evaluating whether SQLite could be a practical embedded cache for a
high-throughput key-value workload. The shape is simple: updates arrive
continuously, each update writes one cache entry, and the serving path needs
fast point reads by key. Today that kind of workload is often handled by a
remote Redis-compatible key-value store. I wanted to test a smaller question: if
the cache lived locally in SQLite with WAL mode enabled, could it sustain enough
writes while still serving point reads by key?

The benchmark used production-sized opaque value buffers and then expanded them
into a larger local workload:

- 500 source value buffers
- roughly 5.7 KiB average value size
- 500,000 generated rows by mutating only indexed key fields
- cache keys shaped like `entity | date | variant | supplier`
- SQLite in WAL mode with `synchronous=NORMAL`
- 20,000-row write batches
- 10 concurrent read probes with a 1 ms interval

The table was simple: one indexed key, an expiry timestamp, and the raw
opaque value bytes.

```sql
CREATE TABLE cache (
  key TEXT PRIMARY KEY,
  expires_at_ms INTEGER NOT NULL,
  value BLOB NOT NULL
) WITHOUT ROWID;
```

At first the Java 25 version looked better on write throughput, while Rust used
far more memory. The read-latency picture was mixed even in the first run, which
was the first hint that this was not a simple "Java is faster than Rust" story.
SQLite is a C library in both cases. Rust calls it through `rusqlite`; Java
calls it through xerial's SQLite JDBC driver. The wrapper layer is different,
but the storage engine is still SQLite.

The initial temptation was to treat this as a Rust-vs-Java result. That turned
out to be the wrong frame.

## Reproducing the Investigation

I kept the benchmark history in small commits so the investigation is
re-runnable instead of just described. The runner is:

```bash
scripts/run-sqlite-investigation-matrix.sh
```

Each process does a 5-second in-process warm-up before the measured 30-second
window. Write throughput and read latency come from the benchmark's measured
window. RSS is max process RSS from `/usr/bin/time -l`, so it includes row
generation and warm-up allocation.

One run on my machine looked like this:

| Commit | What changed | Rust writes/s | Java writes/s | Rust RSS | Java RSS |
|---|---|---:|---:|---:|---:|
| `2b6232d` | Initial benchmark | 12,458 | 13,373 | 3,105 MiB | 526 MiB |
| `a8cdaa2` | Added compile-option diagnostics | 12,967 | 16,480 | 3,092 MiB | 522 MiB |
| `965e77e` | Aligned Rust SQLite and release build settings | 13,080 | 13,065 | 3,090 MiB | 515 MiB |
| `0a20bd4` | Shared Rust value buffers | 12,695 | 13,066 | 98 MiB | 519 MiB |

Read latency distribution from the same run:

| Commit | Runtime | P50 | P75 | P90 | P95 | P99 |
|---|---|---:|---:|---:|---:|---:|
| `2b6232d` | Rust | 132us | 221us | 362us | 744us | 3,638us |
| `2b6232d` | Java | 131us | 225us | 343us | 1,076us | 3,388us |
| `a8cdaa2` | Rust | 116us | 214us | 336us | 946us | 4,077us |
| `a8cdaa2` | Java | 117us | 202us | 300us | 411us | 3,321us |
| `965e77e` | Rust | 122us | 212us | 316us | 484us | 3,232us |
| `965e77e` | Java | 115us | 203us | 313us | 461us | 2,915us |
| `0a20bd4` | Rust | 116us | 214us | 326us | 535us | 5,073us |
| `0a20bd4` | Java | 117us | 202us | 306us | 443us | 3,340us |

That distribution is much more useful than looking only at P99. The P50/P75/P90
values are mostly close. The P95/P99 columns move around more, which points to
tail effects from the mixed writer/reader workload and local scheduling noise,
not a clean language-level latency story.

The useful shape is:

- Java writes faster in the initial row, but Rust does not have uniformly worse
  reads
- after the build-parity row, write throughput is effectively tied
- the read-latency body remains close across runtimes, while the tail is noisy
- the value-sharing commit shows that the huge Rust RSS number was benchmark
  data ownership, not SQLite

## The First Suspicion: Wrapper Overhead

The Rust read probe originally used:

```rust
stmt.query_row([key], |row| read_probe_row(row, mode))
```

A reasonable suspicion was that `rusqlite`'s higher-level `query_row` path was
adding measurable overhead. I replaced it with a lower-level path using
`raw_bind_parameter` and `raw_query`.

That did not explain the gap.

The raw read path did not materially change the conclusion. More importantly,
read-mode controls let me separate "SQLite has to copy the value blob" from
"SQLite has to find the row":

```sql
SELECT 1 FROM cache WHERE key = ?1 LIMIT 1
```

That query does not materialize the value blob. If a difference remains visible
there, blob copying and row decoding are not the main explanation.

The next place to look was below both wrappers: the SQLite C library itself.

## How I Found the Build Difference

The investigation became clearer after I separated the workload into smaller
questions.

First, I looked at write batch timing. Rust and Java had similar commit times,
so the gap was unlikely to be caused by WAL fsync behavior or transaction
commit cost. The difference was in per-row work while executing statements, not
in the final commit.

Second, I changed the Rust read probe from `query_row` to a lower-level
`raw_bind_parameter` and `raw_query` path. If the wrapper was the problem, that
should have moved the numbers materially. It did not.

Third, I added read modes that avoided reading the blob entirely:

```sql
SELECT 1 FROM cache WHERE key = ?1 LIMIT 1
SELECT expires_at_ms FROM cache WHERE key = ?1 LIMIT 1
SELECT value FROM cache WHERE key = ?1 LIMIT 1
```

Those controls did not point to value-copying as the primary read-latency cause.

At that point the remaining shared component was SQLite itself, so I added a
small `--dump-sqlite-compile-options` command to both binaries and compared
runtime `PRAGMA compile_options`.

That was the turn. The Rust and Java binaries were not using equivalent SQLite
C builds.

## The Actual Cause: Different SQLite C Builds

The Rust and Java binaries were not running the same SQLite build.

Rust used bundled SQLite through `rusqlite/libsqlite3-sys`. Java used xerial's
prebuilt SQLite library. Runtime `PRAGMA compile_options` showed that the Rust
build had conservative instrumentation enabled that xerial did not.

The important differences were:

- Rust initially had SQLite memory-status tracking effectively enabled.
- Rust had `ENABLE_API_ARMOR`.
- Rust had `ENABLE_MEMORY_MANAGEMENT`.
- xerial had `DEFAULT_MEMSTATUS=0`.
- xerial had `DISABLE_PAGECACHE_OVERFLOW_STATS`.

Those flags matter in this workload. The hot path is a tight loop of binding a
key, binding an expiry timestamp, binding a blob, stepping the statement, and
resetting for the next row. Extra SQLite memory/status bookkeeping and API
defensive checks land directly on that path.

I made the Rust bundled SQLite build closer to xerial by adding a repo-level
Cargo config. In the public reproduction I also put the Rust release profile in
the same build-parity step, because the point of that commit is to compare
reasonably comparable Rust and Java release artifacts rather than Cargo's
default release profile against xerial's distributed native library.

```toml
[profile.release]
lto = "fat"
codegen-units = 1
panic = "abort"

[env]
LIBSQLITE3_FLAGS = "-DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DISABLE_PAGECACHE_OVERFLOW_STATS -USQLITE_ENABLE_API_ARMOR -USQLITE_ENABLE_MEMORY_MANAGEMENT"
```

After rebuilding, runtime compile options confirmed the intended hot-path flags:

- `DEFAULT_MEMSTATUS=0`
- `DISABLE_PAGECACHE_OVERFLOW_STATS`
- `THREADSAFE=1`

And the Rust build no longer reported:

- `ENABLE_API_ARMOR`
- `ENABLE_MEMORY_MANAGEMENT`

## The Result

After aligning SQLite C build flags and the Rust release build settings, the
clean conclusion is narrower than "Rust became faster." The public reproduction
shows that the initial Java-write-throughput advantage is not a stable language
property: by the build-parity row, Rust and Java write throughput is effectively
tied.

The read distribution says the same thing in a different way. P50/P75/P90 are
close across runtimes. P95/P99 are where the numbers jump around, and those
tails are sensitive to the mixed writer/reader workload, OS scheduling, and
local machine noise.

The final row is the more useful steady-state comparison for this repository:
after value buffers are shared correctly, Rust and Java write throughput and
the main read-latency body are close, while Rust no longer pays the accidental
multi-gigabyte synthetic-row ownership cost.

That is the honest conclusion: once both runtimes use a more comparable SQLite C
build and the benchmark owns data the same way, the result is mostly a SQLite
and workload result, not a wrapper-language result.

## A Separate Trap: Memory Ownership

There was another misleading result in the first benchmark: Rust appeared to use
much more RSS than Java.

This one was my benchmark's fault.

The row multiplier was intended to mutate only indexed key fields while reusing
the same opaque value buffer. The Java implementation did that naturally by
reusing the same `byte[]` reference when expanding rows. The Rust implementation
stored the value as `Vec<u8>` and derived `Clone` for `PriceCacheWrite`.

That meant every expanded synthetic row deep-copied the value bytes.

The source fixture had 2,862,797 bytes of value data across 500 messages. With a
multiplier of 1000, deep-copying those values adds about 2.67 GiB of extra value
buffers.

Changing the Rust value field from `Vec<u8>` to `Arc<[u8]>` fixed the benchmark
semantics: expanded rows now share the same body bytes.

The RSS change in the public reproduction was dramatic:

| Runtime | Before max RSS | After max RSS |
|---|---:|---:|
| Rust SQLite | 3,092 MiB | 98 MiB |

That is a useful reminder: a benchmark can accidentally measure its data
generator as much as the database.

## What I Learned

The main lesson is that "Rust vs Java" was the wrong abstraction level.

For SQLite, the critical comparison was:

- Which SQLite C library is being used?
- How was it compiled?
- Are durability settings the same?
- Is the benchmark generating and owning data the same way?
- Are read query shapes actually identical?

In this case, the initial write-throughput discrepancy was mostly native build
configuration. The initial Rust RSS problem was mostly value-buffer ownership
during synthetic row expansion.

Once those were fixed, Rust and Java were close enough that wrapper-language
differences were not the dominant factor.

## Practical Takeaway

SQLite WAL with `synchronous=NORMAL` looked plausible enough for this style of
local cache experiment to justify deeper testing:

- writes were around 12k rows/sec in the measured mixed workload
- 10 concurrent point-read probes stayed around 100-200us through P75 and a few
  hundred microseconds through P95 in the final public-reproduction run
- memory use was modest once value buffers were shared correctly

That does not mean SQLite is automatically the right production choice. It means
the first result was not a reason to reject it.

Before making a call on embedded storage performance, compare the actual native
engine configuration. With SQLite, wrapper language is often less important than
the C build hiding underneath it.
