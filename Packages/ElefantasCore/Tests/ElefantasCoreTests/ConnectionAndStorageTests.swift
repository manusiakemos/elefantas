import XCTest
import PGKit
@testable import ElefantasCore

final class ConnectionConfigTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let config = ConnectionConfig(name: "Prod", color: .red, host: "db.internal", port: 6432, database: "app",
                                      user: "admin", sslMode: .verifyFull, sslRootCert: "~/ca.pem",
                                      ssh: SSHConfig(host: "bastion", port: 2222, user: "me", auth: .key, keyPath: "~/.ssh/id_ed25519"))
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
    }

    func testDisplayNameAndValidation() {
        var c = ConnectionConfig(host: "db", user: "me")
        XCTAssertEqual(c.displayName, "me@db")
        XCTAssertNil(c.validationError)
        c.ssh = SSHConfig(host: "jump")
        XCTAssertEqual(c.displayName, "me@db via jump")
        c.ssh?.host = "-oProxyCommand=evil"
        XCTAssertNotNil(c.validationError)
        c.ssh = SSHConfig(host: "jump", auth: .key)
        XCTAssertNotNil(c.validationError, "key auth needs a key file")
        c.user = ""
        XCTAssertNotNil(c.validationError)
    }
}

final class SSHTunnelTests: XCTestCase {
    func testAgentArguments() {
        let o = SSHTunnel.Options(ssh: SSHConfig(host: "bastion", port: 2222, user: "me"), remoteHost: "10.0.0.5", remotePort: 5432)
        let args = SSHTunnel.arguments(for: o, localPort: 40000)
        XCTAssertEqual(Array(args.prefix(4)), ["-N", "-T", "-L", "127.0.0.1:40000:10.0.0.5:5432"])
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertEqual(Array(args.suffix(4)), ["-l", "me", "--", "bastion"])
    }

    func testPasswordAndKeyArguments() {
        var o = SSHTunnel.Options(ssh: SSHConfig(host: "h", auth: .password), remoteHost: "::1", remotePort: 5432,
                                  secret: "pw", acceptNewHostKey: true)
        var args = SSHTunnel.arguments(for: o, localPort: 1)
        XCTAssertTrue(args.contains("127.0.0.1:1:[::1]:5432"))
        XCTAssertTrue(args.contains("PubkeyAuthentication=no"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertFalse(args.contains("BatchMode=yes"))
        XCTAssertTrue(o.usesAskpass)

        o = SSHTunnel.Options(ssh: SSHConfig(host: "h", auth: .key, keyPath: "/k"), remoteHost: "db", remotePort: 5432)
        args = SSHTunnel.arguments(for: o, localPort: 1)
        XCTAssertTrue(args.contains("/k"))
        XCTAssertTrue(args.contains("IdentitiesOnly=yes"))
        XCTAssertTrue(args.contains("BatchMode=yes"), "no passphrase: never prompt")
        XCTAssertFalse(args.contains("-l"))
    }

    func testClassifyErrors() {
        XCTAssertEqual(SSHTunnel.classify(stderr: "No ED25519 host key is known for h and you have requested strict checking.\nHost key verification failed.", host: "h"),
                       .unknownHostKey("h"))
        XCTAssertEqual(SSHTunnel.classify(stderr: "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@", host: "h"),
                       .hostKeyChanged("h"))
        XCTAssertEqual(SSHTunnel.classify(stderr: "me@h: Permission denied (publickey).", host: "h"),
                       .authenticationFailed("me@h: Permission denied (publickey)."))
        if case .failed = SSHTunnel.classify(stderr: "ssh: Could not resolve hostname x", host: "x") {} else { XCTFail() }
    }

    func testFreeLocalPort() throws {
        let port = try SSHTunnel.freeLocalPort()
        XCTAssertGreaterThan(port, 1024)
        XCTAssertFalse(SSHTunnel.canConnect(port: port))
    }
}

@MainActor
final class FavoritesStoreTests: XCTestCase {
    func testSaveLoadDeleteWithKeychain() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "elefantas-test-\(UUID().uuidString).json")
        let keychain = KeychainStore(service: "id.elefantas.tests")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FavoritesStore(fileURL: url, keychain: keychain)
        XCTAssertTrue(store.favorites.isEmpty)
        let config = ConnectionConfig(name: "Local", user: "me")
        try store.save(config, secrets: ConnectionSecrets(password: "pw"))
        XCTAssertEqual(store.secrets(for: config.id).password, "pw")

        let reloaded = FavoritesStore(fileURL: url, keychain: keychain)
        XCTAssertEqual(reloaded.favorites, [config])
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains("pw\""), "secrets must not be written to the JSON file")

        let copy = try XCTUnwrap(try reloaded.duplicate(config.id))
        XCTAssertEqual(reloaded.secrets(for: copy.id).password, "pw")

        try reloaded.delete(config.id)
        try reloaded.delete(copy.id)
        XCTAssertTrue(reloaded.favorites.isEmpty)
        XCTAssertNil(keychain.secret(for: config.id, .databasePassword))
        XCTAssertNil(keychain.secret(for: copy.id, .databasePassword))
    }
}

final class FuzzyMatchTests: XCTestCase {
    func testSubsequenceMatching() {
        XCTAssertTrue(FuzzyMatch.matches("usr", "app_users"))
        XCTAssertTrue(FuzzyMatch.matches("EVT", "events"))
        XCTAssertTrue(FuzzyMatch.matches("", "anything"))
        XCTAssertFalse(FuzzyMatch.matches("xyz", "users"))
        XCTAssertFalse(FuzzyMatch.matches("sru", "users"), "order matters")
    }
}
