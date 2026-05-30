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

At first the Java 25 version looked clearly better than the Rust version. That
was surprising. SQLite is a C library in both cases. Rust calls it through
`rusqlite`; Java calls it through xerial's SQLite JDBC driver. The wrapper layer
is different, but the storage engine is still SQLite.

The initial temptation was to treat this as a Rust-vs-Java result. That turned
out to be the wrong frame.

## The First Suspicion: Wrapper Overhead

The Rust read probe originally used:

```rust
stmt.query_row([key], |row| read_probe_row(row, mode))
```

A reasonable suspicion was that `rusqlite`'s higher-level `query_row` path was
adding measurable overhead. I replaced it with a lower-level path using
`raw_bind_parameter` and `raw_query`.

That did not explain the gap.

The raw read path did not materially improve the Rust numbers. More importantly,
the gap was visible even for the cheapest read mode:

```sql
SELECT 1 FROM cache WHERE key = ?1 LIMIT 1
```

That query does not materialize the value blob. If the problem shows up even
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

The Rust gap was still visible even in `SELECT 1`. That ruled out value-copying
as the primary read-latency cause.

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
Cargo config:

```toml
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

After aligning SQLite C build flags, the Rust and Java SQLite results converged.

One clean steady-state run:

| Runtime | Writes/s | Read P50 | Read P95 | Read P99 |
|---|---:|---:|---:|---:|
| Rust SQLite | 12,393/s | 136us | 309us | 457us |
| Java 25 SQLite | 11,986/s | 140us | 294us | 400us |

That is effectively tied. Java had a slightly better tail in that run; Rust had
slightly better median latency and write throughput. The difference is small
enough that the honest conclusion is not "Rust is faster" or "Java is faster."
The conclusion is that once both runtimes use a comparable SQLite C build, the
SQLite result is mostly the SQLite result.

I also reran read modes individually after the build change. Rust and Java were
again in the same range:

| Mode | Rust writes/s | Java writes/s | Rust P50/P95/P99 | Java P50/P95/P99 |
|---|---:|---:|---:|---:|
| `exists` | 11,686/s | 11,995/s | 140 / 300 / 434us | 147 / 342 / 488us |
| `metadata` | 12,991/s | 12,135/s | 135 / 301 / 426us | 145 / 317 / 445us |
| `value` | 12,267/s | 12,109/s | 144 / 328 / 471us | 155 / 334 / 485us |

The earlier Rust-vs-Java gap disappeared.

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

The RSS change was dramatic:

| Runtime | Before avg RSS | After avg RSS |
|---|---:|---:|
| Rust SQLite | 2,460,399 KiB | 240,428 KiB |

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

In this case, the initial Rust slowdown was mostly SQLite C build configuration.
The initial Rust RSS problem was mostly value-buffer ownership during synthetic
row expansion.

Once those were fixed, Rust and Java were close enough that wrapper-language
differences were not the dominant factor.

## Practical Takeaway

SQLite WAL with `synchronous=NORMAL` looked viable for this style of local
price-cache experiment:

- writes were around 12k rows/sec in the measured mixed workload
- 10 concurrent point-read probes stayed in the sub-millisecond P99 range
- memory use was modest once value buffers were shared correctly

That does not mean SQLite is automatically the right production choice. It means
the first result was not a reason to reject it.

Before making a call on embedded storage performance, compare the actual native
engine configuration. With SQLite, wrapper language is often less important than
the C build hiding underneath it.
