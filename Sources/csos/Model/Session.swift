import Foundation
import Observation

/// One tab: one OCI image, one microVM, one shell.
@MainActor
@Observable
final class Session: Identifiable {
    let id = UUID()
    let image: String

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

    init(image: String = "docker.io/library/alpine:latest") {
        self.image = image
        self.title = image.split(separator: "/").last.map(String.init) ?? image
    }

    func startIfNeeded() async throws {
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
}
