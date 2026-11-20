import XCTest
import PGKit
@testable import ElefantasCore

/// Content round trip against the seeded Docker servers: run via `make itest`.
@MainActor
final class ContentIntegrationTests: XCTestCase {
    var connection: PGConnection!
    var table: RelationRef!

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["ELEFANTAS_ITEST"] == "1", "integration tests disabled")
        connection = try await PGConnection.connect(ConnectParams(
            host: env["ELEFANTAS_ITEST_HOST"] ?? "127.0.0.1",
            port: Int(env["ELEFANTAS_ITEST_PORT"] ?? "") ?? 54318,
            database: "elefantas", user: "elefantas", password: "elefantas"))
        table = RelationRef(schema: "app", name: "itest_\(UUID().uuidString.prefix(8).lowercased())")
        let d = PostgresDialect()
        try await connection.execute("""
            CREATE TABLE \(d.qualified(table)) (
              id serial PRIMARY KEY, name text, qty int NOT NULL DEFAULT 0,
              doubled int GENERATED ALWAYS AS (qty * 2) STORED)
            """)
        try await connection.execute("INSERT INTO \(d.qualified(table)) (name, qty) SELECT 'item ' || g, g FROM generate_series(1, 25) g")
    }

    override func tearDown() async throws {
        if let connection, let table {
            try? await connection.execute("DROP TABLE IF EXISTS \(PostgresDialect().qualified(table))")
            await connection.close()
        }
    }

    private func relationInfo() async throws -> RelationInfo {
        let contents = try await Catalog(connection: connection).contents(schema: "app")
        return try XCTUnwrap(contents.relations.first { $0.ref == table })
    }

    private func waitForPage(_ c: ContentController) async throws {
        for _ in 0..<200 where c.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(c.isLoading)
        XCTAssertNil(c.errorMessage)
    }

    func testPagingSortFilter() async throws {
        let c = ContentController(connection: connection)
        await c.load(try await relationInfo())
        c.setPageSize(10)
        try await waitForPage(c)
        XCTAssertEqual(c.columns.map(\.name), ["id", "name", "qty", "doubled"])
        XCTAssertEqual(c.keyColumns, ["id"])
        XCTAssertTrue(c.isEditable)
        XCTAssertFalse(c.isColumnEditable("doubled"))
        XCTAssertEqual(c.rows.count, 10)
        XCTAssertEqual(c.rows.first?[0], "1")
        XCTAssertTrue(c.hasNextPage)

        c.nextPage(); try await waitForPage(c)
        c.nextPage(); try await waitForPage(c)
        XCTAssertEqual(c.rows.count, 5)
        XCTAssertEqual(c.total, .exact(25))
        XCTAssertFalse(c.hasNextPage)

        c.toggleSort(column: "qty"); c.toggleSort(column: "qty") // descending
        try await waitForPage(c)
        XCTAssertEqual(c.offset, 0)
        XCTAssertEqual(c.rows.first?[2], "25")

        c.applyFilter(.column(ColumnFilter(column: "name", op: .contains, value: "item 1")))
        try await waitForPage(c)
        // 11 matches, page size 10, sorted by qty DESC: page 1 is items 19…10.
        XCTAssertEqual(c.rows.compactMap { $0[1] }, (10...19).reversed().map { "item \($0)" })
        XCTAssertTrue(c.hasNextPage)

        c.countRows()
        for _ in 0..<200 where c.total == .counting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(c.total, .exact(11))
    }

    func testEditInsertDelete() async throws {
        let c = ContentController(connection: connection)
        await c.load(try await relationInfo())
        try await waitForPage(c)

        try await c.updateCell(row: 0, column: "qty", value: "100")
        XCTAssertEqual(c.rows[0][2], "100")
        XCTAssertEqual(c.rows[0][3], "200", "generated column re-read via RETURNING")
        try await c.updateCell(row: 0, column: "name", value: nil)
        XCTAssertNil(c.rows[0][1])

        let idx = try await c.insertRow(values: ["name": "new"])
        XCTAssertEqual(c.rows[idx][1], "new")
        XCTAssertEqual(c.rows[idx][2], "0", "default applied")
        XCTAssertEqual(c.rows.count, 26)

        try await c.deleteRows(IndexSet([0, idx]))
        XCTAssertEqual(c.rows.count, 24)
        let count = try await connection.execute("SELECT count(*) FROM \(PostgresDialect().qualified(table))")
        XCTAssertEqual(count.rows, [["24"]])
    }

    func testNoKeyTableIsReadOnly() async throws {
        let contents = try await Catalog(connection: connection).contents(schema: "app")
        let logs = try XCTUnwrap(contents.relations.first { $0.ref.name == "logs" })
        let c = ContentController(connection: connection)
        await c.load(logs)
        try await waitForPage(c)
        XCTAssertFalse(c.isEditable)
        XCTAssertNotNil(c.readOnlyReason)
        XCTAssertEqual(c.rows.count, 3)
        do {
            try await c.updateCell(row: 0, column: "line", value: "x")
            XCTFail("expected read-only error")
        } catch is ContentError {}
    }
}
