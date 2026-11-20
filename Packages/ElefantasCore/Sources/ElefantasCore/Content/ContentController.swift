import Foundation
import Observation
import PGKit

public enum ContentError: Error, LocalizedError, Equatable {
    case readOnly(String)
    case rowNotFound

    public var errorDescription: String? {
        switch self {
        case .readOnly(let reason): reason
        case .rowNotFound: String(localized: "The row no longer exists or its key changed. Refresh and try again.")
        }
    }
}

public enum RowTotal: Equatable, Sendable {
    case unknown
    /// `pg_class.reltuples` (whole table, unfiltered).
    case estimated(Int64)
    case counting
    case exact(Int64)
}

/// State and actions for the Content tab: one relation, one page of rows in memory.
@MainActor
@Observable
public final class ContentController {
    public private(set) var relation: RelationInfo?
    public private(set) var columns: [ColumnInfo] = []
    /// Row-identity columns, or nil when the relation has none (read-only).
    public private(set) var keyColumns: [String]?
    /// Only the current page. Values are text; nil is SQL NULL.
    public private(set) var rows: [PGRow] = []
    /// Incremented on every change to `rows`, so the grid can reload cheaply.
    public private(set) var rowsVersion = 0
    public private(set) var offset = 0
    public private(set) var pageSize = 1000
    public private(set) var sort: SortSpec?
    public private(set) var filter: ContentFilter = .none
    public private(set) var total: RowTotal = .unknown
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    /// Called with errors from background fetches (e.g. to detect a dropped connection).
    public var onError: (@MainActor (Error) -> Void)?

    private let connection: PGConnection
    private let dialect = PostgresDialect()
    private var fetchTask: Task<Void, Never>?
    private var countTask: Task<Void, Never>?
    private var loadGeneration = 0

    public init(connection: PGConnection) {
        self.connection = connection
    }

    // MARK: - Derived state

    public var readOnlyReason: String? {
        guard let relation else { return nil }
        if !relation.kind.isTable { return String(localized: "Views are read-only.") }
        if keyColumns == nil { return String(localized: "This table has no primary key or unique NOT NULL key, so rows cannot be edited safely.") }
        return nil
    }

    public var isEditable: Bool { relation != nil && readOnlyReason == nil }
    public var hasPreviousPage: Bool { offset > 0 }
    public var hasNextPage: Bool {
        if case .exact(let n) = total { return Int64(offset + rows.count) < n }
        return rows.count >= pageSize
    }

    public func isColumnEditable(_ name: String) -> Bool {
        isEditable && !(columns.first { $0.name == name }?.isGenerated ?? false)
    }

    // MARK: - Loading

    /// Loads a relation: columns, row key, then the first page.
    public func load(_ relation: RelationInfo) async {
        cancelAll()
        loadGeneration += 1
        let generation = loadGeneration
        self.relation = relation
        columns = []
        keyColumns = nil
        rows = []
        rowsVersion += 1
        offset = 0
        sort = nil
        filter = .none
        errorMessage = nil
        total = relation.estimatedRows.map { .estimated($0) } ?? .unknown

        do {
            let catalog = Catalog(connection: connection)
            let cols = try await catalog.columns(relation.ref)
            let key = relation.kind.isTable ? try await catalog.rowKey(relation.ref, columns: cols) : nil
            guard generation == loadGeneration else { return }
            columns = cols
            keyColumns = key
        } catch {
            guard generation == loadGeneration else { return }
            report(error)
            return
        }
        reloadPage()
    }

    /// Re-fetches the current page. Cancels any fetch in flight.
    public func reloadPage() {
        guard let relation else { return }
        fetchTask?.cancel()
        let statement = dialect.selectPage(relation.ref, filter: filter, sort: sort, keyColumns: keyColumns ?? [],
                                           limit: pageSize, offset: offset)
        isLoading = true
        errorMessage = nil
        let generation = loadGeneration
        fetchTask = Task { [weak self, connection] in
            var first = true
            do {
                for try await batch in connection.stream(statement.sql, statement.params, chunkSize: 250) {
                    guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
                    let aligned = self.align(batch.rows, from: batch.columns)
                    if first {
                        self.rows = aligned
                        first = false
                    } else {
                        self.rows.append(contentsOf: aligned)
                    }
                    self.rowsVersion += 1
                }
                guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
                self.isLoading = false
                if first { // no batch at all
                    self.rows = []
                    self.rowsVersion += 1
                }
                if self.rows.count < self.pageSize, !self.totalIsExact {
                    self.total = .exact(Int64(self.offset + self.rows.count))
                }
            } catch {
                guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
                self.isLoading = false
                self.report(error)
            }
        }
    }

    private var totalIsExact: Bool {
        if case .exact = total { return true }
        return false
    }

    public func nextPage() {
        guard hasNextPage else { return }
        offset += pageSize
        reloadPage()
    }

    public func previousPage() {
        guard hasPreviousPage else { return }
        offset = max(0, offset - pageSize)
        reloadPage()
    }

    public func setPageSize(_ size: Int) {
        let size = max(10, min(size, 100_000))
        guard size != pageSize else { return }
        pageSize = size
        offset = 0
        reloadPage()
    }

    /// Header click: new column sorts ascending, the same column flips direction.
    public func toggleSort(column: String) {
        if sort?.column == column {
            sort?.ascending.toggle()
        } else {
            sort = SortSpec(column: column, ascending: true)
        }
        offset = 0
        reloadPage()
    }

    public func applyFilter(_ filter: ContentFilter) {
        self.filter = filter
        offset = 0
        if filter == .none {
            total = relation?.estimatedRows.map { .estimated($0) } ?? .unknown
        } else {
            total = .unknown
        }
        reloadPage()
    }

    /// Runs an exact count(*) with the current filter. Cancellable via `cancelCount()`.
    public func countRows() {
        guard let relation else { return }
        countTask?.cancel()
        let statement = dialect.count(relation.ref, filter: filter)
        let previous = total
        total = .counting
        let generation = loadGeneration
        countTask = Task { [weak self, connection] in
            do {
                let result = try await connection.execute(statement.sql, statement.params)
                guard let self, generation == self.loadGeneration else { return }
                if let text = result.rows.first?.first ?? nil, let n = Int64(text) {
                    self.total = .exact(n)
                } else {
                    self.total = previous
                }
            } catch {
                guard let self, generation == self.loadGeneration else { return }
                self.total = previous
                if (error as? PGError)?.isCancellation != true { self.report(error) }
            }
        }
    }

    public func cancelCount() {
        guard countTask != nil, total == .counting else { return }
        connection.cancel()
        countTask = nil
    }

    public func cancelAll() {
        fetchTask?.cancel()
        fetchTask = nil
        if total == .counting { cancelCount() }
        countTask?.cancel()
        countTask = nil
    }

    // MARK: - Editing

    /// Sets one cell. The row is re-read from `RETURNING *`, so defaults and triggers show up.
    public func updateCell(row: Int, column: String, value: String?) async throws {
        let (relation, key) = try editContext(row: row)
        guard isColumnEditable(column) else { throw ContentError.readOnly(String(localized: "This column is generated and cannot be edited.")) }
        let statement = dialect.update(relation.ref, key: key, set: [(column, value)])
        let result = try await connection.execute(statement.sql, statement.params)
        guard let updated = result.rows.first else { throw ContentError.rowNotFound }
        let aligned = align([updated], from: result.columns)[0]
        if let idx = indexOfRow(withKey: key) {
            rows[idx] = aligned
            rowsVersion += 1
        }
    }

    /// Inserts a row (omitted columns use their defaults) and appends it to the current page.
    @discardableResult
    public func insertRow(values: [String: String?]) async throws -> Int {
        guard let relation, isEditable else { throw ContentError.readOnly(readOnlyReason ?? "") }
        let ordered = columns.compactMap { col -> (String, String?)? in
            guard let value = values[col.name] else { return nil }
            return (col.name, value)
        }
        let statement = dialect.insert(relation.ref, values: ordered)
        let result = try await connection.execute(statement.sql, statement.params)
        guard let inserted = result.rows.first else { throw ContentError.rowNotFound }
        rows.append(align([inserted], from: result.columns)[0])
        rowsVersion += 1
        if case .exact(let n) = total { total = .exact(n + 1) }
        return rows.count - 1
    }

    /// Deletes rows in one transaction; if any row is missing, nothing is deleted.
    public func deleteRows(_ indices: IndexSet) async throws {
        guard let relation, isEditable, !indices.isEmpty else { throw ContentError.readOnly(readOnlyReason ?? "") }
        let keys = try indices.map { try editContext(row: $0).key }
        let statements = keys.map { dialect.delete(relation.ref, key: $0) }
        try await connection.transaction { session in
            for statement in statements {
                let result = try session.execute(statement.sql, statement.params)
                if result.affectedRows != 1 { throw ContentError.rowNotFound }
            }
        }
        let doomed = Set(keys.compactMap { indexOfRow(withKey: $0) })
        rows = rows.enumerated().filter { !doomed.contains($0.offset) }.map(\.element)
        rowsVersion += 1
        if case .exact(let n) = total { total = .exact(max(0, n - Int64(doomed.count))) }
    }

    // MARK: - Helpers

    private func editContext(row: Int) throws -> (relation: RelationInfo, key: [(String, String?)]) {
        guard let relation, let keyColumns, isEditable else { throw ContentError.readOnly(readOnlyReason ?? "") }
        guard rows.indices.contains(row) else { throw ContentError.rowNotFound }
        let key = keyColumns.map { name -> (String, String?) in
            let idx = columns.firstIndex { $0.name == name }
            return (name, idx.flatMap { rows[row][$0] })
        }
        return (relation, key)
    }

    private func indexOfRow(withKey key: [(String, String?)]) -> Int? {
        let positions = key.map { k in columns.firstIndex { $0.name == k.0 } }
        return rows.firstIndex { row in
            zip(positions, key).allSatisfy { pos, k in pos.map { row[$0] == k.1 } ?? false }
        }
    }

    /// Reorders result values to match `columns` by name (guards against column-order drift).
    private func align(_ rows: [PGRow], from resultColumns: [PGColumn]) -> [PGRow] {
        let names = resultColumns.map(\.name)
        if names == columns.map(\.name) { return rows }
        if columns.isEmpty {
            columns = resultColumns.enumerated().map { i, c in
                ColumnInfo(name: c.name, typeName: "", typeOID: c.typeOID, notNull: false,
                           defaultExpression: nil, position: i + 1, isGenerated: false)
            }
            return rows
        }
        let map = columns.map { col in names.firstIndex(of: col.name) }
        return rows.map { row in map.map { $0.flatMap { row[$0] } } }
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
        onError?(error)
    }
}
