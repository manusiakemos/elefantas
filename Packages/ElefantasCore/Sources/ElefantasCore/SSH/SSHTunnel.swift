import Darwin
import Foundation

public enum SSHTunnelError: Error, LocalizedError, Equatable {
    /// The server's host key is not in known_hosts. Retry with `acceptNewHostKey` after the user agrees.
    case unknownHostKey(String)
    /// The host key differs from known_hosts. Never auto-accepted.
    case hostKeyChanged(String)
    case authenticationFailed(String)
    case failed(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .unknownHostKey(let host):
            String(localized: "The SSH host “\(host)” is not known. Trust it and add it to known_hosts?")
        case .hostKeyChanged(let host):
            String(localized: "The SSH host key for “\(host)” has CHANGED. This could be an attack. Fix ~/.ssh/known_hosts manually if the change is expected.")
        case .authenticationFailed(let detail):
            String(localized: "SSH authentication failed. \(detail)")
        case .failed(let detail):
            String(localized: "SSH tunnel failed: \(detail)")
        case .timeout:
            String(localized: "Timed out while opening the SSH tunnel.")
        }
    }
}

/// A local port forward through the system `/usr/bin/ssh`.
/// Respects ~/.ssh/config and ssh-agent. Passwords and passphrases go through SSH_ASKPASS.
public final class SSHTunnel: @unchecked Sendable {
    public struct Options: Sendable, Hashable {
        public var ssh: SSHConfig
        /// Database host and port as seen from the SSH server.
        public var remoteHost: String
        public var remotePort: Int
        public var secret: String?
        public var acceptNewHostKey: Bool
        public var connectTimeout: Int

        public init(ssh: SSHConfig, remoteHost: String, remotePort: Int, secret: String? = nil,
                    acceptNewHostKey: Bool = false, connectTimeout: Int = 15) {
            self.ssh = ssh
            self.remoteHost = remoteHost
            self.remotePort = remotePort
            self.secret = secret
            self.acceptNewHostKey = acceptNewHostKey
            self.connectTimeout = connectTimeout
        }

        var usesAskpass: Bool {
            guard let secret, !secret.isEmpty else { return false }
            return ssh.auth == .password || ssh.auth == .key
        }
    }

    public let options: Options
    public private(set) var localPort: Int = 0
    /// Called once if ssh exits on its own after the tunnel was up (e.g. network loss).
    public var onUnexpectedExit: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var stderrBuffer = Data()
    private var stopping = false

    public init(options: Options) {
        self.options = options
    }

    deinit {
        process?.terminate()
    }

    // ssh children are not killed when the app exits, so running tunnels are tracked here.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [ObjectIdentifier: Process] = [:]

    /// Terminates every running tunnel. Call from `applicationWillTerminate`.
    public static func terminateAll() {
        let processes = registryLock.withLock { () -> [Process] in
            defer { registry.removeAll() }
            return Array(registry.values)
        }
        processes.filter(\.isRunning).forEach { $0.terminate() }
    }

    private func register(_ process: Process?) {
        Self.registryLock.withLock { Self.registry[ObjectIdentifier(self)] = process }
    }

    // MARK: - Arguments (pure, unit-tested)

    public static func arguments(for options: Options, localPort: Int) -> [String] {
        let ssh = options.ssh
        let remoteHost = options.remoteHost.contains(":") ? "[\(options.remoteHost)]" : options.remoteHost
        var args = [
            "-N", "-T",
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(options.remotePort)",
            "-p", String(ssh.port),
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=\(options.connectTimeout)",
            "-o", "StrictHostKeyChecking=\(options.acceptNewHostKey ? "accept-new" : "yes")",
        ]
        switch ssh.auth {
        case .agent:
            args += ["-o", "BatchMode=yes"]
        case .key:
            if let keyPath = ssh.keyPath, !keyPath.isEmpty {
                args += ["-i", (keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
            }
            if !options.usesAskpass { args += ["-o", "BatchMode=yes"] }
        case .password:
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive",
                     "-o", "PubkeyAuthentication=no",
                     "-o", "NumberOfPasswordPrompts=1"]
        }
        if !ssh.user.isEmpty { args += ["-l", ssh.user] }
        args += ["--", ssh.host]
        return args
    }

    /// Maps ssh's stderr to a typed error.
    static func classify(stderr: String, host: String) -> SSHTunnelError {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") { return .hostKeyChanged(host) }
        if text.contains("Host key verification failed") || text.range(of: "No .* host key is known", options: .regularExpression) != nil {
            return .unknownHostKey(host)
        }
        if text.contains("Permission denied") || text.contains("Too many authentication failures") {
            return .authenticationFailed(lastLine(text))
        }
        return .failed(text.isEmpty ? String(localized: "ssh exited without output.") : lastLine(text))
    }

    private static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
    }

    // MARK: - Lifecycle

    /// Starts ssh and waits until the local port accepts connections.
    public func start(timeout: Duration = .seconds(30)) async throws {
        let port = try Self.freeLocalPort()
        localPort = port

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.arguments(for: options, localPort: port)
        var env = ProcessInfo.processInfo.environment
        if options.usesAskpass {
            env["SSH_ASKPASS"] = try Self.askpassHelper().path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? "elefantas:0"
            env["ELEFANTAS_SSH_SECRET"] = options.secret
        }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.withLock {
                self.stderrBuffer.append(data)
                if self.stderrBuffer.count > 16_384 { self.stderrBuffer.removeFirst(self.stderrBuffer.count - 16_384) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            errPipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.register(nil)
            let (wasStopping, message) = self.lock.withLock { (self.stopping, self.stderrText) }
            if !wasStopping { self.onUnexpectedExit?(message) }
        }

        lock.withLock { self.process = process; self.stopping = false }
        try process.run()
        register(process)

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !process.isRunning {
                // Give the readability handler a moment to drain stderr.
                try? await Task.sleep(for: .milliseconds(100))
                lock.withLock { stopping = true }
                throw Self.classify(stderr: lock.withLock { stderrText }, host: options.ssh.host)
            }
            if Self.canConnect(port: port) { return }
            if Task.isCancelled { stop(); throw CancellationError() }
            try? await Task.sleep(for: .milliseconds(100))
        }
        stop()
        throw SSHTunnelError.timeout
    }

    public func stop() {
        let p = lock.withLock { () -> Process? in
            stopping = true
            return process
        }
        if let p, p.isRunning { p.terminate() }
    }

    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    private var stderrText: String { String(decoding: stderrBuffer, as: UTF8.self) }

    // MARK: - Helpers

    /// Writes (once) a tiny askpass script that echoes the secret from the environment,
    /// so the secret is never written to disk.
    static func askpassHelper() throws -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Elefantas", directoryHint: .isDirectory)
        let url = dir.appending(path: "ssh-askpass.sh")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$ELEFANTAS_SSH_SECRET\"\n"
        let fm = FileManager.default
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Asks the kernel for a free port on 127.0.0.1.
    static func freeLocalPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHTunnelError.failed("socket() failed") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { throw SSHTunnelError.failed("Could not find a free local port.") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
