import ElefantasCore
import SwiftUI

/// One window = one connection, like Sequel Ace: the connection screen until connected,
/// then the workspace.
struct RootView: View {
    @State private var workspace: Workspace?

    var body: some View {
        Group {
            if let workspace {
                WorkspaceView(workspace: workspace) {
                    Task {
                        await workspace.close()
                        self.workspace = nil
                    }
                }
            } else {
                ConnectionScreen { session in
                    workspace = Workspace(session: session)
                }
            }
        }
        .navigationTitle(workspace.map { "\($0.session.config.displayName) / \($0.session.currentDatabase)" } ?? "Elefantas")
    }
}
