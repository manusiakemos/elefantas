import AppKit
import ElefantasCore
import SwiftUI

struct ConnectionForm: View {
    @Binding var draft: ConnectionConfig
    @Binding var secrets: ConnectionSecrets
    @State private var mode: Mode = .standard

    enum Mode: String, CaseIterable, Identifiable {
        case standard, ssh
        var id: String { rawValue }
        var title: LocalizedStringKey { self == .standard ? "Standard" : "SSH" }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Connection type", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            .padding(.top, 16)

            Form {
                switch mode {
                case .standard: standardSection
                case .ssh: sshSection
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { mode = draft.ssh == nil ? .standard : .ssh }
        .onChange(of: draft.id) { _, _ in mode = draft.ssh == nil ? .standard : .ssh }
    }

    // MARK: - Standard

    @ViewBuilder private var standardSection: some View {
        Section {
            TextField("Name", text: $draft.name, prompt: Text(draft.displayName))
            Picker("Color", selection: $draft.color) {
                Text("None").tag(ConnectionColor?.none)
                ForEach(ConnectionColor.allCases) { color in
                    Label(color.rawValue.capitalized, systemImage: "circle.fill")
                        .foregroundStyle(color.swiftUIColor)
                        .tag(ConnectionColor?.some(color))
                }
            }
        }
        Section {
            TextField("Host", text: $draft.host, prompt: Text("127.0.0.1"))
                .textContentType(.URL)
            TextField("Port", value: $draft.port, format: .number.grouping(.never))
            TextField("User", text: $draft.user, prompt: Text("postgres"))
                .textContentType(.username)
            SecureField("Password", text: optionalBinding(\.password))
            TextField("Database", text: $draft.database, prompt: Text("postgres"))
        } footer: {
            if draft.ssh != nil {
                Text("Host and port are resolved from the SSH server (see the SSH tab).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("SSL") {
            Picker("SSL mode", selection: $draft.sslMode) {
                ForEach(SSLMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            if draft.sslMode == .verifyCA || draft.sslMode == .verifyFull {
                FilePathField(title: "Root certificate", path: Binding(
                    get: { draft.sslRootCert ?? "" },
                    set: { draft.sslRootCert = $0.isEmpty ? nil : $0 }))
            }
        }
    }

    // MARK: - SSH

    @ViewBuilder private var sshSection: some View {
        Section {
            Toggle("Connect through an SSH tunnel", isOn: Binding(
                get: { draft.ssh != nil },
                set: { draft.ssh = $0 ? (draft.ssh ?? SSHConfig()) : nil }))
        }
        if draft.ssh != nil {
            Section("SSH server") {
                TextField("SSH host", text: sshBinding(\.host), prompt: Text("bastion.example.com"))
                TextField("SSH port", value: sshBinding(\.port), format: .number.grouping(.never))
                TextField("SSH user", text: sshBinding(\.user), prompt: Text("from ~/.ssh/config"))
            }
            Section("Authentication") {
                Picker("Method", selection: sshBinding(\.auth)) {
                    Text("ssh-agent / default keys").tag(SSHAuthMethod.agent)
                    Text("Key file").tag(SSHAuthMethod.key)
                    Text("Password").tag(SSHAuthMethod.password)
                }
                switch draft.ssh?.auth ?? .agent {
                case .agent:
                    Text("Uses ssh-agent, your default keys and ~/.ssh/config.")
                        .font(.caption).foregroundStyle(.secondary)
                case .key:
                    FilePathField(title: "Key file", path: Binding(
                        get: { draft.ssh?.keyPath ?? "" },
                        set: { draft.ssh?.keyPath = $0.isEmpty ? nil : $0 }),
                        startDirectory: "~/.ssh")
                    SecureField("Passphrase", text: optionalBinding(\.sshSecret), prompt: Text("optional"))
                case .password:
                    SecureField("SSH password", text: optionalBinding(\.sshSecret))
                }
            }
            Section {
                Text("Database host “\(draft.host)” and port \(String(draft.port)) are reached from the SSH server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bindings

    private func optionalBinding(_ keyPath: WritableKeyPath<ConnectionSecrets, String?>) -> Binding<String> {
        Binding(get: { secrets[keyPath: keyPath] ?? "" },
                set: { secrets[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func sshBinding<T>(_ keyPath: WritableKeyPath<SSHConfig, T>) -> Binding<T> {
        Binding(get: { (draft.ssh ?? SSHConfig())[keyPath: keyPath] },
                set: {
                    var ssh = draft.ssh ?? SSHConfig()
                    ssh[keyPath: keyPath] = $0
                    draft.ssh = ssh
                })
    }
}

/// Text field + "Choose…" button that opens an NSOpenPanel.
struct FilePathField: View {
    let title: LocalizedStringKey
    @Binding var path: String
    var startDirectory: String?

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: $path).labelsHidden()
                Button("Choose…") { choose() }
            }
        }
    }

    @MainActor private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let startDirectory {
            panel.directoryURL = URL(fileURLWithPath: (startDirectory as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            path = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}
