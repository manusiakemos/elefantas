import Foundation
import Observation
import PGKit

/// Case-insensitive subsequence match ("usr" matches "app_users").
public enum FuzzyMatch {
    public static func matches(_ query: String, _ candidate: String) -> Bool {
        let q = query.lowercased().filter { !$0.isWhitespace }
        guard !q.isEmpty else { return true }
        var it = q.makeIterator()
        var next = it.next()
        for ch in candidate.lowercased() where ch == next {
            next = it.next()
            if next == nil { return true }
        }
        return false
    }
}

/// Sidebar state: schemas and their objects for the current database.
@MainActor
@Observable
public final class ExplorerModel {
    public private(set) var schemas: [SchemaInfo] = []
    public private(set) var contents: [String: SchemaContents] = [:]
    public private(set) var loadingSchemas: Set<String> = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public var expandedSchemas: Set<String> = []
    public var showSystemSchemas = false {
        didSet { if filterText.isEmpty == false { Task { await loadAllVisible() } } }
    }
    public var filterText = "" {
        didSet { if !filterText.isEmpty { Task { await loadAllVisible() } } }
    }

    private let catalog: Catalog

    public init(connection: PGConnection) {
        self.catalog = Catalog(connection: connection)
    }

    public var visibleSchemas: [SchemaInfo] {
        let base = showSystemSchemas ? schemas : schemas.filter { !$0.isSystem }
        guard !filterText.isEmpty else { return base }
        return base.filter { schema in
            guard let c = contents[schema.name] else { return false }
            return c.relations.contains { FuzzyMatch.matches(filterText, $0.ref.name) }
                || c.functions.contains { FuzzyMatch.matches(filterText, $0.name) }
        }
    }

    public func relations(in schema: String) -> [RelationInfo] {
        let all = contents[schema]?.relations ?? []
        return filterText.isEmpty ? all : all.filter { FuzzyMatch.matches(filterText, $0.ref.name) }
    }

    public func functions(in schema: String) -> [FunctionInfo] {
        let all = contents[schema]?.functions ?? []
        return filterText.isEmpty ? all : all.filter { FuzzyMatch.matches(filterText, $0.name) }
    }

    public func relation(_ ref: RelationRef) -> RelationInfo? {
        contents[ref.schema]?.relations.first { $0.ref == ref }
    }

    /// Reloads schemas and the contents of every loaded or non-system schema.
    public func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            schemas = try await catalog.schemas()
            let names = Set(schemas.map(\.name))
            contents = contents.filter { names.contains($0.key) }
            if expandedSchemas.isEmpty {
                // Expand "public" (or the first user schema) on first load, like Sequel Ace's table list.
                if let first = schemas.first(where: { $0.name == "public" }) ?? schemas.first(where: { !$0.isSystem }) {
                    expandedSchemas.insert(first.name)
                }
            }
            for schema in schemas where !schema.isSystem || contents[schema.name] != nil {
                await loadContents(schema.name, force: true)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func loadContents(_ schema: String, force: Bool = false) async {
        guard force || contents[schema] == nil, !loadingSchemas.contains(schema) else { return }
        loadingSchemas.insert(schema)
        defer { loadingSchemas.remove(schema) }
        do {
            contents[schema] = try await catalog.contents(schema: schema)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadAllVisible() async {
        let base = showSystemSchemas ? schemas : schemas.filter { !$0.isSystem }
        for schema in base where contents[schema.name] == nil {
            await loadContents(schema.name)
        }
    }
}
