import CLibPQ
import Foundation

public typealias Oid = UInt32

public struct PGColumn: Sendable, Hashable {
    public var name: String
    public var typeOID: Oid
    /// OID of the source table, or 0 if the column is not a plain table column.
    public var tableOID: Oid
    /// 1-based attribute number within `tableOID`, or 0.
    public var tableColumn: Int
}

/// One row in text format. `nil` is SQL NULL, distinct from an empty string.
public typealias PGRow = [String?]

/// A fully materialized result (use for small results; use `stream` for large ones).
public struct PGResult: Sendable {
    public var columns: [PGColumn]
    public var rows: [PGRow]
    public var commandTag: String
    /// Rows affected by INSERT/UPDATE/DELETE/etc., when reported.
    public var affectedRows: Int?

    public subscript(row: Int, column: String) -> String? {
        guard let idx = columns.firstIndex(where: { $0.name == column }) else { return nil }
        return rows[row][idx]
    }
}

/// A slice of rows delivered by `PGConnection.stream`.
public struct PGRowBatch: Sendable {
    public var columns: [PGColumn]
    public var rows: [PGRow]
    /// True for the last batch of the statement.
    public var isLast: Bool
}

enum ResultReader {
    static func columns(_ res: OpaquePointer) -> [PGColumn] {
        (0..<PQnfields(res)).map { i in
            PGColumn(
                name: PQfname(res, i).map { String(cString: $0) } ?? "?column?",
                typeOID: PQftype(res, i),
                tableOID: PQftable(res, i),
                tableColumn: Int(PQftablecol(res, i))
            )
        }
    }

    static func rows(_ res: OpaquePointer) -> [PGRow] {
        let nrows = PQntuples(res)
        let ncols = PQnfields(res)
        var rows: [PGRow] = []
        rows.reserveCapacity(Int(nrows))
        for r in 0..<nrows {
            var row: PGRow = []
            row.reserveCapacity(Int(ncols))
            for c in 0..<ncols {
                if PQgetisnull(res, r, c) == 1 {
                    row.append(nil)
                } else {
                    let len = Int(PQgetlength(res, r, c))
                    let ptr = UnsafeRawPointer(PQgetvalue(res, r, c)!).assumingMemoryBound(to: UInt8.self)
                    row.append(String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self))
                }
            }
            rows.append(row)
        }
        return rows
    }

    static func result(_ res: OpaquePointer) -> PGResult {
        let tag = PQcmdStatus(res).map { String(cString: $0) } ?? ""
        let affected = PQcmdTuples(res).flatMap { Int(String(cString: $0)) }
        return PGResult(columns: columns(res), rows: rows(res), commandTag: tag, affectedRows: affected)
    }
}
