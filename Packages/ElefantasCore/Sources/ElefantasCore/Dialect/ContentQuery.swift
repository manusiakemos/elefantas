import Foundation

/// A SQL statement plus its text-format parameters ($1, $2, ...).
public struct SQLStatement: Hashable, Sendable {
    public var sql: String
    public var params: [String?]

    public init(_ sql: String, _ params: [String?] = []) {
        self.sql = sql
        self.params = params
    }
}

public enum FilterOperator: String, Sendable, Codable, CaseIterable, Identifiable {
    case equal = "="
    case notEqual = "≠"
    case less = "<"
    case lessOrEqual = "≤"
    case greater = ">"
    case greaterOrEqual = "≥"
    case contains = "contains"
    case like = "LIKE"
    case notLike = "NOT LIKE"
    case iLike = "ILIKE"
    case isNull = "IS NULL"
    case isNotNull = "IS NOT NULL"
    case inList = "IN"
    case between = "BETWEEN"

    public var id: String { rawValue }

    /// Number of values the operator takes (IN takes a comma-separated list in one field).
    public var valueCount: Int {
        switch self {
        case .isNull, .isNotNull: 0
        case .between: 2
        default: 1
        }
    }
}

public struct ColumnFilter: Hashable, Sendable, Codable {
    public var column: String
    public var op: FilterOperator
    public var value: String
    public var secondValue: String

    public init(column: String, op: FilterOperator, value: String = "", secondValue: String = "") {
        self.column = column
        self.op = op
        self.value = value
        self.secondValue = secondValue
    }
}

public enum ContentFilter: Hashable, Sendable, Codable {
    case none
    case column(ColumnFilter)
    /// Raw SQL expression placed after WHERE. Executed verbatim: user-authored.
    case rawWhere(String)
}

public struct SortSpec: Hashable, Sendable, Codable {
    public var column: String
    public var ascending: Bool

    public init(column: String, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}
