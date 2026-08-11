import Foundation

/// Everything the UI is allowed to know about "there is a Linux over there".
///
/// The whole point of this seam is that `ContainerBackend` (Apple
/// Containerization) can be swapped for an EFI/Alpine disk-image backend
/// without the terminal or the UI noticing. Keep it byte-oriented and dumb:
/// no VT parsing lives here, that is SwiftTerm's job.
protocol LinuxBackend: Actor {
    /// Bytes coming *out* of the guest, destined for the terminal view.
    var output: AsyncStream<ArraySlice<UInt8>> { get }

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

    var errorDescription: String? {
        switch self {
        case .missingAsset(let name):
            return """
                Missing runtime asset "\(name)". The app bundle is incomplete — \
                reinstall cs-OS, or run `make assets` if this is a dev build.
                """
        case .notRunning:
            return "The Linux guest is not running."
        }
    }
}
