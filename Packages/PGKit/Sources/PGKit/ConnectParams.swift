import Foundation

/// libpq `sslmode` values.
public enum SSLMode: String, Sendable, Codable, CaseIterable, Hashable {
    case disable
    case allow
    case prefer
    case require
    case verifyCA = "verify-ca"
    case verifyFull = "verify-full"
}

/// Parameters for opening a connection. Contains the password in memory only;
/// persistence of secrets is the caller's job (Keychain).
public struct ConnectParams: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var database: String
    public var user: String
    public var password: String?
    public var sslMode: SSLMode
    public var sslRootCert: String?
    public var connectTimeout: Int
    public var applicationName: String

    public init(
        host: String,
        port: Int = 5432,
        database: String,
        user: String,
        password: String? = nil,
        sslMode: SSLMode = .prefer,
        sslRootCert: String? = nil,
        connectTimeout: Int = 10,
        applicationName: String = "Elefantas"
    ) {
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.password = password
        self.sslMode = sslMode
        self.sslRootCert = sslRootCert
        self.connectTimeout = connectTimeout
        self.applicationName = applicationName
    }

    /// Keyword/value pairs for `PQconnectdbParams`. Empty optional values are omitted.
    public var keywordPairs: [(String, String)] {
        var pairs: [(String, String)] = [
            ("host", host),
            ("port", String(port)),
            ("dbname", database),
            ("user", user),
            ("sslmode", sslMode.rawValue),
            ("connect_timeout", String(connectTimeout)),
            ("application_name", applicationName),
            ("client_encoding", "UTF8"),
            ("keepalives", "1"),
            ("keepalives_idle", "30"),
            ("keepalives_interval", "10"),
            ("keepalives_count", "3"),
        ]
        if let password, !password.isEmpty { pairs.append(("password", password)) }
        if let sslRootCert, !sslRootCert.isEmpty { pairs.append(("sslrootcert", sslRootCert)) }
        return pairs
    }
}
