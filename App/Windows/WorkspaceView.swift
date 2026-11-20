import ElefantasCore
import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    let onDisconnect: () -> Void

    var body: some View {
        NavigationSplitView {
            ExplorerSidebar(explorer: workspace.explorer, selection: $workspace.selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 400)
        } detail: {
            VStack(spacing: 0) {
                connectionBanner
                detail
            }
        }
        .toolbar { toolbar }
        .alert("Error", isPresented: Binding(
            get: { workspace.alertMessage != nil },
            set: { if !$0 { workspace.alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspace.alertMessage ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        switch workspace.tab {
        case .content:
            if let relation = workspace.selectedRelation {
                ContentTabView(controller: workspace.content, relation: relation)
                    .id(ObjectIdentifier(workspace.content))
            } else if let function = workspace.selectedFunction {
                PlaceholderView(systemImage: "function", title: function.signature,
                                message: "Function details arrive with the Structure tab in Phase 2.")
            } else {
                PlaceholderView(systemImage: "sidebar.left", title: "Select a table",
                                message: "Choose a table or view in the sidebar to browse its rows.")
            }
        case .structure:
            PlaceholderView(systemImage: WorkspaceTab.structure.systemImage, title: "Structure",
                            message: "Columns, indexes, constraints and DDL arrive in Phase 2.")
        case .query:
            PlaceholderView(systemImage: WorkspaceTab.query.systemImage, title: "Query",
                            message: "The SQL editor arrives in Phase 2.")
        }
    }

    @ViewBuilder private var connectionBanner: some View {
        if case .lost(let reason) = workspace.session.state {
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(.orange)
                Text("Connection lost: \(reason)").lineLimit(2)
                Spacer()
                Button("Reconnect") { Task { await workspace.reconnect() } }
            }
            .padding(10)
            .background(.orange.opacity(0.12))
            Divider()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Database", selection: Binding(
                get: { workspace.session.currentDatabase },
                set: { name in Task { await workspace.switchDatabase(name) } })
            ) {
                ForEach(workspace.session.databases, id: \.self) { Text($0).tag($0) }
            }
            .help("Choose database")
            .frame(minWidth: 140)
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $workspace.tab) {
                ForEach(WorkspaceTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleOnly)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await workspace.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh (⌘R)")

            ServerStatusBadge(session: workspace.session)

            Button(action: onDisconnect) {
                Label("Disconnect", systemImage: "eject")
            }
            .help("Disconnect")
        }
    }
}

private struct ServerStatusBadge: View {
    let session: ConnectionSession

    var body: some View {
        let info = session.serverInfo
        Label {
            Text(info.map { "PG \($0.version)" } ?? "")
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .help(helpText)
    }

    private var icon: String {
        switch session.state {
        case .connected: session.serverInfo?.sslInUse == true ? "lock.fill" : "circle.fill"
        case .lost, .failed: "exclamationmark.triangle.fill"
        default: "circle.dotted"
        }
    }

    private var color: Color {
        switch session.state {
        case .connected: .green
        case .lost, .failed: .orange
        default: .secondary
        }
    }

    private var helpText: String {
        guard let info = session.serverInfo else { return "" }
        var parts = ["PostgreSQL \(info.version)"]
        parts.append(info.sslInUse ? String(localized: "SSL") : String(localized: "No SSL"))
        if info.viaSSH { parts.append(String(localized: "SSH tunnel")) }
        return parts.joined(separator: " · ")
    }
}

struct PlaceholderView: View {
    let systemImage: String
    let title: String
    let message: LocalizedStringKey

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
