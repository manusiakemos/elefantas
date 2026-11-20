import Foundation

/// Schema-qualified relation name.
public struct RelationRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public var schema: String
    public var name: String

    public init(schema: String, name: String) {
        self.schema = schema
        self.name = name
    }

    public var description: String { "\(schema).\(name)" }
}

public enum RelationKind: String, Sendable, Codable, CaseIterable {
    case table = "r"
    case partitionedTable = "p"
    case view = "v"
    case materializedView = "m"
    case foreignTable = "f"

    public var isTable: Bool { self == .table || self == .partitionedTable }
}

public struct SchemaInfo: Hashable, Sendable, Identifiable {
    public var name: String
    public var isSystem: Bool
    public var id: String { name }
}

public struct RelationInfo: Hashable, Sendable, Identifiable {
    public var oid: UInt32
    public var ref: RelationRef
    public var kind: RelationKind
    /// `pg_class.reltuples`; nil when the relation was never analyzed.
    public var estimatedRows: Int64?
    public var id: UInt32 { oid }
}

public enum FunctionKind: String, Sendable, Codable {
    case function = "f"
    case procedure = "p"
    case aggregate = "a"
    case window = "w"
}

public struct FunctionInfo: Hashable, Sendable, Identifiable {
    public var oid: UInt32
    public var schema: String
    public var name: String
    public var arguments: String
    public var kind: FunctionKind
    public var id: UInt32 { oid }
    public var signature: String { "\(name)(\(arguments))" }
}

public struct ColumnInfo: Hashable, Sendable, Identifiable {
    public var name: String
    public var typeName: String
    public var typeOID: UInt32
    public var notNull: Bool
    public var defaultExpression: String?
    /// 1-based attribute number.
    public var position: Int
    /// True for identity or generated columns.
    public var isGenerated: Bool
    public var id: String { name }
}

/// Content of the object explorer for one schema.
public struct SchemaContents: Sendable, Hashable {
    public var relations: [RelationInfo]
    public var functions: [FunctionInfo]
}
