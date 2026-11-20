import Foundation
import PGKit

/// Reads the object catalog of the connected database. SQL comes from `PostgresDialect`.
public struct Catalog: Sendable {
    public let connection: PGConnection
    public let dialect: PostgresDialect

    public init(connection: PGConnection, dialect: PostgresDialect = PostgresDialect()) {
        self.connection = connection
        self.dialect = dialect
    }

    public func databases() async throws -> [String] {
        try await run(dialect.listDatabases()).rows.compactMap { $0[0] }
    }

    public func schemas() async throws -> [SchemaInfo] {
        try await run(dialect.listSchemas()).rows.map {
            SchemaInfo(name: $0[0] ?? "", isSystem: $0[1] == "t")
        }
    }

    public func contents(schema: String) async throws -> SchemaContents {
        let relations = try await run(dialect.listRelations(schema: schema)).rows.compactMap { row -> RelationInfo? in
            guard let oid = row[0].flatMap(UInt32.init), let name = row[1],
                  let kind = row[2].flatMap(RelationKind.init(rawValue:)) else { return nil }
            let estimate = row[3].flatMap(Int64.init)
            return RelationInfo(oid: oid, ref: RelationRef(schema: schema, name: name), kind: kind,
                                estimatedRows: (estimate ?? -1) < 0 ? nil : estimate)
        }
        let functions = try await run(dialect.listFunctions(schema: schema)).rows.compactMap { row -> FunctionInfo? in
            guard let oid = row[0].flatMap(UInt32.init), let name = row[1] else { return nil }
            return FunctionInfo(oid: oid, schema: schema, name: name, arguments: row[2] ?? "",
                                kind: row[3].flatMap(FunctionKind.init(rawValue:)) ?? .function)
        }
        return SchemaContents(relations: relations, functions: functions)
    }

    public func columns(_ ref: RelationRef) async throws -> [ColumnInfo] {
        try await run(dialect.listColumns(ref)).rows.map { row in
            ColumnInfo(name: row[0] ?? "", typeName: row[1] ?? "", typeOID: row[2].flatMap(UInt32.init) ?? 0,
                       notNull: row[3] == "t", defaultExpression: row[4], position: row[5].flatMap(Int.init) ?? 0,
                       isGenerated: row[6] == "t")
        }
    }

    /// Columns that identify a row (primary key, else a unique index over NOT NULL columns),
    /// or nil if the relation has none, in which case Content is read-only.
    public func rowKey(_ ref: RelationRef, columns: [ColumnInfo]) async throws -> [String]? {
        let rows = try await run(dialect.listKeyCandidates(ref)).rows
        let notNull = Set(columns.filter(\.notNull).map(\.name))
        var candidates: [(oid: String, columns: [String])] = []
        for row in rows {
            guard let oid = row[0], let column = row[2] else { continue }
            if candidates.last?.oid == oid {
                candidates[candidates.count - 1].columns.append(column)
            } else {
                candidates.append((oid, [column]))
            }
        }
        return candidates.first { $0.columns.allSatisfy(notNull.contains) }?.columns
    }

    private func run(_ statement: SQLStatement) async throws -> PGResult {
        try await connection.execute(statement.sql, statement.params)
    }
}
