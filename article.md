# What a Rust-vs-Java SQLite Benchmark Actually Measured

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
far more memory. But the read-latency picture was mixed even in the first run.
Rust was not uniformly slower; in some percentiles it was equal or better, and
in the far tail it moved around.

That was the first hint that the benchmark was measuring more than one thing.
SQLite is a C library in both cases. Rust calls it through `rusqlite`; Java
calls it through xerial's SQLite JDBC driver. The wrapper layer is different,
but the storage engine is still SQLite.

The initial temptation was to treat this as a Rust-vs-Java result. That turned
out to be the wrong frame. The useful question was: which parts of the result
come from SQLite build settings, which parts come from benchmark data ownership,
and which parts are just noisy mixed-workload tails?

## Reproducing the Investigation

I kept the benchmark history in small commits so the investigation is
re-runnable instead of just described. The runner is:

```bash
scripts/run-sqlite-investigation-matrix.sh
```

Each process does a 5-second in-process warm-up before the measured 30-second
window. Write throughput and read latency come from the benchmark's measured
window. Process metrics come from `/usr/bin/time -l` on macOS and
`/usr/bin/time -pv` on Linux, so they include row generation and warm-up
allocation.

One run on my machine looked like this:

| Commit | What changed | Rust writes/s | Java writes/s | Rust RSS | Java RSS |
|---|---|---:|---:|---:|---:|
| `f6c2aae` | Initial benchmark | 9,685 | 13,774 | 3,094 MiB | 519 MiB |
| `22a17e9` | Added compile-option diagnostics | 11,310 | 14,321 | 3,095 MiB | 519 MiB |
| `053bf0f` | Aligned Rust SQLite and release build settings | 17,553 | 16,394 | 3,099 MiB | 537 MiB |
| `d81712c` | Shared Rust value buffers | 17,493 | 16,725 | 107 MiB | 520 MiB |

Read latency distribution from the same run:

| Commit | Runtime | P50 | P75 | P90 | P95 | P99 |
|---|---|---:|---:|---:|---:|---:|
| `f6c2aae` | Rust | 645us | 1,081us | 1,426us | 1,619us | 2,050us |
| `f6c2aae` | Java | 197us | 266us | 339us | 394us | 568us |
| `22a17e9` | Rust | 514us | 976us | 1,333us | 1,513us | 1,828us |
| `22a17e9` | Java | 201us | 299us | 405us | 473us | 615us |
| `053bf0f` | Rust | 186us | 261us | 341us | 394us | 515us |
| `053bf0f` | Java | 192us | 292us | 410us | 486us | 649us |
| `d81712c` | Rust | 185us | 258us | 337us | 392us | 523us |
| `d81712c` | Java | 176us | 232us | 290us | 333us | 445us |

That distribution is much more useful than looking only at P99. The early rows
show a real Rust penalty before the native SQLite build is aligned. After the
build-parity row, the body of the distribution is close enough that the result
is no longer a clean wrapper-language latency story.

The useful shape is not "Rust was slower." The useful shape is:

- Java writes and reads faster in the initial rows
- after the build-parity row, Rust and Java write throughput are close
- after the build-parity row, the read-latency body is close across runtimes
- the value-sharing commit shows that the huge Rust RSS number was benchmark
  data ownership, not SQLite

## First Suspicion: Wrapper Overhead

The Rust read probe originally used:

```rust
stmt.query_row([key], |row| read_probe_row(row, mode))
```

A reasonable suspicion was that `rusqlite`'s higher-level `query_row` path was
adding measurable overhead. I replaced it with a lower-level path using
`raw_bind_parameter` and `raw_query`.

That did not explain the benchmark.

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

## One Real Factor: Different SQLite C Builds

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

Those flags can matter in this workload. The hot path is a tight loop of binding
a key, binding an expiry timestamp, binding a blob, stepping the statement, and
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

## What Changed

After aligning SQLite C build flags and the Rust release build settings, the
clean conclusion is narrower than "Rust became faster." The public reproduction
shows that the initial Java write-throughput advantage is not a stable language
property: by the build-parity row, Rust and Java write throughput is effectively
tied.

The read distribution says the same thing in a different way. The initial rows
show Rust paying for the native build configuration. After build parity,
P50/P75/P90 are close across runtimes, and the remaining differences are small
enough to be sensitive to the mixed writer/reader workload and local machine
noise.

The final row is the more useful comparison for this repository:
after value buffers are shared correctly, Rust and Java write throughput and
the main read-latency body are close, while Rust no longer pays the accidental
multi-gigabyte synthetic-row ownership cost.

That is the honest conclusion: once both runtimes use a more comparable native
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
| Rust SQLite | 3,095 MiB | 107 MiB |

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

In this case, the initial write-throughput discrepancy was affected by native
build configuration. The initial Rust RSS problem was value-buffer ownership
during synthetic row expansion. The read-latency story became much narrower
after the native build settings were aligned: the body of the distribution was
then close enough that wrapper-language differences were not the dominant
factor.

Once those were fixed, Rust and Java were close enough that wrapper-language
differences were not the dominant factor.

## Practical Takeaway

SQLite WAL with `synchronous=NORMAL` looked plausible enough for this style of
local cache experiment to justify deeper testing:

- writes were around 17k rows/sec in the measured mixed workload
- 10 concurrent point-read probes stayed around 200-260us through P75 and a few
  hundred microseconds through P95 in the final public-reproduction run
- memory use was modest once value buffers were shared correctly

That does not mean SQLite is automatically the right production choice. It means
the first result was not a reason to reject it.

Before making a call on embedded storage performance, compare the actual native
engine configuration. With SQLite, wrapper language is often less important than
the C build hiding underneath it.
