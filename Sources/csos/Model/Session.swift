import Foundation
import Observation

/// One tab: one OCI image, one microVM, one shell.
@MainActor
@Observable
final class Session: Identifiable {
    /// What this session actually is. Both kinds live in the same sidebar and
    /// the same window; only the detail view differs.
    enum Kind: Equatable {
        /// Linux under the bundled microVM: sub-second boot, ~120MB idle.
        case linux
        /// A real macOS guest: the only kind where .dmg/.pkg installers work.
        case macOS
    }

    let id = UUID()
    let kind: Kind
    let image: String

    /// Non-nil only for `.macOS` sessions.
    private(set) var macGuest: MacGuest?

    var title: String
    var workingDirectory: String?
    var scrollPosition: Double = 0
    var state: State = .idle

    /// Existential, not concrete: which backend this is depends on the OS.
    /// See BackendFactory.
    private(set) var backend: (any LinuxBackend)?

    enum State: Equatable {
        case idle, booting, running, failed(String), exited
    }

    var defaultTitle: String {
        image.split(separator: "/").last.map(String.init) ?? image
    }

    init(kind: Kind = .linux, image: String = "docker.io/library/alpine:latest") {
        self.kind = kind
        self.image = image
        switch kind {
        case .linux:
            self.title = image.split(separator: "/").last.map(String.init) ?? image
        case .macOS:
            self.title = "macOS"
            self.macGuest = MacGuest()
        }
    }

    func startIfNeeded() async throws {
        // macOS guests drive their own phase machine inside MacGuest; there is
        // no LinuxBackend involved.
        if kind == .macOS {
            await macGuest?.start()
            return
        }
        guard backend == nil else { return }
        state = .booting
        do {
            let backend = BackendFactory.make(image: image)
            self.backend = backend
            try await backend.start()
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
            backend = nil
            throw error
        }
    }

    func close() async {
        await macGuest?.stop()
        await backend?.stop()
        backend = nil
        state = .exited
    }
}

@MainActor
@Observable
final class SessionStore {
    var sessions: [Session] = []
    var selected: Session.ID?

    /// Images offered in the new-tab menu. Purely a convenience list — any OCI
    /// reference works via the image field.
    static let presets = [
        "docker.io/library/alpine:latest",
        "docker.io/library/debian:stable-slim",
        "docker.io/library/ubuntu:24.04",
        "docker.io/library/fedora:41",
    ]

    init() { newSession() }

    /// Starts a full macOS desktop session. Only one is offered: Apple's
    /// licence permits two macOS VMs per host and one is plenty here.
    @discardableResult
    func newMacSession() -> Session {
        if let existing = sessions.first(where: { $0.kind == .macOS }) {
            selected = existing.id
            return existing
        }
        let session = Session(kind: .macOS)
        sessions.append(session)
        selected = session.id
        return session
    }

    @discardableResult
    func newSession(image: String = presets[0]) -> Session {
        let session = Session(image: image)
        sessions.append(session)
        selected = session.id
        return session
    }

    func close(_ session: Session) {
        Task { await session.close() }
        sessions.removeAll { $0.id == session.id }
        if selected == session.id { selected = sessions.last?.id }
        if sessions.isEmpty { newSession() }
    }

    var current: Session? {
        sessions.first { $0.id == selected } ?? sessions.first
    }

    /// Cycle sessions with ⌘⇧[ / ⌘⇧], the standard Mac tab shortcuts. Wraps,
    /// because stopping at the ends is a surprise in a tab strip.
    func selectRelative(_ offset: Int) {
        guard !sessions.isEmpty else { return }
        let index = sessions.firstIndex { $0.id == selected } ?? 0
        let next = (index + offset % sessions.count + sessions.count) % sessions.count
        selected = sessions[next].id
    }
}
