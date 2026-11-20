import AppKit
import ElefantasCore
import SwiftUI

@main
struct ElefantasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var favorites = FavoritesStore()

    var body: some Scene {
        WindowGroup(id: "connection") {
            RootView()
                .environment(favorites)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            AppCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        SSHTunnel.terminateAll()
    }
}

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { openTab() }
                .keyboardShortcut("t", modifiers: .command)
        }
    }

    /// Opens a new connection window and merges it into the current window as a tab.
    @MainActor
    private func openTab() {
        let current = NSApp.keyWindow
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        openWindow(id: "connection")
        DispatchQueue.main.async {
            guard let current,
                  let created = NSApp.windows.first(where: { !before.contains(ObjectIdentifier($0)) && $0.isVisible })
            else { return }
            current.addTabbedWindow(created, ordered: .above)
            created.makeKeyAndOrderFront(nil)
        }
    }
}
