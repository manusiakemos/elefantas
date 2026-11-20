import XCTest
@testable import PGKit

final class ConnectParamsTests: XCTestCase {
    func testKeywordPairsOmitEmptyOptionals() {
        let p = ConnectParams(host: "db", port: 6543, database: "app", user: "me", password: "", sslMode: .require)
        let dict = Dictionary(uniqueKeysWithValues: p.keywordPairs)
        XCTAssertEqual(dict["host"], "db")
        XCTAssertEqual(dict["port"], "6543")
        XCTAssertEqual(dict["sslmode"], "require")
        XCTAssertEqual(dict["client_encoding"], "UTF8")
        XCTAssertNil(dict["password"])
        XCTAssertNil(dict["sslrootcert"])
    }

    func testKeywordPairsIncludePasswordAndRootCert() {
        let p = ConnectParams(host: "h", database: "d", user: "u", password: "s3cret",
                              sslMode: .verifyFull, sslRootCert: "/tmp/ca.pem")
        let dict = Dictionary(uniqueKeysWithValues: p.keywordPairs)
        XCTAssertEqual(dict["password"], "s3cret")
        XCTAssertEqual(dict["sslmode"], "verify-full")
        XCTAssertEqual(dict["sslrootcert"], "/tmp/ca.pem")
    }

    func testWithParamsKeepsNullDistinctFromEmpty() {
        withParams(["a", nil, ""]) { count, values in
            XCTAssertEqual(count, 3)
            XCTAssertEqual(String(cString: values![0]!), "a")
            XCTAssertNil(values![1])
            XCTAssertEqual(String(cString: values![2]!), "")
        }
        withParams([]) { count, values in
            XCTAssertEqual(count, 0)
            XCTAssertNil(values)
        }
    }

    func testConnectFailureReportsConnectionError() async {
        // Port 1 on localhost: refused immediately, no server needed.
        let p = ConnectParams(host: "127.0.0.1", port: 1, database: "x", user: "x", sslMode: .disable, connectTimeout: 2)
        do {
            _ = try await PGConnection.connect(p)
            XCTFail("expected failure")
        } catch let error as PGError {
            XCTAssertEqual(error.kind, .connection)
            XCTAssertFalse(error.message.isEmpty)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

/// Requires a server: run via `make itest` (sets ELEFANTAS_ITEST=1 and the port).
final class PGConnectionIntegrationTests: XCTestCase {
    static var params: ConnectParams {
        let env = ProcessInfo.processInfo.environment
        return ConnectParams(
            host: env["ELEFANTAS_ITEST_HOST"] ?? "127.0.0.1",
            port: Int(env["ELEFANTAS_ITEST_PORT"] ?? "") ?? 54318,
            database: "elefantas", user: "elefantas", password: "elefantas", sslMode: .prefer)
    }

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ELEFANTAS_ITEST"] == "1", "integration tests disabled")
    }

    func testExecuteWithParamsAndNulls() async throws {
        let c = try await PGConnection.connect(Self.params)
        XCTAssertGreaterThanOrEqual(c.serverVersion, 170000)
        let r = try await c.execute("SELECT $1::int + 1 AS n, $2::text AS t, ''::text AS e", ["41", nil])
        XCTAssertEqual(r.columns.map(\.name), ["n", "t", "e"])
        XCTAssertEqual(r.rows, [["42", nil, ""]])
        await c.close()
        XCTAssertTrue(c.isClosed)
    }

    func testQueryErrorCarriesSQLState() async throws {
        let c = try await PGConnection.connect(Self.params)
        do {
            try await c.execute("SELECT * FROM no_such_table")
            XCTFail("expected failure")
        } catch let error as PGError {
            XCTAssertEqual(error.kind, .query)
            XCTAssertEqual(error.sqlState, "42P01")
            XCTAssertNotNil(error.position)
        }
        // Connection is still usable afterwards.
        let r = try await c.execute("SELECT 1")
        XCTAssertEqual(r.rows, [["1"]])
    }

    func testBadPassword() async throws {
        var p = Self.params
        p.password = "wrong"
        p.sslMode = .disable
        do {
            _ = try await PGConnection.connect(p)
            XCTFail("expected failure")
        } catch let error as PGError {
            XCTAssertEqual(error.kind, .connection)
        }
    }

    func testStreamDeliversAllRowsInBatches() async throws {
        let c = try await PGConnection.connect(Self.params)
        var total = 0
        var batches = 0
        var sawLast = false
        for try await batch in c.stream("SELECT g FROM generate_series(1, 100000) g", chunkSize: 1000) {
            XCTAssertLessThanOrEqual(batch.rows.count, 1000)
            total += batch.rows.count
            batches += 1
            sawLast = batch.isLast
        }
        XCTAssertEqual(total, 100000)
        XCTAssertGreaterThanOrEqual(batches, 100)
        XCTAssertTrue(sawLast)
    }

    func testCancelLongQuery() async throws {
        let c = try await PGConnection.connect(Self.params)
        let task = Task { try await c.execute("SELECT pg_sleep(30)") }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        c.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as PGError {
            XCTAssertTrue(error.isCancellation, "got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let r = try await c.execute("SELECT 1")
        XCTAssertEqual(r.rows, [["1"]])
    }

    func testTransactionRollsBackOnError() async throws {
        let c = try await PGConnection.connect(Self.params)
        try await c.execute("CREATE TEMP TABLE t (id int PRIMARY KEY)")
        do {
            try await c.transaction { s in
                try s.execute("INSERT INTO t VALUES (1)")
                try s.execute("INSERT INTO t VALUES (1)") // duplicate key
            }
            XCTFail("expected failure")
        } catch let error as PGError {
            XCTAssertEqual(error.sqlState, "23505")
        }
        let r = try await c.execute("SELECT count(*) FROM t")
        XCTAssertEqual(r.rows, [["0"]])
    }
}
