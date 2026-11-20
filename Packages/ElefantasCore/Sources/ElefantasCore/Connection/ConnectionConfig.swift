import Foundation
import PGKit

public enum ConnectionColor: String, Codable, Sendable, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, gray
    public var id: String { rawValue }
}

public enum SSHAuthMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    /// ssh-agent and default keys / ~/.ssh/config.
    case agent
    /// A specific private key file, optionally with a passphrase.
    case key
    case password
    public var id: String { rawValue }
}

public struct SSHConfig: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var user: String
    public var auth: SSHAuthMethod
    public var keyPath: String?

    public init(host: String = "", port: Int = 22, user: String = "", auth: SSHAuthMethod = .agent, keyPath: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
        self.keyPath = keyPath
    }
}

/// A saved or ad-hoc connection. Contains no secrets; those live in the Keychain.
public struct ConnectionConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var color: ConnectionColor?
    public var host: String
    public var port: Int
    public var database: String
    public var user: String
    public var sslMode: SSLMode
    public var sslRootCert: String?
    /// When set, the connection goes through an SSH tunnel and `host`/`port` are
    /// resolved from the SSH server's point of view.
    public var ssh: SSHConfig?

    public init(id: UUID = UUID(), name: String = "", color: ConnectionColor? = nil,
                host: String = "127.0.0.1", port: Int = 5432, database: String = "postgres",
                user: String = "", sslMode: SSLMode = .prefer, sslRootCert: String? = nil, ssh: SSHConfig? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.sslMode = sslMode
        self.sslRootCert = sslRootCert
        self.ssh = ssh
    }

    public var displayName: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        let target = user.isEmpty ? host : "\(user)@\(host)"
        return ssh.map { "\(target) via \($0.host)" } ?? target
    }

    /// Basic validation before attempting to connect. Returns a user-facing message or nil.
    public var validationError: String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Host is required.") }
        if !(1...65535).contains(port) { return String(localized: "Port must be between 1 and 65535.") }
        if user.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "User is required.") }
        if let ssh {
            if ssh.host.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "SSH host is required.") }
            if ssh.host.hasPrefix("-") || host.hasPrefix("-") { return String(localized: "Host names cannot start with “-”.") }
            if !(1...65535).contains(ssh.port) { return String(localized: "SSH port must be between 1 and 65535.") }
            if ssh.auth == .key && (ssh.keyPath ?? "").isEmpty { return String(localized: "Choose an SSH key file.") }
        }
        return nil
    }
}

/// Secrets supplied at connect time (from the Keychain or the connection form).
public struct ConnectionSecrets: Sendable, Hashable {
    public var password: String?
    /// SSH password or key passphrase, depending on `SSHConfig.auth`.
    public var sshSecret: String?

    public init(password: String? = nil, sshSecret: String? = nil) {
        self.password = password
        self.sshSecret = sshSecret
    }
}
