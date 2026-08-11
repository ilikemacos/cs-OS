import Foundation

/// `LinuxBackend` over a shared Virtualization.framework microVM.
///
/// This is the backend for macOS 14–25, where Apple's Containerization
/// framework does not exist. It is also the smaller and faster of the two:
/// one kernel for the whole app, ~120MB idle, sub-second boot.
///
/// One instance == one tab == one vsock connection == one pty + /bin/sh.
actor MicroVMBackend: LinuxBackend {

    private let supervisor: MicroVMSupervisor
    private var session: VsockSession?
    private var stopped = false

    private let stream: AsyncStream<ArraySlice<UInt8>>
    private let continuation: AsyncStream<ArraySlice<UInt8>>.Continuation

    nonisolated var output: AsyncStream<ArraySlice<UInt8>> { stream }

    init(supervisor: MicroVMSupervisor = .shared) {
        self.supervisor = supervisor
        // Buffer rather than drop: a burst of build output must not lose lines
        // just because the view is mid-layout.
        var cont: AsyncStream<ArraySlice<UInt8>>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    func start() async throws {
        guard session == nil, !stopped else { return }

        let session = try await supervisor.openSession()
        self.session = session

        // VsockSession delivers on its own queue; hop back into the actor.
        session.onData = { [weak self] bytes in
            guard let self else { return }
            let copy = Array(bytes)
            Task { await self.emit(copy[...]) }
        }
        session.onClose = { [weak self] status in
            guard let self else { return }
            Task { await self.handleClose(status: status) }
        }
    }

    private func emit(_ bytes: ArraySlice<UInt8>) {
        guard !stopped else { return }
        continuation.yield(bytes)
    }

    private func handleClose(status: Int32?) {
        guard !stopped else { return }
        let note = status.map { "\r\n[process exited with status \($0)]\r\n" }
            ?? "\r\n[connection to guest closed]\r\n"
        continuation.yield(ArraySlice(Array(note.utf8)))
        stopped = true
        session = nil
        continuation.finish()
    }

    func write(_ bytes: ArraySlice<UInt8>) async {
        session?.write(bytes)
    }

    func resize(cols: Int, rows: Int) async {
        session?.resize(cols: cols, rows: rows)
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        session?.close()
        session = nil
        continuation.finish()
        // Deliberately does not shut the VM down: other tabs share it. The
        // supervisor is torn down at app exit.
    }
}
