import SwiftUI

@main
struct CSOSApp: App {
    @State private var store = SessionStore()

    var body: some Scene {
        Window("cs-OS", id: "main") {
            RootView(store: store)
        }
        // Liquid Glass wants the content to run under the titlebar so the
        // chrome and the window controls share one continuous glass surface.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 960, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { store.newSession() }
                    .keyboardShortcut("t", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Close Session") {
                    if let current = store.current { store.close(current) }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
        }
    }
}
