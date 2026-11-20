import XCTest
import PGKit
@testable import ElefantasCore

/// Requires the seeded Docker servers: run via `make itest`.
final class CatalogIntegrationTests: XCTestCase {
    var connection: PGConnection!

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["ELEFANTAS_ITEST"] == "1", "integration tests disabled")
        connection = try await PGConnection.connect(ConnectParams(
            host: env["ELEFANTAS_ITEST_HOST"] ?? "127.0.0.1",
            port: Int(env["ELEFANTAS_ITEST_PORT"] ?? "") ?? 54318,
            database: "elefantas", user: "elefantas", password: "elefantas"))
    }

    override func tearDown() async throws {
        await connection?.close()
    }

    func testDatabasesAndSchemas() async throws {
        let catalog = Catalog(connection: connection)
        let dbs = try await catalog.databases()
        XCTAssertTrue(dbs.contains("elefantas"))
        XCTAssertFalse(dbs.contains("template0"))

        let schemas = try await catalog.schemas()
        XCTAssertEqual(schemas.first { $0.name == "app" }?.isSystem, false)
        XCTAssertEqual(schemas.first { $0.name == "pg_catalog" }?.isSystem, true)
        XCTAssertFalse(schemas.contains { $0.name.hasPrefix("pg_toast") })
    }

    func testSchemaContents() async throws {
        let contents = try await Catalog(connection: connection).contents(schema: "app")
        let byName = Dictionary(uniqueKeysWithValues: contents.relations.map { ($0.ref.name, $0) })
        XCTAssertEqual(byName["users"]?.kind, .table)
        XCTAssertEqual(byName["active_users"]?.kind, .view)
        XCTAssertEqual(byName["event_counts"]?.kind, .materializedView)
        XCTAssertGreaterThan(byName["events"]?.estimatedRows ?? 0, 900_000)
        XCTAssertTrue(contents.functions.contains { $0.name == "user_count" && $0.kind == .function })
        XCTAssertTrue(contents.functions.contains { $0.name == "noop" && $0.kind == .procedure })
    }

    func testColumnsAndRowKey() async throws {
        let catalog = Catalog(connection: connection)
        let users = RelationRef(schema: "app", name: "users")
        let cols = try await catalog.columns(users)
        XCTAssertEqual(cols.map(\.name), ["id", "email", "name", "active", "created_at"])
        XCTAssertEqual(cols[0].typeName, "bigint")
        XCTAssertTrue(cols[0].notNull)
        XCTAssertNotNil(cols[0].defaultExpression)
        let key = try await catalog.rowKey(users, columns: cols)
        XCTAssertEqual(key, ["id"])

        let logs = RelationRef(schema: "app", name: "logs")
        let noKey = try await catalog.rowKey(logs, columns: try await catalog.columns(logs))
        XCTAssertNil(noKey)
    }

    func testQuotedIdentifiers() async throws {
        let catalog = Catalog(connection: connection)
        let weird = RelationRef(schema: "Mixed Case", name: "Weird \"Name\"")
        let cols = try await catalog.columns(weird)
        XCTAssertEqual(cols.map(\.name), ["id", "Select"])
        let d = PostgresDialect()
        let page = d.selectPage(weird, filter: .column(ColumnFilter(column: "Select", op: .equal, value: "")),
                                sort: nil, keyColumns: ["id"], limit: 10, offset: 0)
        let r = try await connection.execute(page.sql, page.params)
        XCTAssertEqual(r.rows, [["2", ""]])
    }
}
