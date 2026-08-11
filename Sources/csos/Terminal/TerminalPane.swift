import AppKit
import SwiftTerm
import SwiftUI

/// SwiftTerm's `TerminalView` bridged into SwiftUI.
///
/// PERFORMANCE CONTRACT: this view is **opaque**. No `.glassEffect`, no
/// vibrancy, no transparency anywhere in this file. A translucent layer behind
/// a surface that repaints on every keystroke forces the compositor to re-blur
/// continuously and is exactly how a pretty terminal ends up feeling slow.
/// The glass belongs to the chrome around it — see `GlassChrome.swift`.
struct TerminalPane: NSViewRepresentable {
    let session: Session

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: Theme.monospace)
        view.terminalDelegate = context.coordinator
        view.configureNativeColors()

        // Opaque background, matched to the window tint so the seam is invisible.
        view.nativeBackgroundColor = Theme.terminalBackground
        view.nativeForegroundColor = Theme.terminalForeground
        view.caretColor = Theme.accent
        view.layer?.isOpaque = true
        view.layer?.backgroundColor = Theme.terminalBackground.cgColor

        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        if view.font != Theme.monospace { view.font = Theme.monospace }
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: Session
        private weak var view: TerminalView?
        private var pump: Task<Void, Never>?

        init(session: Session) {
            self.session = session
            super.init()
        }

        func attach(_ view: TerminalView) {
            self.view = view
            guard pump == nil else { return }

            pump = Task { [weak self] in
                do {
                    try await session.startIfNeeded()
                } catch {
                    self?.writeBanner(error)
                    return
                }
                guard let stream = await session.backend?.output else { return }
                for await chunk in stream {
                    self?.view?.feed(byteArray: chunk)
                }
            }
        }

        /// Surface backend failures in the terminal itself rather than an
        /// alert sheet — it keeps the failure next to the context.
        private func writeBanner(_ error: Error) {
            let text = "\r\n\u{1b}[31mcs-OS:\u{1b}[0m \(error.localizedDescription)\r\n"
            view?.feed(text: text)
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            Task { await session.backend?.write(data) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { await session.backend?.resize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            session.title = title.isEmpty ? session.defaultTitle : title
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            session.workingDirectory = directory
        }

        func scrolled(source: TerminalView, position: Double) {
            // Drives the chrome parallax. Clamped hard — see GlassChrome.
            session.scrollPosition = position
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link),
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else { return }
            NSWorkspace.shared.open(url)
        }

        func bell(source: TerminalView) {
            NSSound.beep()
        }

        deinit { pump?.cancel() }
    }
}
