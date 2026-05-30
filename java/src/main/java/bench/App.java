package bench;

import java.nio.file.Path;
import java.nio.file.Files;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.SplittableRandom;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import picocli.CommandLine;
import picocli.CommandLine.Command;
import picocli.CommandLine.ITypeConverter;
import picocli.CommandLine.Option;
import picocli.CommandLine.ParameterException;
import picocli.CommandLine.Spec;
import picocli.CommandLine.Model.CommandSpec;

@Command(name = "sqlite-build-flags-bench")
public final class App implements Callable<Integer> {
    private static final String UPSERT_SQL = "INSERT INTO cache(key, expires_at_ms, value) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET expires_at_ms = excluded.expires_at_ms, value = excluded.value";
    private static final String[] SQLITE_SIDE_CARS = {"-wal", "-shm", "-journal"};

    @Spec
    CommandSpec spec;

    @Option(names = "--db-path", defaultValue = "/private/tmp/sqlite-java-bench.sqlite")
    Path dbPath;
    @Option(names = "--reuse-db", description = "Reuse an existing database instead of deleting it before the run.")
    boolean reuseDb;
    @Option(names = "--rows", defaultValue = "500000")
    int rows;
    @Option(names = "--value-bytes", defaultValue = "5700")
    int valueBytes;
    @Option(names = "--batch-size", defaultValue = "20000")
    int batchSize;
    @Option(names = "--read-threads", defaultValue = "10")
    int readThreads;
    @Option(names = "--read-interval-us", defaultValue = "1000")
    long readIntervalUs;
    @Option(names = "--duration-secs", defaultValue = "30")
    long durationSecs;
    @Option(names = "--warmup-secs", defaultValue = "5")
    long warmupSecs;
    @Option(names = "--read-key-count", defaultValue = "500")
    int readKeyCount;
    @Option(names = "--read-pattern", defaultValue = "sequential", converter = ReadPatternConverter.class)
    ReadPattern readPattern = ReadPattern.SEQUENTIAL;
    @Option(names = "--read-seed", defaultValue = "1")
    long readSeed;
    @Option(names = "--read-mode", defaultValue = "value", converter = ReadModeConverter.class)
    ReadMode readMode = ReadMode.VALUE;
    @Option(names = "--dump-sqlite-compile-options")
    boolean dumpSqliteCompileOptions;

    record Row(String key, long expiresAtMs, byte[] value) {}
    record MeasuredRun(long written, ReadStats readStats, Duration elapsed) {}
    enum ReadPattern {
        SEQUENTIAL,
        RANDOM;

        static ReadPattern parse(String value) {
            for (ReadPattern pattern : values()) {
                if (pattern.name().equalsIgnoreCase(value)) {
                    return pattern;
                }
            }
            throw new IllegalArgumentException("expected one of: sequential, random");
        }
    }

    enum ReadMode {
        EXISTS("SELECT 1 FROM cache WHERE key = ? LIMIT 1"),
        METADATA("SELECT expires_at_ms FROM cache WHERE key = ? LIMIT 1"),
        VALUE("SELECT value FROM cache WHERE key = ? LIMIT 1");

        final String sql;

        ReadMode(String sql) {
            this.sql = sql;
        }

        void consume(ResultSet rs) throws SQLException {
            switch (this) {
                case EXISTS, METADATA -> rs.getLong(1);
                case VALUE -> rs.getBytes(1);
            }
        }

        static ReadMode parse(String value) {
            for (ReadMode mode : values()) {
                if (mode.name().equalsIgnoreCase(value)) {
                    return mode;
                }
            }
            throw new IllegalArgumentException("expected one of: exists, metadata, value");
        }
    }

    static final class ReadModeConverter implements ITypeConverter<ReadMode> {
        @Override
        public ReadMode convert(String value) {
            return ReadMode.parse(value);
        }
    }

    static final class ReadPatternConverter implements ITypeConverter<ReadPattern> {
        @Override
        public ReadPattern convert(String value) {
            return ReadPattern.parse(value);
        }
    }

    public static void main(String[] args) {
        System.exit(new CommandLine(new App()).execute(args));
    }

    public Integer call() throws Exception {
        if (dumpSqliteCompileOptions) {
            dumpCompileOptions();
            return 0;
        }
        validateOptions();
        if (!reuseDb) {
            resetDatabase();
        }
        List<Row> rows = generateRows(this.rows, valueBytes);
        prepareDb();
        Duration warmupDuration = Duration.ofSeconds(warmupSecs);
        Duration benchmarkDuration = Duration.ofSeconds(durationSecs);
        if (!warmupDuration.isZero()) {
            runMixed(rows, warmupDuration);
        }
        MeasuredRun measured = runMixed(rows, benchmarkDuration);
        ReadStats merged = measured.readStats();
        System.out.printf(
                "java sqlite wrote %d rows in %d ms (%.2f writes/s)%n",
                measured.written(),
                measured.elapsed().toMillis(),
                writesPerSecond(measured));
        System.out.printf("read probe: attempts=%d, hits=%d, misses=%d, avg_us=%d, p50_us=%d, p75_us=%d, p90_us=%d, p95_us=%d, p99_us=%d%n",
                merged.attempts, merged.hits, merged.misses, merged.avgUs(), merged.percentile(50), merged.percentile(75), merged.percentile(90), merged.percentile(95), merged.percentile(99));
        return 0;
    }

    double writesPerSecond(MeasuredRun measured) {
        return measured.written() / (measured.elapsed().toNanos() / 1_000_000_000.0);
    }

    MeasuredRun runMixed(List<Row> rows, Duration duration) throws Exception {
        AtomicBoolean stop = new AtomicBoolean(false);
        List<String> keys = readKeys(rows);
        ExecutorService executor = readThreads > 0 ? Executors.newFixedThreadPool(readThreads) : null;
        List<Future<ReadStats>> futures = new ArrayList<>();
        for (int i = 0; i < readThreads; i++) {
            int readerIndex = i;
            futures.add(executor.submit(() -> readLoop(keys, stop, readerIndex)));
        }
        long started = System.nanoTime();
        long written = 0;
        Exception writeFailure = null;
        try {
            written = writeFor(rows, duration);
        } catch (Exception e) {
            writeFailure = e;
        } finally {
            stop.set(true);
            stopReaders(executor);
        }
        ReadStats merged = new ReadStats();
        Exception readFailure = null;
        try {
            merged = collectReadStats(futures);
        } catch (Exception e) {
            readFailure = e;
        }
        if (writeFailure != null) {
            throw writeFailure;
        }
        if (readFailure != null) {
            throw readFailure;
        }
        Duration elapsed = Duration.ofNanos(System.nanoTime() - started);
        return new MeasuredRun(written, merged, elapsed);
    }

    List<String> readKeys(List<Row> rows) {
        return rows.stream().limit(Math.min(readKeyCount, rows.size())).map(Row::key).toList();
    }

    List<Row> generateRows(int count, int valueBytes) {
        List<Row> rows = new ArrayList<>(count);
        byte[] value = deterministicBytes(valueBytes);
        for (int i = 0; i < count; i++) {
            rows.add(new Row("hotel:" + (i % 100_000) + "|date:2026-03-" + ((i % 28) + 1) + "|los:" + ((i % 7) + 1) + "|variant:" + i, 1_800_000_000_000L, value));
        }
        return rows;
    }

    byte[] deterministicBytes(int len) {
        byte[] bytes = new byte[len];
        for (int i = 0; i < len; i++) {
            bytes[i] = (byte) ((i * 31) % 251);
        }
        return bytes;
    }

    void prepareDb() throws Exception {
        try (Connection c = openWriteConnection()) {
            try (Statement s = c.createStatement()) {
                s.execute("CREATE TABLE IF NOT EXISTS cache (key TEXT PRIMARY KEY, expires_at_ms INTEGER NOT NULL, value BLOB NOT NULL) WITHOUT ROWID");
            }
        }
    }

    long writeFor(List<Row> rows, Duration duration) throws Exception {
        try (Connection c = openWriteConnection()) {
            c.setAutoCommit(false);
            long started = System.nanoTime();
            long deadline = started + duration.toNanos();
            long written = 0;
            int pending = 0;
            try (PreparedStatement ps = c.prepareStatement(UPSERT_SQL)) {
                while (System.nanoTime() < deadline) {
                    for (Row row : rows) {
                        if (System.nanoTime() >= deadline) {
                            break;
                        }
                        ps.setString(1, row.key());
                        ps.setLong(2, row.expiresAtMs());
                        ps.setBytes(3, row.value());
                        ps.executeUpdate();
                        pending++;
                        if (pending >= batchSize) {
                            c.commit();
                            written += pending;
                            pending = 0;
                        }
                    }
                }
                if (pending > 0) {
                    c.commit();
                    written += pending;
                }
            } catch (Exception e) {
                rollbackQuietly(c);
                throw e;
            }
            return written;
        }
    }

    ReadStats readLoop(List<String> keys, AtomicBoolean stop) {
        return readLoop(keys, stop, 0);
    }

    ReadStats readLoop(List<String> keys, AtomicBoolean stop, int readerIndex) {
        ReadStats stats = new ReadStats();
        SplittableRandom random = new SplittableRandom(readSeed + readerIndex);
        try (Connection c = openReadConnection();
             PreparedStatement ps = c.prepareStatement(readMode.sql)) {
            int index = 0;
            while (!stop.get()) {
                String key = switch (readPattern) {
                    case SEQUENTIAL -> keys.get(index++ % keys.size());
                    case RANDOM -> keys.get(random.nextInt(keys.size()));
                };
                stats.attempts++;
                long started = System.nanoTime();
                ps.setString(1, key);
                try (ResultSet rs = ps.executeQuery()) {
                    if (rs.next()) {
                        readMode.consume(rs);
                        stats.hits++;
                    } else {
                        stats.misses++;
                    }
                    stats.latencies.add(elapsedUs(started));
                }
                long sleepMillis = readIntervalUs / 1000;
                int sleepNanos = (int) (readIntervalUs % 1000) * 1000;
                Thread.sleep(sleepMillis, sleepNanos);
            }
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
        return stats;
    }

    Connection openWriteConnection() throws SQLException {
        Connection c = DriverManager.getConnection(jdbcUrl());
        try {
            try (Statement s = c.createStatement()) {
                s.execute("PRAGMA busy_timeout = 5000");
                s.execute("PRAGMA journal_mode = WAL");
                s.execute("PRAGMA synchronous = NORMAL");
                s.execute("PRAGMA wal_autocheckpoint = 0");
            }
            return c;
        } catch (SQLException e) {
            closeQuietly(c);
            throw e;
        }
    }

    Connection openReadConnection() throws SQLException {
        Connection c = DriverManager.getConnection(jdbcUrl());
        try {
            try (Statement s = c.createStatement()) {
                s.execute("PRAGMA busy_timeout = 5000");
                s.execute("PRAGMA query_only = ON");
            }
            return c;
        } catch (SQLException e) {
            closeQuietly(c);
            throw e;
        }
    }

    String jdbcUrl() {
        return "jdbc:sqlite:" + dbPath;
    }

    void resetDatabase() throws Exception {
        Files.deleteIfExists(dbPath);
        for (String suffix : SQLITE_SIDE_CARS) {
            Files.deleteIfExists(Path.of(dbPath.toString() + suffix));
        }
    }

    void dumpCompileOptions() throws Exception {
        try (Connection c = DriverManager.getConnection("jdbc:sqlite::memory:");
             Statement s = c.createStatement();
             ResultSet rs = s.executeQuery("PRAGMA compile_options")) {
            while (rs.next()) {
                System.out.println(rs.getString(1));
            }
        }
    }

    void validateOptions() {
        requirePositive("--rows", rows);
        requireNonNegative("--value-bytes", valueBytes);
        requirePositive("--batch-size", batchSize);
        requireNonNegative("--read-threads", readThreads);
        requireNonNegative("--read-interval-us", readIntervalUs);
        requirePositive("--duration-secs", durationSecs);
        requireNonNegative("--warmup-secs", warmupSecs);
        requirePositive("--read-key-count", readKeyCount);
    }

    void requirePositive(String option, long value) {
        if (value <= 0) {
            throw new ParameterException(spec.commandLine(), option + " must be > 0");
        }
    }

    void requireNonNegative(String option, long value) {
        if (value < 0) {
            throw new ParameterException(spec.commandLine(), option + " must be >= 0");
        }
    }

    ReadStats collectReadStats(List<Future<ReadStats>> futures) throws Exception {
        ReadStats merged = new ReadStats();
        for (Future<ReadStats> future : futures) {
            try {
                merged.merge(future.get());
            } catch (ExecutionException e) {
                Throwable cause = e.getCause();
                if (cause instanceof Exception exception) {
                    throw exception;
                }
                if (cause instanceof Error error) {
                    throw error;
                }
                throw new RuntimeException(cause);
            }
        }
        return merged;
    }

    void stopReaders(ExecutorService executor) throws InterruptedException {
        if (executor == null) {
            return;
        }
        executor.shutdown();
        if (!executor.awaitTermination(30, TimeUnit.SECONDS)) {
            executor.shutdownNow();
            if (!executor.awaitTermination(30, TimeUnit.SECONDS)) {
                throw new IllegalStateException("readers did not stop");
            }
        }
    }

    long elapsedUs(long started) {
        return (System.nanoTime() - started + 999) / 1000;
    }

    void rollbackQuietly(Connection c) {
        try {
            c.rollback();
        } catch (SQLException ignored) {
            // Preserve the original failure.
        }
    }

    void closeQuietly(Connection c) {
        try {
            c.close();
        } catch (SQLException ignored) {
            // Preserve the original failure.
        }
    }

    static final class ReadStats {
        long attempts;
        long hits;
        long misses;
        List<Long> latencies = new ArrayList<>();
        ReadStats merge(ReadStats other) {
            attempts += other.attempts;
            hits += other.hits;
            misses += other.misses;
            latencies.addAll(other.latencies);
            return this;
        }
        long avgUs() {
            return latencies.isEmpty() ? 0 : latencies.stream().mapToLong(Long::longValue).sum() / latencies.size();
        }
        long percentile(int pct) {
            if (latencies.isEmpty()) return 0;
            ArrayList<Long> copy = new ArrayList<>(latencies);
            Collections.sort(copy);
            return copy.get((copy.size() - 1) * pct / 100);
        }
    }
}
