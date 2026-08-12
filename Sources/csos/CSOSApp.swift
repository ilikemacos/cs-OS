import SwiftUI

@main
struct CSOSApp: App {
    @State private var store = SessionStore()

    var body: some Scene {
        Window("cs-OS", id: "main") {
            RootView(store: store)
        }
        // Standard macOS window furniture: real title bar, real traffic lights,
        // a unified toolbar the system styles for us. An earlier revision used
        // .hiddenTitleBar with a bespoke floating bar, which cost every native
        // affordance — window dragging, the proxy icon, toolbar vibrancy — and
        // still did not look like a Mac app.
        .windowToolbarStyle(.unified)
        .defaultSize(width: 960, height: 620)
        .commands {
            // Give the app the standard Mac tab commands users already know.
            CommandGroup(replacing: .newItem) {
                Button("New Session") { store.newSession() }
                    .keyboardShortcut("t", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Close Session") {
                    if let current = store.current { store.close(current) }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(store.current == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Select Next Session") { store.selectRelative(+1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Select Previous Session") { store.selectRelative(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }
        }
    }
}
