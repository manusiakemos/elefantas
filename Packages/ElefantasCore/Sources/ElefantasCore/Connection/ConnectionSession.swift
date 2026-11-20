import Foundation
import Observation
import PGKit

public struct ServerInfo: Sendable, Hashable {
    public var version: String
    public var versionNumber: Int
    public var sslInUse: Bool
    public var viaSSH: Bool
}

/// One live connection window: optional SSH tunnel + one PGConnection to the current database.
@MainActor
@Observable
public final class ConnectionSession {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case connected
        /// The connection dropped; `reconnect()` may recover it.
        case lost(String)
        case failed(String)
    }

    public let config: ConnectionConfig
    public private(set) var state: State = .idle
    public private(set) var connection: PGConnection?
    public private(set) var currentDatabase: String
    public private(set) var databases: [String] = []
    public private(set) var serverInfo: ServerInfo?

    private let secrets: ConnectionSecrets
    private var tunnel: SSHTunnel?
    private var acceptNewHostKey = false

    public init(config: ConnectionConfig, secrets: ConnectionSecrets) {
        self.config = config
        self.secrets = secrets
        self.currentDatabase = config.database
    }

    public var catalog: Catalog? { connection.map { Catalog(connection: $0) } }

    // MARK: - Lifecycle

    /// Connects. Throws `SSHTunnelError.unknownHostKey` so the UI can ask to trust the host
    /// and call `connect(trustingNewHostKey: true)`.
    public func connect(trustingNewHostKey: Bool = false) async throws {
        if trustingNewHostKey { acceptNewHostKey = true }
        state = .connecting
        do {
            try await open(database: currentDatabase)
            state = .connected
            databases = (try? await catalog?.databases()) ?? [currentDatabase]
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    public func disconnect() async {
        if let connection { await connection.close() }
        connection = nil
        tunnel?.stop()
        tunnel = nil
        state = .idle
    }

    public func reconnect() async throws {
        if let connection { await connection.close() }
        connection = nil
        if let tunnel, !tunnel.isRunning { self.tunnel = nil }
        try await connect()
    }

    /// Postgres cannot switch databases within a session, so this opens a new connection
    /// (reusing the tunnel) and closes the old one on success.
    public func switchDatabase(_ name: String) async throws {
        guard name != currentDatabase else { return }
        let old = connection
        try await open(database: name)
        currentDatabase = name
        if let old { await old.close() }
    }

    /// Call when an operation fails; marks the session lost if the socket is gone.
    public func noteFailure(_ error: Error) async {
        guard let pgError = error as? PGError, pgError.kind != .query, let connection else { return }
        if await !connection.isAlive() {
            state = .lost(pgError.message)
        }
    }

    // MARK: - Test connection

    /// Opens and closes a connection (and tunnel), returning server details.
    public static func test(_ config: ConnectionConfig, secrets: ConnectionSecrets,
                            trustingNewHostKey: Bool = false) async throws -> ServerInfo {
        let session = ConnectionSession(config: config, secrets: secrets)
        session.acceptNewHostKey = trustingNewHostKey
        do {
            try await session.open(database: config.database)
            let info = session.serverInfo
            await session.disconnect()
            guard let info else { throw PGError(kind: .connection, message: "No server info") }
            return info
        } catch {
            await session.disconnect()
            throw error
        }
    }

    // MARK: - Internals

    private func open(database: String) async throws {
        var host = config.host
        var port = config.port
        if let ssh = config.ssh {
            let tunnel: SSHTunnel
            if let existing = self.tunnel, existing.isRunning {
                tunnel = existing
            } else {
                tunnel = SSHTunnel(options: .init(ssh: ssh, remoteHost: config.host, remotePort: config.port,
                                                  secret: secrets.sshSecret, acceptNewHostKey: acceptNewHostKey))
                tunnel.onUnexpectedExit = { [weak self] message in
                    Task { @MainActor in self?.state = .lost(String(localized: "SSH tunnel closed: \(message)")) }
                }
                try await tunnel.start()
                self.tunnel = tunnel
            }
            host = "127.0.0.1"
            port = tunnel.localPort
        }

        let params = ConnectParams(host: host, port: port, database: database, user: config.user,
                                   password: secrets.password, sslMode: config.sslMode, sslRootCert: config.sslRootCert)
        let conn = try await PGConnection.connect(params)
        let versionSQL = PostgresDialect().serverVersion()
        let version = (try? await conn.execute(versionSQL.sql, versionSQL.params))?.rows.first?.first ?? nil
        connection = conn
        serverInfo = ServerInfo(version: version ?? String(conn.serverVersion), versionNumber: conn.serverVersion,
                                sslInUse: conn.sslInUse, viaSSH: config.ssh != nil)
    }
}
