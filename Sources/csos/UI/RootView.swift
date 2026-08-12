import AppKit
import SwiftUI

/// The window: a source-list sidebar of sessions beside the active terminal.
///
/// The split view is doing real work here, not decoration. A terminal that
/// fills the entire window with black is a console; a Mac app puts the console
/// *inside* an app — a sidebar to move between sessions, a toolbar, and native
/// views for every state that isn't "a shell is running".
struct RootView: View {
    @Bindable var store: SessionStore

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 420)
        .toolbar { toolbarContent }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $store.selected) {
            Section("Sessions") {
                ForEach(store.sessions) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            Button("Close Session") { store.close(session) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            // Mirrors the "+" affordance at the foot of Mail's and Finder's
            // source lists, which is where Mac users look for it.
            Button {
                store.newSession()
            } label: {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let session = store.current {
            SessionDetail(session: session, store: store)
                .navigationTitle(session.title)
                .navigationSubtitle(subtitle(for: session))
        } else {
            ContentUnavailableView(
                "No Session",
                systemImage: "terminal",
                description: Text("Press ⌘T to start a Linux session."))
        }
    }

    private func subtitle(for session: Session) -> String {
        switch session.state {
        case .running: return session.workingDirectory ?? session.image
        case .booting: return "Starting…"
        case .idle:    return "Not started"
        case .exited:  return "Exited"
        case .failed:  return "Failed to start"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if BackendFactory.supportsImageSelection {
                Menu {
                    ForEach(SessionStore.presets, id: \.self) { image in
                        Button(image.split(separator: "/").last.map(String.init) ?? image) {
                            store.newSession(image: image)
                        }
                    }
                } label: {
                    Label("New Session", systemImage: "plus")
                } primaryAction: {
                    store.newSession()
                }
                .help("New session (⌘T)")
            } else {
                Button { store.newSession() } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("New session (⌘T)")
            }
        }
    }
}

// MARK: - Sidebar row

private struct SessionRow: View {
    @Bindable var session: Session

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .lineLimit(1)
                if let dir = session.workingDirectory, session.state == .running {
                    Text(dir)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint)
        }
    }

    private var icon: String {
        switch session.state {
        case .running: return "terminal.fill"
        case .booting: return "hourglass"
        case .failed:  return "exclamationmark.triangle.fill"
        case .exited:  return "terminal"
        case .idle:    return "terminal"
        }
    }

    private var tint: Color {
        switch session.state {
        case .running: return Theme.statusRunning
        case .booting: return Theme.statusBooting
        case .failed:  return Theme.statusFailed
        case .idle, .exited: return Theme.mutedColor
        }
    }
}

// MARK: - Detail body

/// Switches on session state so a failure is a *view*, not a red line printed
/// into an otherwise empty console.
private struct SessionDetail: View {
    @Bindable var session: Session
    let store: SessionStore

    var body: some View {
        ZStack {
            WindowBackdrop().ignoresSafeArea()

            content
        }
        // TerminalPane used to start the session as a side effect of being
        // created. It is no longer built until the guest is running, so the
        // start has to be driven from here — otherwise an idle session sits on
        // the spinner forever.
        .task(id: session.id) {
            try? await session.startIfNeeded()
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch session.state {
            case .idle, .booting:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Starting Linux…")
                        .font(.headline)
                    Text("First boot takes about a second.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

            case .failed(let message):
                failure(message)

            case .running, .exited:
                TerminalPane(session: session)
                    // Inset with a rounded edge so the terminal reads as a
                    // panel within the app, not as the app itself.
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 1))
                    .padding(12)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Linux didn't start", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(message)
                .textSelection(.enabled)
        } actions: {
            HStack {
                Button("Try Again") {
                    Task { try? await session.startIfNeeded() }
                }
                .buttonStyle(.borderedProminent)

                Button("Show Boot Log") {
                    NSWorkspace.shared.selectFile(
                        GuestBundle.stateDirectory.appendingPathComponent("boot.log").path,
                        inFileViewerRootedAtPath: GuestBundle.stateDirectory.path)
                }
            }
        }
    }
}
