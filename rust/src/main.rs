use anyhow::{Context, Result, bail};
use clap::{Parser, ValueEnum};
use rusqlite::Connection;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug, Parser)]
struct Args {
    #[arg(long, default_value = "/private/tmp/sqlite-rust-bench.sqlite")]
    db_path: PathBuf,
    #[arg(long, default_value_t = 500_000, value_parser = parse_positive_usize)]
    rows: usize,
    #[arg(long, default_value_t = 5_700)]
    value_bytes: usize,
    #[arg(long, default_value_t = 20_000, value_parser = parse_positive_usize)]
    batch_size: usize,
    #[arg(long, default_value_t = 10)]
    read_threads: usize,
    #[arg(long, default_value_t = 1_000)]
    read_interval_us: u64,
    #[arg(long, default_value_t = 30, value_parser = parse_positive_u64)]
    duration_secs: u64,
    #[arg(long, default_value_t = 5)]
    warmup_secs: u64,
    #[arg(long, default_value_t = 500, value_parser = parse_positive_usize)]
    read_key_count: usize,
    #[arg(long, value_enum, default_value_t = ReadPattern::Sequential)]
    read_pattern: ReadPattern,
    #[arg(long, default_value_t = 1)]
    read_seed: u64,
    #[arg(long, value_enum, default_value_t = ReadMode::Value)]
    read_mode: ReadMode,
    #[arg(long, default_value_t = false)]
    reuse_db: bool,
    #[arg(long, default_value_t = false)]
    dump_sqlite_compile_options: bool,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum ReadPattern {
    Sequential,
    Random,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum ReadMode {
    Exists,
    Metadata,
    Value,
}

#[derive(Clone)]
struct Row {
    key: String,
    expires_at_ms: i64,
    value: Vec<u8>,
}

#[derive(Clone, Copy)]
struct RunConfig {
    batch_size: usize,
    read_threads: usize,
    read_interval: Duration,
    read_key_count: usize,
    read_pattern: ReadPattern,
    read_seed: u64,
    read_mode: ReadMode,
}

fn main() -> Result<()> {
    let args = Args::parse();
    run(args)
}

fn run(args: Args) -> Result<()> {
    if args.dump_sqlite_compile_options {
        dump_compile_options()?;
        return Ok(());
    }

    if !args.reuse_db {
        reset_database(&args.db_path)?;
    }
    let rows = generate_rows(args.rows, args.value_bytes);
    prepare_db(&args.db_path)?;
    let config = RunConfig {
        batch_size: args.batch_size,
        read_threads: args.read_threads,
        read_interval: Duration::from_micros(args.read_interval_us),
        read_key_count: args.read_key_count,
        read_pattern: args.read_pattern,
        read_seed: args.read_seed,
        read_mode: args.read_mode,
    };

    if args.warmup_secs > 0 {
        let _ = run_mixed(
            &args.db_path,
            &rows,
            config,
            Duration::from_secs(args.warmup_secs),
        )?;
    }

    let (written, stats, elapsed) = run_mixed(
        &args.db_path,
        &rows,
        config,
        Duration::from_secs(args.duration_secs),
    )?;
    println!(
        "rust sqlite wrote {written} rows in {} ms ({:.2} writes/s)",
        elapsed.as_millis(),
        written as f64 / elapsed.as_secs_f64()
    );
    println!(
        "read probe: attempts={}, hits={}, misses={}, avg_us={}, p50_us={}, p75_us={}, p90_us={}, p95_us={}, p99_us={}",
        stats.attempts,
        stats.hits,
        stats.misses,
        stats.avg_us(),
        percentile(&stats.latencies, 50),
        percentile(&stats.latencies, 75),
        percentile(&stats.latencies, 90),
        percentile(&stats.latencies, 95),
        percentile(&stats.latencies, 99)
    );
    Ok(())
}

fn run_mixed(
    path: &Path,
    rows: &[Row],
    config: RunConfig,
    duration: Duration,
) -> Result<(usize, ReadStats, Duration)> {
    let stop = Arc::new(AtomicBool::new(false));
    let readers = start_readers(
        path.to_path_buf(),
        read_keys(rows, config.read_key_count),
        config.read_threads,
        config.read_interval,
        config.read_pattern,
        config.read_seed,
        config.read_mode,
        stop.clone(),
    );

    let started = Instant::now();
    let written = write_for(path, rows, config.batch_size, duration);
    stop.store(true, Ordering::Relaxed);
    let stats = collect_readers(readers);
    let written = written?;
    let stats = stats?;
    let elapsed = started.elapsed();
    Ok((written, stats, elapsed))
}

fn read_keys(rows: &[Row], read_key_count: usize) -> Vec<String> {
    rows.iter()
        .take(read_key_count.min(rows.len()))
        .map(|row| row.key.clone())
        .collect()
}

fn generate_rows(count: usize, value_bytes: usize) -> Vec<Row> {
    let mut rows = Vec::with_capacity(count);
    let base_value = deterministic_bytes(value_bytes);
    for index in 0..count {
        rows.push(Row {
            key: format!(
                "hotel:{}|date:2026-03-{:02}|los:{}|variant:{}",
                index % 100_000,
                (index % 28) + 1,
                (index % 7) + 1,
                index
            ),
            expires_at_ms: 1_800_000_000_000,
            value: base_value.clone(),
        });
    }
    rows
}

fn deterministic_bytes(len: usize) -> Vec<u8> {
    (0..len).map(|i| (i.wrapping_mul(31) % 251) as u8).collect()
}

fn prepare_db(path: &Path) -> Result<()> {
    let conn = open_write_connection(path)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS cache (
           key TEXT PRIMARY KEY,
           expires_at_ms INTEGER NOT NULL,
           value BLOB NOT NULL
         ) WITHOUT ROWID;",
    )?;
    Ok(())
}

fn write_for(path: &Path, rows: &[Row], batch_size: usize, duration: Duration) -> Result<usize> {
    let mut conn = open_write_connection(path)?;
    let started = Instant::now();
    let mut written = 0;
    while started.elapsed() < duration {
        for batch in rows.chunks(batch_size) {
            if started.elapsed() >= duration {
                return Ok(written);
            }
            let tx = conn.transaction()?;
            let mut pending = 0;
            {
                let mut stmt = tx.prepare_cached(
                    "INSERT INTO cache(key, expires_at_ms, value)
                     VALUES (?1, ?2, ?3)
                     ON CONFLICT(key) DO UPDATE SET
                       expires_at_ms = excluded.expires_at_ms,
                       value = excluded.value",
                )?;
                for row in batch {
                    if started.elapsed() >= duration {
                        break;
                    }
                    stmt.execute((&row.key, row.expires_at_ms, row.value.as_slice()))?;
                    pending += 1;
                }
            }
            if pending == 0 {
                tx.rollback()?;
                return Ok(written);
            }
            tx.commit()?;
            written += pending;
            if pending < batch.len() {
                return Ok(written);
            }
        }
    }
    Ok(written)
}

fn start_readers(
    path: PathBuf,
    keys: Vec<String>,
    threads: usize,
    interval: Duration,
    pattern: ReadPattern,
    seed: u64,
    mode: ReadMode,
    stop: Arc<AtomicBool>,
) -> Vec<thread::JoinHandle<Result<ReadStats>>> {
    (0..threads)
        .map(|reader_index| {
            let path = path.clone();
            let keys = keys.clone();
            let stop = stop.clone();
            thread::spawn(move || {
                read_loop(
                    path,
                    keys,
                    interval,
                    mode,
                    pattern,
                    seed.wrapping_add(reader_index as u64),
                    stop,
                )
            })
        })
        .collect()
}

fn read_loop(
    path: PathBuf,
    keys: Vec<String>,
    interval: Duration,
    mode: ReadMode,
    pattern: ReadPattern,
    seed: u64,
    stop: Arc<AtomicBool>,
) -> Result<ReadStats> {
    let conn = open_read_connection(&path)?;
    let sql = match mode {
        ReadMode::Exists => "SELECT 1 FROM cache WHERE key = ?1 LIMIT 1",
        ReadMode::Metadata => "SELECT expires_at_ms FROM cache WHERE key = ?1 LIMIT 1",
        ReadMode::Value => "SELECT value FROM cache WHERE key = ?1 LIMIT 1",
    };
    let mut stmt = conn.prepare_cached(sql)?;
    let mut stats = ReadStats::default();
    let mut index = 0usize;
    let mut random = Lcg::new(seed);
    while !stop.load(Ordering::Relaxed) {
        let key_index = match pattern {
            ReadPattern::Sequential => {
                let key_index = index % keys.len();
                index = index.wrapping_add(1);
                key_index
            }
            ReadPattern::Random => random.next_usize(keys.len()),
        };
        let key = &keys[key_index];
        stats.attempts += 1;
        let started = Instant::now();
        let result = stmt.query_row([key], |row| match mode {
            ReadMode::Exists => row.get::<_, i64>(0).map(|_| ()),
            ReadMode::Metadata => row.get::<_, i64>(0).map(|_| ()),
            ReadMode::Value => row.get::<_, Vec<u8>>(0).map(|_| ()),
        });
        match result {
            Ok(()) => {
                stats.hits += 1;
            }
            Err(rusqlite::Error::QueryReturnedNoRows) => stats.misses += 1,
            Err(error) => return Err(error.into()),
        }
        stats.latencies.push(elapsed_us(started));
        thread::sleep(interval);
    }
    Ok(stats)
}

fn open_write_connection(path: &Path) -> Result<Connection> {
    let conn = Connection::open(path)?;
    conn.execute_batch(
        "PRAGMA busy_timeout = 5000;
         PRAGMA journal_mode = WAL;
         PRAGMA synchronous = NORMAL;
         PRAGMA wal_autocheckpoint = 0;",
    )?;
    Ok(conn)
}

fn open_read_connection(path: &Path) -> Result<Connection> {
    let conn = Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
    )?;
    conn.execute_batch(
        "PRAGMA busy_timeout = 5000;
         PRAGMA query_only = ON;",
    )?;
    Ok(conn)
}

fn reset_database(path: &Path) -> Result<()> {
    remove_file_if_exists(path)?;
    for suffix in ["-wal", "-shm", "-journal"] {
        remove_file_if_exists(PathBuf::from(format!("{}{suffix}", path.display())))?;
    }
    Ok(())
}

fn remove_file_if_exists(path: impl AsRef<Path>) -> Result<()> {
    match fs::remove_file(path.as_ref()) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| format!("remove {}", path.as_ref().display())),
    }
}

fn collect_readers(readers: Vec<thread::JoinHandle<Result<ReadStats>>>) -> Result<ReadStats> {
    readers
        .into_iter()
        .map(|reader| match reader.join() {
            Ok(result) => result,
            Err(_) => bail!("reader thread panicked"),
        })
        .try_fold(ReadStats::default(), |stats, reader_stats| {
            Ok(stats.merge(reader_stats?))
        })
}

fn dump_compile_options() -> Result<()> {
    let conn = Connection::open_in_memory()?;
    let mut stmt = conn.prepare("PRAGMA compile_options")?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
    for option in rows {
        println!("{}", option?);
    }
    Ok(())
}

#[derive(Default)]
struct ReadStats {
    attempts: u64,
    hits: u64,
    misses: u64,
    latencies: Vec<u64>,
}

impl ReadStats {
    fn merge(mut self, mut other: ReadStats) -> ReadStats {
        self.attempts += other.attempts;
        self.hits += other.hits;
        self.misses += other.misses;
        self.latencies.append(&mut other.latencies);
        self
    }

    fn avg_us(&self) -> u64 {
        if self.latencies.is_empty() {
            0
        } else {
            self.latencies.iter().sum::<u64>() / self.latencies.len() as u64
        }
    }
}

fn elapsed_us(started: Instant) -> u64 {
    ((started.elapsed().as_nanos() + 999) / 1_000) as u64
}

fn percentile(values: &[u64], pct: usize) -> u64 {
    if values.is_empty() {
        return 0;
    }
    let mut values = values.to_vec();
    values.sort_unstable();
    values[(values.len() - 1) * pct / 100]
}

fn parse_positive_usize(value: &str) -> std::result::Result<usize, String> {
    let parsed = value
        .parse::<usize>()
        .map_err(|error| format!("invalid positive integer: {error}"))?;
    if parsed == 0 {
        Err("value must be > 0".to_string())
    } else {
        Ok(parsed)
    }
}

fn parse_positive_u64(value: &str) -> std::result::Result<u64, String> {
    let parsed = value
        .parse::<u64>()
        .map_err(|error| format!("invalid positive integer: {error}"))?;
    if parsed == 0 {
        Err("value must be > 0".to_string())
    } else {
        Ok(parsed)
    }
}

struct Lcg {
    state: u64,
}

impl Lcg {
    fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    fn next_usize(&mut self, upper: usize) -> usize {
        self.state = self
            .state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        (self.state as usize) % upper
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::OptionalExtension;
    use std::fs;
    use std::sync::atomic::AtomicBool;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn cli_rejects_values_that_make_the_benchmark_invalid() {
        assert!(Args::try_parse_from(["bench", "--rows", "0"]).is_err());
        assert!(Args::try_parse_from(["bench", "--batch-size", "0"]).is_err());
        assert!(Args::try_parse_from(["bench", "--duration-secs", "0"]).is_err());
        assert!(Args::try_parse_from(["bench", "--read-key-count", "0"]).is_err());
    }

    #[test]
    fn run_resets_existing_database_by_default() -> Result<()> {
        let path = temp_db_path("reset");
        let conn = Connection::open(&path)?;
        conn.execute("CREATE TABLE stale_marker(id INTEGER PRIMARY KEY)", [])?;
        drop(conn);

        let args = Args {
            db_path: path.clone(),
            reuse_db: false,
            rows: 1,
            value_bytes: 4,
            batch_size: 1,
            read_threads: 0,
            read_interval_us: 0,
            duration_secs: 1,
            warmup_secs: 0,
            read_key_count: 1,
            read_pattern: ReadPattern::Sequential,
            read_seed: 1,
            read_mode: ReadMode::Exists,
            dump_sqlite_compile_options: false,
        };

        run(args)?;

        let conn = Connection::open(&path)?;
        let stale_exists: Option<i64> = conn
            .query_row(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'stale_marker'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        cleanup_db(&path);
        assert_eq!(None, stale_exists);
        Ok(())
    }

    #[test]
    fn writer_connections_apply_benchmark_pragmas() -> Result<()> {
        let path = temp_db_path("pragmas");
        let conn = open_write_connection(&path)?;

        assert_eq!(0, pragma_i64(&conn, "wal_autocheckpoint")?);
        assert_eq!(1, pragma_i64(&conn, "synchronous")?);
        cleanup_db(&path);
        Ok(())
    }

    #[test]
    fn misses_contribute_to_latency_distribution() -> Result<()> {
        let path = temp_db_path("misses");
        prepare_db(&path)?;
        let stop = Arc::new(AtomicBool::new(false));
        let stopper = stop.clone();
        let handle = thread::spawn(move || {
            thread::sleep(Duration::from_millis(25));
            stopper.store(true, Ordering::Relaxed);
        });

        let stats = read_loop(
            path.clone(),
            vec!["missing".to_string()],
            Duration::ZERO,
            ReadMode::Exists,
            ReadPattern::Sequential,
            1,
            stop,
        )?;
        handle.join().unwrap();

        cleanup_db(&path);
        assert!(stats.attempts > 0);
        assert_eq!(stats.attempts, stats.misses);
        assert_eq!(stats.attempts as usize, stats.latencies.len());
        Ok(())
    }

    fn pragma_i64(conn: &Connection, name: &str) -> Result<i64> {
        Ok(conn.query_row(&format!("PRAGMA {name}"), [], |row| row.get(0))?)
    }

    fn temp_db_path(name: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "sqlite-rust-bench-{name}-{}-{nanos}.sqlite",
            std::process::id()
        ))
    }

    fn cleanup_db(path: &PathBuf) {
        let _ = fs::remove_file(path);
        let _ = fs::remove_file(PathBuf::from(format!("{}-wal", path.display())));
        let _ = fs::remove_file(PathBuf::from(format!("{}-shm", path.display())));
        let _ = fs::remove_file(PathBuf::from(format!("{}-journal", path.display())));
    }
}
