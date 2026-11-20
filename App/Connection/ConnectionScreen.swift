import ElefantasCore
import SwiftUI

/// Favorites on the left, connection form on the right (Sequel Ace style).
struct ConnectionScreen: View {
    let onConnected: (ConnectionSession) -> Void

    @Environment(FavoritesStore.self) private var favorites
    @State private var selection: UUID?
    @State private var draft = ConnectionConfig()
    @State private var secrets = ConnectionSecrets()
    @State private var isBusy = false
    @State private var status: Status?
    @State private var pendingTrust: PendingTrust?

    enum Status: Equatable {
        case success(String)
        case failure(String)
    }

    struct PendingTrust: Identifiable {
        let host: String
        let isTest: Bool
        var id: String { host }
    }

    var body: some View {
        NavigationSplitView {
            FavoritesList(selection: $selection, onConnect: { id in
                select(id)
                Task { await connect() }
            })
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            ConnectionForm(draft: $draft, secrets: $secrets)
                .safeAreaInset(edge: .bottom) { actionBar }
                .disabled(isBusy)
        }
        .onChange(of: selection) { _, id in select(id) }
        .onChange(of: favorites.favorites.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { select(nil) }
        }
        .alert(item: $pendingTrust) { trust in
            Alert(
                title: Text("Unknown SSH host"),
                message: Text("The authenticity of “\(trust.host)” can’t be established. Trust this host and add its key to ~/.ssh/known_hosts?"),
                primaryButton: .default(Text("Trust and Continue")) {
                    Task { trust.isTest ? await test(trust: true) : await connect(trust: true) }
                },
                secondaryButton: .cancel())
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            statusView
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
            Button("Test") { Task { await test() } }
            Button(selection == nil ? "Add to Favorites" : "Save") { save() }
            Button("Connect") { Task { await connect() } }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .success(let text):
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(2)
        case .failure(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(3)
                .textSelection(.enabled)
        case nil:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func select(_ id: UUID?) {
        status = nil
        if let id, let config = favorites.favorites.first(where: { $0.id == id }) {
            draft = config
            secrets = favorites.secrets(for: id)
        } else {
            draft = ConnectionConfig()
            secrets = ConnectionSecrets()
        }
        if selection != id { selection = id }
    }

    private func save() {
        do {
            try favorites.save(draft, secrets: secrets)
            selection = draft.id
            status = .success(String(localized: "Saved."))
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func test(trust: Bool = false) async {
        if let error = draft.validationError { status = .failure(error); return }
        isBusy = true
        defer { isBusy = false }
        do {
            let info = try await ConnectionSession.test(draft, secrets: secrets, trustingNewHostKey: trust)
            var text = String(localized: "Connected to PostgreSQL \(info.version)")
            if info.sslInUse { text += String(localized: " · SSL") }
            if info.viaSSH { text += String(localized: " · SSH") }
            status = .success(text)
        } catch SSHTunnelError.unknownHostKey(let host) {
            pendingTrust = PendingTrust(host: host, isTest: true)
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func connect(trust: Bool = false) async {
        if let error = draft.validationError { status = .failure(error); return }
        isBusy = true
        defer { isBusy = false }
        let session = ConnectionSession(config: draft, secrets: secrets)
        do {
            try await session.connect(trustingNewHostKey: trust)
            onConnected(session)
        } catch SSHTunnelError.unknownHostKey(let host) {
            await session.disconnect()
            pendingTrust = PendingTrust(host: host, isTest: false)
        } catch {
            await session.disconnect()
            status = .failure(error.localizedDescription)
        }
    }
}

private struct FavoritesList: View {
    @Binding var selection: UUID?
    let onConnect: (UUID) -> Void
    @Environment(FavoritesStore.self) private var favorites
    @State private var errorMessage: String?

    var body: some View {
        List(selection: $selection) {
            Section("Favorites") {
                ForEach(favorites.favorites) { config in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(config.color?.swiftUIColor ?? .clear)
                            .overlay(Circle().strokeBorder(.secondary.opacity(config.color == nil ? 0.5 : 0)))
                            .frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(config.displayName).lineLimit(1)
                            Text("\(config.host):\(String(config.port))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(config.id)
                }
                .onMove { source, destination in
                    perform { try favorites.move(fromOffsets: source, toOffset: destination) }
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first {
                Button("Connect") { onConnect(id) }
                Button("Duplicate") { perform { selection = try favorites.duplicate(id)?.id } }
                Divider()
                Button("Delete", role: .destructive) { perform { try favorites.delete(id) } }
            }
        } primaryAction: { ids in
            if let id = ids.first { onConnect(id) }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { selection = nil } label: { Label("New Connection", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .help("Start a new connection")
                Spacer()
            }
            .padding(8)
        }
        .alert("Saved connections", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

extension ConnectionColor {
    var swiftUIColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}
