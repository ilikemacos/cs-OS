import Foundation

/// Everything the UI is allowed to know about "there is a Linux over there".
///
/// The whole point of this seam is that `ContainerBackend` (Apple
/// Containerization) can be swapped for an EFI/Alpine disk-image backend
/// without the terminal or the UI noticing. Keep it byte-oriented and dumb:
/// no VT parsing lives here, that is SwiftTerm's job.
protocol LinuxBackend: Actor {
    /// Bytes coming *out* of the guest, destined for the terminal view.
    ///
    /// nonisolated so the view can grab the stream without an await hop —
    /// AsyncStream is Sendable and the continuation is thread-safe, so there is
    /// nothing to protect. Without this, reaching it through `any LinuxBackend`
    /// is an actor-isolation error even though the conformers store it in a
    /// `let`.
    nonisolated var output: AsyncStream<ArraySlice<UInt8>> { get }

    /// Boot the guest and spawn the login process. Resolves once the process
    /// is running — not once the shell has drawn a prompt.
    func start() async throws

    /// Bytes going *in* to the guest, typed by the user.
    func write(_ bytes: ArraySlice<UInt8>) async

    /// Propagate a window resize so the guest's TIOCGWINSZ is honest.
    func resize(cols: Int, rows: Int) async

    /// Terminate the guest. Safe to call more than once.
    func stop() async
}

enum BackendError: LocalizedError {
    case missingAsset(String)
    case notRunning
    case vmStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAsset(let name):
            return """
                Missing runtime asset "\(name)". The app bundle is incomplete — \
                reinstall cs-OS, or run `make assets` if this is a dev build.
                """
        case .notRunning:
            return "The Linux guest is not running."
        case .vmStartFailed(let detail):
            return "The Linux virtual machine could not be started.\n\n\(detail)"
        }
    }
}

/// Chooses the backend for the running OS.
///
/// Containerization is richer — arbitrary OCI images, the whole Docker Hub —
/// but it is macOS 26+ only. Below that we fall back to the bundled microVM,
/// which is what keeps cs-OS installable on 4GB-class machines that can never
/// run macOS 26. Both satisfy `LinuxBackend`, so the UI never branches.
enum BackendFactory {

    enum Kind: String {
        case containerization
        case microVM
    }

    /// `nil` image means "whatever the backend's default userland is".
    static func make(image: String?) -> any LinuxBackend {
        switch preferredKind {
        case .containerization:
            #if CSOS_CONTAINERIZATION
            if #available(macOS 26.0, *) {
                if let image, let backend = try? ContainerBackend(image: image) {
                    return backend
                }
            }
            #endif
            // Falls through when the Containerization build flag is off or the
            // image failed to resolve — better a working shell than no shell.
            return MicroVMBackend()
        case .microVM:
            return MicroVMBackend()
        }
    }

    static var preferredKind: Kind {
        #if CSOS_CONTAINERIZATION
        if #available(macOS 26.0, *) { return .containerization }
        #endif
        return .microVM
    }

    /// True when this build can offer the OCI image picker in the UI.
    static var supportsImageSelection: Bool {
        preferredKind == .containerization
    }
}
