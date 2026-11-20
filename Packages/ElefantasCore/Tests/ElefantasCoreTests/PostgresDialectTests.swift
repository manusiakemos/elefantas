import XCTest
@testable import ElefantasCore

final class PostgresDialectTests: XCTestCase {
    let d = PostgresDialect()
    let users = RelationRef(schema: "app", name: "users")

    func testQuoteIdentEscapesQuotes() {
        XCTAssertEqual(d.quoteIdent("plain"), "\"plain\"")
        XCTAssertEqual(d.quoteIdent("Weird \"Name\""), "\"Weird \"\"Name\"\"\"")
        XCTAssertEqual(d.qualified(RelationRef(schema: "Mixed Case", name: "t")), "\"Mixed Case\".\"t\"")
    }

    func testSelectPageDefaultOrdersByKey() {
        let s = d.selectPage(users, filter: .none, sort: nil, keyColumns: ["id"], limit: 1000, offset: 2000)
        XCTAssertEqual(s.sql, "SELECT * FROM \"app\".\"users\" ORDER BY \"id\" LIMIT 1000 OFFSET 2000")
        XCTAssertEqual(s.params, [])
    }

    func testSelectPageSortThenKeyTiebreak() {
        let s = d.selectPage(users, filter: .none, sort: SortSpec(column: "name", ascending: false),
                             keyColumns: ["id"], limit: 10, offset: 0)
        XCTAssertEqual(s.sql, "SELECT * FROM \"app\".\"users\" ORDER BY \"name\" DESC, \"id\" LIMIT 10 OFFSET 0")
    }

    func testSelectPageNoKeyNoSortHasNoOrderBy() {
        let s = d.selectPage(users, filter: .none, sort: nil, keyColumns: [], limit: 10, offset: 0)
        XCTAssertFalse(s.sql.contains("ORDER BY"))
    }

    func testColumnFiltersBindValues() {
        func clause(_ f: ColumnFilter) -> (String?, [String?]) {
            var params: [String?] = []
            let sql = d.whereClause(.column(f), params: &params)
            return (sql, params)
        }
        XCTAssertEqual(clause(ColumnFilter(column: "id", op: .equal, value: "5")).0, "\"id\" = $1")
        XCTAssertEqual(clause(ColumnFilter(column: "id", op: .equal, value: "5")).1, ["5"])
        XCTAssertEqual(clause(ColumnFilter(column: "name", op: .contains, value: "50%_x")).1, ["%50\\%\\_x%"])
        XCTAssertEqual(clause(ColumnFilter(column: "name", op: .contains, value: "a")).0, "\"name\"::text ILIKE $1")
        XCTAssertEqual(clause(ColumnFilter(column: "n", op: .isNull)).0, "\"n\" IS NULL")
        XCTAssertEqual(clause(ColumnFilter(column: "n", op: .isNull)).1, [])
        XCTAssertEqual(clause(ColumnFilter(column: "n", op: .between, value: "1", secondValue: "9")).0,
                       "\"n\" BETWEEN $1 AND $2")
        let inList = clause(ColumnFilter(column: "id", op: .inList, value: "1, 2 ,3"))
        XCTAssertEqual(inList.0, "\"id\" IN ($1, $2, $3)")
        XCTAssertEqual(inList.1, ["1", "2", "3"])
        XCTAssertEqual(clause(ColumnFilter(column: "id", op: .notEqual, value: "1")).0, "\"id\" IS DISTINCT FROM $1")
    }

    func testFilterParamsPrecedeLimit() {
        let s = d.selectPage(users, filter: .column(ColumnFilter(column: "email", op: .like, value: "a%")),
                             sort: nil, keyColumns: ["id"], limit: 5, offset: 0)
        XCTAssertEqual(s.sql, "SELECT * FROM \"app\".\"users\" WHERE \"email\"::text LIKE $1 ORDER BY \"id\" LIMIT 5 OFFSET 0")
        XCTAssertEqual(s.params, ["a%"])
    }

    func testRawWhereIsParenthesizedAndBlankIgnored() {
        var p: [String?] = []
        XCTAssertEqual(d.whereClause(.rawWhere(" id > 3 OR id < 1 "), params: &p), "(id > 3 OR id < 1)")
        XCTAssertNil(d.whereClause(.rawWhere("   "), params: &p))
    }

    func testUpdateInsertDelete() {
        let u = d.update(users, key: [("id", "7")], set: [("name", nil), ("email", "x@y")])
        XCTAssertEqual(u.sql, "UPDATE \"app\".\"users\" SET \"name\" = $1, \"email\" = $2 WHERE \"id\" = $3 RETURNING *")
        XCTAssertEqual(u.params, [nil, "x@y", "7"])

        let i = d.insert(users, values: [("email", "a@b"), ("name", nil)])
        XCTAssertEqual(i.sql, "INSERT INTO \"app\".\"users\" (\"email\", \"name\") VALUES ($1, $2) RETURNING *")
        XCTAssertEqual(i.params, ["a@b", nil])
        XCTAssertEqual(d.insert(users, values: []).sql, "INSERT INTO \"app\".\"users\" DEFAULT VALUES RETURNING *")

        let del = d.delete(users, key: [("a", "1"), ("b", "2")])
        XCTAssertEqual(del.sql, "DELETE FROM \"app\".\"users\" WHERE \"a\" = $1 AND \"b\" = $2")
        XCTAssertEqual(del.params, ["1", "2"])
    }

    func testCountUsesFilter() {
        let c = d.count(users, filter: .column(ColumnFilter(column: "active", op: .equal, value: "true")))
        XCTAssertEqual(c.sql, "SELECT count(*) FROM \"app\".\"users\" WHERE \"active\" = $1")
        XCTAssertEqual(c.params, ["true"])
    }
}
