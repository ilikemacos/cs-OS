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

    /// `TerminalViewDelegate` is a nonisolated protocol, so the coordinator
    /// cannot be `@MainActor` without the conformance crossing isolation.
    /// Instead it is nonisolated and every callback re-enters the main actor via
    /// `assumeIsolated` — sound because AppKit only ever calls these on main.
    final class Coordinator: NSObject, TerminalViewDelegate {
        private nonisolated(unsafe) let session: Session
        private nonisolated(unsafe) weak var view: TerminalView?
        private nonisolated(unsafe) var pump: Task<Void, Never>?

        init(session: Session) {
            self.session = session
            super.init()
        }

        @MainActor
        func attach(_ view: TerminalView) {
            self.view = view
            guard pump == nil else { return }

            pump = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.session.startIfNeeded()
                } catch {
                    self.writeBanner(error)
                    return
                }
                guard let stream = self.session.backend?.output else { return }
                for await chunk in stream {
                    self.view?.feed(byteArray: chunk)
                }
            }
        }

        /// Surface backend failures in the terminal itself rather than an
        /// alert sheet — it keeps the failure next to the context.
        @MainActor
        private func writeBanner(_ error: Error) {
            let text = "\r\n\u{1b}[31mcs-OS:\u{1b}[0m \(error.localizedDescription)\r\n"
            view?.feed(text: text)
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            MainActor.assumeIsolated {
                let backend = session.backend
                Task { await backend?.write(bytes[...]) }
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                let backend = session.backend
                Task { await backend?.resize(cols: newCols, rows: newRows) }
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            MainActor.assumeIsolated {
                session.title = title.isEmpty ? session.defaultTitle : title
            }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            MainActor.assumeIsolated {
                session.workingDirectory = directory
            }
        }

        func scrolled(source: TerminalView, position: Double) {
            // Drives the chrome parallax. Clamped hard — see GlassChrome.
            MainActor.assumeIsolated {
                session.scrollPosition = position
            }
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

        /// OSC 52 — the guest asking to put something on the host clipboard.
        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            MainActor.assumeIsolated {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }

        func clipboardRead(source: TerminalView) -> Data? {
            MainActor.assumeIsolated {
                NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
            }
        }

        /// iTerm2 inline-image protocol. cs-OS renders text only, so the payload
        /// is dropped rather than half-drawn.
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        /// Fires only when `notifyUpdateChanges` is enabled, which it isn't.
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        deinit { pump?.cancel() }
    }
}
