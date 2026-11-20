import CLibPQ
import Foundation

public struct PGError: Error, Sendable, Hashable, LocalizedError {
    public enum Kind: Sendable, Hashable {
        case connection
        case query
        case closed
    }

    public var kind: Kind
    public var message: String
    public var sqlState: String?
    public var severity: String?
    public var detail: String?
    public var hint: String?
    /// 1-based character position in the query text, when reported.
    public var position: Int?

    public init(kind: Kind, message: String, sqlState: String? = nil, severity: String? = nil,
                detail: String? = nil, hint: String? = nil, position: Int? = nil) {
        self.kind = kind
        self.message = message
        self.sqlState = sqlState
        self.severity = severity
        self.detail = detail
        self.hint = hint
        self.position = position
    }

    public var errorDescription: String? { message }

    /// SQLSTATE 57014: the statement was cancelled (by `PGConnection.cancel()` or a timeout).
    public var isCancellation: Bool { sqlState == "57014" }

    static let closed = PGError(kind: .closed, message: "The connection is closed.")

    static func connection(_ conn: OpaquePointer?) -> PGError {
        PGError(kind: .connection, message: conn.map { lastMessage($0) } ?? "Out of memory")
    }

    static func lastMessage(_ conn: OpaquePointer) -> String {
        guard let cstr = PQerrorMessage(conn) else { return "Unknown error" }
        let msg = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? "Unknown error" : msg
    }

    /// Builds an error from a failed `PGresult` (falls back to the connection message).
    static func from(result: OpaquePointer?, conn: OpaquePointer) -> PGError {
        guard let result else { return PGError(kind: .query, message: lastMessage(conn)) }
        func field(_ code: Character) -> String? {
            guard let p = PQresultErrorField(result, Int32(code.asciiValue!)) else { return nil }
            return String(cString: p)
        }
        let primary = field("M") ?? lastMessage(conn)
        return PGError(
            kind: PQstatus(conn) == CONNECTION_OK ? .query : .connection,
            message: primary,
            sqlState: field("C"),
            severity: field("V") ?? field("S"),
            detail: field("D"),
            hint: field("H"),
            position: field("P").flatMap { Int($0) }
        )
    }
}
