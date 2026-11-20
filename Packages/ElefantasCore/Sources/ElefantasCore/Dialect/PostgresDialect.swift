import Foundation

/// The only place in the app that writes PostgreSQL SQL.
/// Every function is pure: it returns SQL text plus parameters, never executes anything.
/// User-supplied values always go through `$n` parameters; identifiers are always quoted.
public struct PostgresDialect: Sendable {
    public init() {}

    // MARK: - Identifiers

    public func quoteIdent(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public func qualified(_ ref: RelationRef) -> String {
        quoteIdent(ref.schema) + "." + quoteIdent(ref.name)
    }

    // MARK: - Catalog

    public func listDatabases() -> SQLStatement {
        SQLStatement("""
            SELECT datname FROM pg_catalog.pg_database
            WHERE datallowconn AND NOT datistemplate
            ORDER BY datname
            """)
    }

    /// Columns: name, is_system.
    public func listSchemas() -> SQLStatement {
        SQLStatement("""
            SELECT n.nspname,
                   (n.nspname LIKE 'pg\\_%' OR n.nspname = 'information_schema'
                    OR n.nspname LIKE '\\_timescaledb%' OR n.nspname LIKE 'timescaledb\\_%') AS is_system
            FROM pg_catalog.pg_namespace n
            WHERE n.nspname NOT LIKE 'pg\\_toast%' AND n.nspname NOT LIKE 'pg\\_temp\\_%'
            ORDER BY 2, 1
            """)
    }

    /// Columns: oid, relname, relkind, reltuples. Partitions are hidden (their parent is shown).
    public func listRelations(schema: String) -> SQLStatement {
        SQLStatement("""
            SELECT c.oid, c.relname, c.relkind, c.reltuples::bigint
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1
              AND c.relkind IN ('r','p','v','m','f')
              AND NOT c.relispartition
            ORDER BY c.relname
            """, [schema])
    }

    /// Columns: oid, proname, identity arguments, prokind. Extension members are hidden.
    public func listFunctions(schema: String) -> SQLStatement {
        SQLStatement("""
            SELECT p.oid, p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid), p.prokind
            FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = $1
              AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d
                              WHERE d.classid = 'pg_catalog.pg_proc'::regclass
                                AND d.objid = p.oid AND d.deptype = 'e')
            ORDER BY p.proname, 3
            """, [schema])
    }

    private let relationOID = """
        (SELECT c.oid FROM pg_catalog.pg_class c
         JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = $1 AND c.relname = $2)
        """

    /// Columns: attname, type, typoid, notnull, default, attnum, generated.
    public func listColumns(_ ref: RelationRef) -> SQLStatement {
        SQLStatement("""
            SELECT a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod), a.atttypid,
                   a.attnotnull, pg_catalog.pg_get_expr(d.adbin, d.adrelid), a.attnum,
                   (a.attidentity <> '' OR a.attgenerated <> '') AS generated
            FROM pg_catalog.pg_attribute a
            LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = \(relationOID)
              AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """, [ref.schema, ref.name])
    }

    /// Candidate row-identity keys: the primary key first, then plain unique indexes
    /// (no expressions, no predicate). Columns: index oid, is_primary, attname, ordinal.
    /// The caller picks the first candidate whose columns are all NOT NULL.
    public func listKeyCandidates(_ ref: RelationRef) -> SQLStatement {
        SQLStatement("""
            SELECT i.indexrelid, i.indisprimary, a.attname, k.ord
            FROM pg_catalog.pg_index i
            CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
            JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
            WHERE i.indrelid = \(relationOID)
              AND (i.indisprimary OR (i.indisunique AND i.indpred IS NULL AND i.indexprs IS NULL))
              AND k.ord <= i.indnkeyatts
            ORDER BY i.indisprimary DESC, i.indexrelid, k.ord
            """, [ref.schema, ref.name])
    }

    // MARK: - Content

    public func selectPage(_ ref: RelationRef, filter: ContentFilter, sort: SortSpec?,
                           keyColumns: [String], limit: Int, offset: Int) -> SQLStatement {
        var params: [String?] = []
        var sql = "SELECT * FROM \(qualified(ref))"
        if let whereSQL = whereClause(filter, params: &params) { sql += " WHERE \(whereSQL)" }

        // ORDER BY the user's sort, then the key, so OFFSET paging is deterministic.
        var order: [String] = []
        if let sort { order.append("\(quoteIdent(sort.column)) \(sort.ascending ? "ASC" : "DESC")") }
        for key in keyColumns where key != sort?.column { order.append(quoteIdent(key)) }
        if !order.isEmpty { sql += " ORDER BY " + order.joined(separator: ", ") }

        sql += " LIMIT \(max(0, limit)) OFFSET \(max(0, offset))"
        return SQLStatement(sql, params)
    }

    public func count(_ ref: RelationRef, filter: ContentFilter) -> SQLStatement {
        var params: [String?] = []
        var sql = "SELECT count(*) FROM \(qualified(ref))"
        if let whereSQL = whereClause(filter, params: &params) { sql += " WHERE \(whereSQL)" }
        return SQLStatement(sql, params)
    }

    /// UPDATE one row identified by `key` (column → value). Returns the updated row.
    public func update(_ ref: RelationRef, key: [(String, String?)], set: [(String, String?)]) -> SQLStatement {
        precondition(!key.isEmpty && !set.isEmpty)
        var params: [String?] = []
        let assignments = set.map { column, value in
            params.append(value)
            return "\(quoteIdent(column)) = $\(params.count)"
        }
        let conditions = keyConditions(key, params: &params)
        return SQLStatement(
            "UPDATE \(qualified(ref)) SET \(assignments.joined(separator: ", ")) WHERE \(conditions) RETURNING *",
            params)
    }

    /// INSERT one row. Columns not listed get their defaults. Returns the inserted row.
    public func insert(_ ref: RelationRef, values: [(String, String?)]) -> SQLStatement {
        guard !values.isEmpty else {
            return SQLStatement("INSERT INTO \(qualified(ref)) DEFAULT VALUES RETURNING *")
        }
        let columns = values.map { quoteIdent($0.0) }.joined(separator: ", ")
        let placeholders = values.indices.map { "$\($0 + 1)" }.joined(separator: ", ")
        return SQLStatement(
            "INSERT INTO \(qualified(ref)) (\(columns)) VALUES (\(placeholders)) RETURNING *",
            values.map(\.1))
    }

    /// DELETE one row identified by `key`.
    public func delete(_ ref: RelationRef, key: [(String, String?)]) -> SQLStatement {
        precondition(!key.isEmpty)
        var params: [String?] = []
        let conditions = keyConditions(key, params: &params)
        return SQLStatement("DELETE FROM \(qualified(ref)) WHERE \(conditions)", params)
    }

    // MARK: - Helpers

    private func keyConditions(_ key: [(String, String?)], params: inout [String?]) -> String {
        key.map { column, value in
            guard let value else { return "\(quoteIdent(column)) IS NULL" }
            params.append(value)
            return "\(quoteIdent(column)) = $\(params.count)"
        }.joined(separator: " AND ")
    }

    func whereClause(_ filter: ContentFilter, params: inout [String?]) -> String? {
        switch filter {
        case .none:
            return nil
        case .rawWhere(let expression):
            let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "(\(trimmed))"
        case .column(let f):
            let col = quoteIdent(f.column)
            func bind(_ value: String) -> String {
                params.append(value)
                return "$\(params.count)"
            }
            switch f.op {
            case .equal: return "\(col) = \(bind(f.value))"
            case .notEqual: return "\(col) IS DISTINCT FROM \(bind(f.value))"
            case .less: return "\(col) < \(bind(f.value))"
            case .lessOrEqual: return "\(col) <= \(bind(f.value))"
            case .greater: return "\(col) > \(bind(f.value))"
            case .greaterOrEqual: return "\(col) >= \(bind(f.value))"
            case .contains: return "\(col)::text ILIKE \(bind("%" + escapeLike(f.value) + "%"))"
            case .like: return "\(col)::text LIKE \(bind(f.value))"
            case .notLike: return "\(col)::text NOT LIKE \(bind(f.value))"
            case .iLike: return "\(col)::text ILIKE \(bind(f.value))"
            case .isNull: return "\(col) IS NULL"
            case .isNotNull: return "\(col) IS NOT NULL"
            case .between: return "\(col) BETWEEN \(bind(f.value)) AND \(bind(f.secondValue))"
            case .inList:
                let items = f.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard !items.isEmpty else { return "false" }
                return "\(col) IN (\(items.map { bind($0) }.joined(separator: ", ")))"
            }
        }
    }

    /// Escapes LIKE wildcards so the value matches literally.
    func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
