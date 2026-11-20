import CLibPQ
import Foundation

/// A single libpq connection.
///
/// All blocking libpq calls run on a private serial queue, so calls are naturally ordered
/// and never block the caller's thread. `cancel()` is the only call that may run concurrently
/// with a running statement; it opens a separate cancel connection.
public final class PGConnection: @unchecked Sendable {
    // `conn` is only touched on `queue`, except in `cancel()` (guarded by `stateLock`) and deinit.
    private let conn: OpaquePointer
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var closed = false

    /// Server version as an integer, e.g. 180001 for 18.1.
    public let serverVersion: Int
    public let sslInUse: Bool
    public let backendPID: Int32
    public let params: ConnectParams

    private init(conn: OpaquePointer, params: ConnectParams) {
        self.conn = conn
        self.params = params
        self.queue = DispatchQueue(label: "elefantas.pg.\(params.host):\(params.port)", qos: .userInitiated)
        self.serverVersion = Int(PQserverVersion(conn))
        self.sslInUse = PQsslInUse(conn) == 1
        self.backendPID = PQbackendPID(conn)
    }

    deinit {
        if !closed { PQfinish(conn) }
    }

    // MARK: - Connect / close

    public static func connect(_ params: ConnectParams) async throws -> PGConnection {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let pairs = params.keywordPairs
                let raw = withCStringArray(pairs.map(\.0)) { keys in
                    withCStringArray(pairs.map(\.1)) { values in
                        PQconnectdbParams(keys, values, 0)
                    }
                }
                guard let raw else {
                    cont.resume(throwing: PGError.connection(nil))
                    return
                }
                guard PQstatus(raw) == CONNECTION_OK else {
                    let error = PGError.connection(raw)
                    PQfinish(raw)
                    cont.resume(throwing: error)
                    return
                }
                cont.resume(returning: PGConnection(conn: raw, params: params))
            }
        }
    }

    /// Closes the connection after any queued work finishes. Idempotent.
    public func close() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                stateLock.withLock {
                    if !closed {
                        closed = true
                        PQfinish(conn)
                    }
                }
                cont.resume()
            }
        }
    }

    public var isClosed: Bool { stateLock.withLock { closed } }

    /// True if the socket is still usable. Waits for queued work.
    public func isAlive() async -> Bool {
        (try? await run { conn in PQstatus(conn) == CONNECTION_OK }) ?? false
    }

    /// Re-establishes a broken connection with the same parameters.
    public func reset() async throws {
        try await run { conn in
            PQreset(conn)
            guard PQstatus(conn) == CONNECTION_OK else { throw PGError.connection(conn) }
        }
    }

    // MARK: - Queries

    /// Runs one statement and materializes the whole result. Use for small results.
    @discardableResult
    public func execute(_ sql: String, _ params: [String?] = []) async throws -> PGResult {
        try await run { conn in try Self.execSync(conn, sql, params) }
    }

    /// Runs `body` on the connection queue with exclusive access, inside BEGIN/COMMIT.
    /// Rolls back if `body` throws. No other statement can interleave.
    public func transaction<T: Sendable>(_ body: @escaping @Sendable (PGSession) throws -> T) async throws -> T {
        try await run { conn in
            let session = PGSession(conn: conn)
            try session.execute("BEGIN")
            do {
                let value = try body(session)
                try session.execute("COMMIT")
                return value
            } catch {
                _ = try? session.execute("ROLLBACK")
                throw error
            }
        }
    }

    /// Streams a single statement's rows in batches of `chunkSize` (libpq chunked rows mode),
    /// so memory stays bounded by the batch size. Cancelling the consuming task cancels the query.
    public func stream(_ sql: String, _ params: [String?] = [], chunkSize: Int = 500) -> AsyncThrowingStream<PGRowBatch, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.cancel() }
            }
            queue.async { [self] in
                guard !isClosed else {
                    continuation.finish(throwing: PGError.closed)
                    return
                }
                let sent = withParams(params) { count, values in
                    PQsendQueryParams(conn, sql, count, nil, values, nil, nil, 0)
                }
                guard sent == 1 else {
                    continuation.finish(throwing: PGError(kind: .query, message: PGError.lastMessage(conn)))
                    return
                }
                PQsetChunkedRowsMode(conn, Int32(max(1, chunkSize)))

                var failure: PGError?
                var columns: [PGColumn]?
                // Must drain every result until NULL, even after an error.
                while let res = PQgetResult(conn) {
                    defer { PQclear(res) }
                    switch PQresultStatus(res) {
                    case PGRES_TUPLES_CHUNK, PGRES_SINGLE_TUPLE:
                        guard failure == nil else { continue }
                        let cols = columns ?? ResultReader.columns(res)
                        columns = cols
                        continuation.yield(PGRowBatch(columns: cols, rows: ResultReader.rows(res), isLast: false))
                    case PGRES_TUPLES_OK, PGRES_COMMAND_OK, PGRES_EMPTY_QUERY:
                        guard failure == nil else { continue }
                        let cols = columns ?? ResultReader.columns(res)
                        continuation.yield(PGRowBatch(columns: cols, rows: ResultReader.rows(res), isLast: true))
                    default:
                        if failure == nil { failure = PGError.from(result: res, conn: conn) }
                    }
                }
                if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    /// Requests cancellation of the statement currently running on this connection.
    /// Safe to call from any thread; a no-op if nothing is running.
    public func cancel() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed, let cancelConn = PQcancelCreate(conn) else { return }
        defer { PQcancelFinish(cancelConn) }
        _ = PQcancelBlocking(cancelConn)
    }

    // MARK: - Internals

    private func run<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                guard !isClosed else {
                    cont.resume(throwing: PGError.closed)
                    return
                }
                cont.resume(with: Result { try body(conn) })
            }
        }
    }

    static func execSync(_ conn: OpaquePointer, _ sql: String, _ params: [String?]) throws -> PGResult {
        let res = withParams(params) { count, values in
            PQexecParams(conn, sql, count, nil, values, nil, nil, 0)
        }
        defer { PQclear(res) }
        guard let res else { throw PGError(kind: .query, message: PGError.lastMessage(conn)) }
        switch PQresultStatus(res) {
        case PGRES_COMMAND_OK, PGRES_TUPLES_OK, PGRES_EMPTY_QUERY:
            return ResultReader.result(res)
        default:
            throw PGError.from(result: res, conn: conn)
        }
    }
}

/// Synchronous access to a connection, valid only inside `PGConnection.transaction`.
public struct PGSession: @unchecked Sendable {
    fileprivate let conn: OpaquePointer

    @discardableResult
    public func execute(_ sql: String, _ params: [String?] = []) throws -> PGResult {
        try PGConnection.execSync(conn, sql, params)
    }
}

// MARK: - C string helpers

/// Calls `body` with a NULL-terminated array of C strings.
func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    let pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { buffer in
        buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { body($0) }
    }
}

/// Calls `body` with (count, values) for text-format query parameters; nil means SQL NULL.
func withParams<R>(_ params: [String?], _ body: (Int32, UnsafePointer<UnsafePointer<CChar>?>?) -> R) -> R {
    if params.isEmpty { return body(0, nil) }
    let pointers: [UnsafeMutablePointer<CChar>?] = params.map { $0.map { strdup($0) } ?? nil }
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { buffer in
        buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
            body(Int32(params.count), $0)
        }
    }
}
