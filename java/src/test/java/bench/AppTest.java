package bench;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import picocli.CommandLine;

final class AppTest {
    @TempDir
    Path tempDir;

    @Test
    void rejectsInvalidReadModeBeforeRunningBenchmark() {
        Path db = tempDir.resolve("invalid-mode.sqlite");

        int exitCode = new CommandLine(new App()).execute(
                "--db-path", db.toString(),
                "--rows", "1",
                "--duration-secs", "0",
                "--warmup-secs", "0",
                "--read-mode", "bogus");

        assertEquals(CommandLine.ExitCode.USAGE, exitCode);
        assertFalse(Files.exists(db));
    }

    @Test
    void defaultRunDeletesExistingDatabaseBeforePreparingSchema() throws Exception {
        Path db = tempDir.resolve("reset.sqlite");
        try (Connection c = DriverManager.getConnection("jdbc:sqlite:" + db);
             Statement s = c.createStatement()) {
            s.execute("CREATE TABLE stale_marker (id INTEGER PRIMARY KEY)");
            s.execute("INSERT INTO stale_marker(id) VALUES (1)");
        }

        int exitCode = new CommandLine(new App()).execute(
                "--db-path", db.toString(),
                "--rows", "1",
                "--value-bytes", "4",
                "--batch-size", "1",
                "--read-threads", "0",
                "--duration-secs", "1",
                "--warmup-secs", "0");

        assertEquals(CommandLine.ExitCode.OK, exitCode);
        try (Connection c = DriverManager.getConnection("jdbc:sqlite:" + db);
             ResultSet rs = c.getMetaData().getTables(null, null, "stale_marker", null)) {
            assertFalse(rs.next());
        }
    }

    @Test
    void missesContributeToLatencyDistribution() throws Exception {
        App app = new App();
        app.dbPath = tempDir.resolve("misses.sqlite");
        app.readMode = App.ReadMode.EXISTS;
        app.readIntervalUs = 0;
        app.prepareDb();

        AtomicBoolean stop = new AtomicBoolean(false);
        Thread stopper = new Thread(() -> {
            try {
                Thread.sleep(25);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            stop.set(true);
        });
        stopper.start();

        App.ReadStats stats = app.readLoop(List.of("missing"), stop);
        stopper.join();

        assertTrue(stats.attempts > 0);
        assertEquals(stats.attempts, stats.misses);
        assertEquals(stats.attempts, stats.latencies.size());
    }

    @Test
    void writerConnectionsApplyBenchmarkPragmas() throws Exception {
        App app = new App();
        app.dbPath = tempDir.resolve("pragmas.sqlite");
        app.prepareDb();

        try (Connection c = app.openWriteConnection();
             Statement s = c.createStatement()) {
            assertEquals(0, pragmaLong(s, "wal_autocheckpoint"));
            assertEquals(1, pragmaLong(s, "synchronous"));
        }
    }

    @Test
    void writePathExecutesRowsInsideTransactionsWithoutJdbcBatching() throws Exception {
        App app = new App();
        app.dbPath = tempDir.resolve("writes.sqlite");
        app.batchSize = 2;
        app.prepareDb();

        long written = app.writeFor(app.generateRows(3, 4), Duration.ofMillis(200));

        assertTrue(written >= 3);
        try (Connection c = DriverManager.getConnection("jdbc:sqlite:" + app.dbPath);
             Statement s = c.createStatement();
             ResultSet rs = s.executeQuery("SELECT COUNT(*) FROM cache")) {
            assertTrue(rs.next());
            assertEquals(3, rs.getLong(1));
        }
    }

    private static long pragmaLong(Statement s, String name) throws Exception {
        try (ResultSet rs = s.executeQuery("PRAGMA " + name)) {
            assertTrue(rs.next());
            return rs.getLong(1);
        }
    }
}
