import Foundation
import Observation

/// Saved connections, persisted as JSON in Application Support. Secrets are not stored here.
@MainActor
@Observable
public final class FavoritesStore {
    public private(set) var favorites: [ConnectionConfig] = []
    public private(set) var lastError: String?

    private let fileURL: URL
    private let keychain: KeychainStore

    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Elefantas", directoryHint: .isDirectory)
            .appending(path: "favorites.json")
    }

    public init(fileURL: URL = FavoritesStore.defaultURL, keychain: KeychainStore = KeychainStore()) {
        self.fileURL = fileURL
        self.keychain = keychain
        load()
    }

    public func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            favorites = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            favorites = try JSONDecoder().decode(File.self, from: data).favorites
        } catch {
            lastError = String(localized: "Could not read saved connections: \(error.localizedDescription)")
        }
    }

    /// Inserts or replaces a favorite (matched by id) and stores its secrets.
    public func save(_ config: ConnectionConfig, secrets: ConnectionSecrets) throws {
        if let idx = favorites.firstIndex(where: { $0.id == config.id }) {
            favorites[idx] = config
        } else {
            favorites.append(config)
        }
        try keychain.setSecret(secrets.password, for: config.id, .databasePassword)
        try keychain.setSecret(config.ssh == nil ? nil : secrets.sshSecret, for: config.id, .sshSecret)
        try persist()
    }

    public func delete(_ id: UUID) throws {
        favorites.removeAll { $0.id == id }
        keychain.deleteAll(for: id)
        try persist()
    }

    public func duplicate(_ id: UUID) throws -> ConnectionConfig? {
        guard let original = favorites.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = String(localized: "\(original.displayName) copy")
        try save(copy, secrets: secrets(for: original.id))
        return copy
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        // Same semantics as SwiftUI's `move(fromOffsets:toOffset:)` (not available without SwiftUI).
        let moving = source.map { favorites[$0] }
        let insertAt = destination - source.count(in: 0..<destination)
        var remaining = favorites.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        remaining.insert(contentsOf: moving, at: insertAt)
        favorites = remaining
        try persist()
    }

    public func secrets(for id: UUID) -> ConnectionSecrets {
        ConnectionSecrets(password: keychain.secret(for: id, .databasePassword),
                          sshSecret: keychain.secret(for: id, .sshSecret))
    }

    private struct File: Codable {
        var version = 1
        var favorites: [ConnectionConfig]
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(favorites: favorites)).write(to: fileURL, options: .atomic)
        lastError = nil
    }
}
