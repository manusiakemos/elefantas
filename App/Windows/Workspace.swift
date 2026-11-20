import ElefantasCore
import Observation
import SwiftUI

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case structure, content, query
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .structure: "Structure"
        case .content: "Content"
        case .query: "Query"
        }
    }

    var systemImage: String {
        switch self {
        case .structure: "tablecells.badge.ellipsis"
        case .content: "tablecells"
        case .query: "terminal"
        }
    }
}

enum SidebarItem: Hashable {
    case relation(RelationRef)
    case function(UInt32)
}

/// Per-window state once connected: session, explorer, and the Content controller.
@MainActor
@Observable
final class Workspace {
    let session: ConnectionSession
    private(set) var explorer: ExplorerModel
    private(set) var content: ContentController
    var tab: WorkspaceTab = .content
    var selection: SidebarItem? {
        didSet { selectionChanged() }
    }
    var alertMessage: String?

    init(session: ConnectionSession) {
        self.session = session
        let connection = session.connection!
        self.explorer = ExplorerModel(connection: connection)
        self.content = ContentController(connection: connection)
        wireErrors()
        Task { await explorer.reload() }
    }

    var selectedRelation: RelationInfo? {
        guard case .relation(let ref) = selection else { return nil }
        return explorer.relation(ref)
    }

    var selectedFunction: FunctionInfo? {
        guard case .function(let oid) = selection else { return nil }
        return explorer.contents.values.lazy.flatMap(\.functions).first { $0.oid == oid }
    }

    func switchDatabase(_ name: String) async {
        do {
            content.cancelAll()
            try await session.switchDatabase(name)
            rebuildForCurrentConnection()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func reconnect() async {
        do {
            try await session.reconnect()
            rebuildForCurrentConnection()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func refresh() async {
        await explorer.reload()
        if content.relation != nil { content.reloadPage() }
    }

    func close() async {
        content.cancelAll()
        await session.disconnect()
    }

    private func rebuildForCurrentConnection() {
        guard let connection = session.connection else { return }
        let previous = selection
        explorer = ExplorerModel(connection: connection)
        content = ContentController(connection: connection)
        wireErrors()
        selection = nil
        Task {
            await explorer.reload()
            // Keep the selection when the same relation exists (e.g. after a reconnect).
            if case .relation(let ref) = previous, explorer.relation(ref) != nil { selection = previous }
        }
    }

    private func wireErrors() {
        content.onError = { [weak self] error in
            guard let self else { return }
            Task { await self.session.noteFailure(error) }
        }
    }

    private func selectionChanged() {
        guard let relation = selectedRelation else { return }
        if content.relation?.ref != relation.ref {
            Task { await content.load(relation) }
        }
    }
}
