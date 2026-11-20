import Foundation
import Security

/// Generic-password storage in the macOS Keychain.
public struct KeychainStore: Sendable {
    public enum Kind: String, Sendable {
        case databasePassword = "db"
        case sshSecret = "ssh"
    }

    public struct Failure: Error, LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    public let service: String

    public init(service: String = "id.elefantas.app") {
        self.service = service
    }

    public static func account(_ id: UUID, _ kind: Kind) -> String {
        "\(id.uuidString).\(kind.rawValue)"
    }

    public func secret(for id: UUID, _ kind: Kind) -> String? {
        get(account: Self.account(id, kind))
    }

    /// Stores `secret`, or deletes the item when it is nil or empty.
    public func setSecret(_ secret: String?, for id: UUID, _ kind: Kind) throws {
        try set(secret, account: Self.account(id, kind))
    }

    public func deleteAll(for id: UUID) {
        for kind in [Kind.databasePassword, .sshSecret] { try? set(nil, account: Self.account(id, kind)) }
    }

    // MARK: - Raw access

    public func get(account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ secret: String?, account: String) throws {
        let query = baseQuery(account)
        guard let secret, !secret.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
            return
        }
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "Elefantas"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure(status: addStatus) }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
