import CryptoKit
import Foundation

/// Locates and validates the Linux guest artifacts shipped inside the .app,
/// and prepares the per-user writable overlay disk.
///
/// Layout inside the bundle. cs-OS ships a universal binary, so the guest is
/// per-architecture: an arm64 Mac cannot boot an x86_64 kernel.
///
///     Contents/Resources/guest/manifest.json          sha256 of every file below
///     Contents/Resources/guest/<arch>/kernel          uncompressed Image / bzImage
///     Contents/Resources/guest/<arch>/initramfs.cpio.gz  busybox + paned
///     Contents/Resources/guest/<arch>/rootfs.erofs    read-only Alpine userland
///     Contents/Resources/guest/<arch>/overlay-seed.ext4  empty ext4, grown on boot
///
/// where <arch> is `arm64` or `x86_64`. Manifest keys are the arch-relative
/// paths, e.g. "arm64/kernel".
struct GuestBundle {
    let kernel: URL
    let initramfs: URL
    let rootfs: URL
    let overlay: URL

    enum GuestError: LocalizedError {
        case missingResource(String)
        case checksumMismatch(String, expected: String, actual: String)
        case manifestUnreadable(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                return "The guest image component '\(name)' is missing from the application bundle. Reinstall cs-OS."
            case .checksumMismatch(let name, let expected, let actual):
                return "Integrity check failed for '\(name)'.\nExpected \(expected)\nFound    \(actual)\nReinstall cs-OS."
            case .manifestUnreadable(let why):
                return "Could not read the guest manifest: \(why)"
            }
        }
    }

    /// Which guest tree this binary slice needs. Compile-time, not runtime:
    /// under Rosetta an x86_64 slice must boot the x86_64 kernel even though
    /// the machine is arm64.
    static var hostArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// Where mutable per-user state lives. Deliberately under the user's own
    /// Library — nothing in cs-OS ever writes outside $HOME, which is what
    /// keeps the whole product sudo-free.
    static var stateDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("cs-OS", isDirectory: true)
    }

    static func load() throws -> GuestBundle {
        guard let resources = Bundle.main.resourceURL else {
            throw GuestError.missingResource("Resources")
        }
        let root = resources.appendingPathComponent("guest", isDirectory: true)
        let guestDir = root.appendingPathComponent(hostArch, isDirectory: true)

        let manifestURL = root.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw GuestError.manifestUnreadable(manifestURL.path)
        }
        guard let checksums = try? JSONDecoder().decode([String: String].self, from: manifestData) else {
            throw GuestError.manifestUnreadable("malformed JSON")
        }

        // Verify the read-only artifacts. The overlay is user-mutable by
        // design, so it is explicitly not checksummed.
        for name in ["kernel", "initramfs.cpio.gz", "rootfs.erofs"] {
            let key = "\(hostArch)/\(name)"
            let url = guestDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw GuestError.missingResource(key)
            }
            guard let expected = checksums[key] else {
                throw GuestError.manifestUnreadable("no entry for \(key)")
            }
            let actual = try sha256(of: url)
            guard actual == expected else {
                throw GuestError.checksumMismatch(key, expected: expected, actual: actual)
            }
        }

        let overlay = try prepareOverlay(seed: guestDir.appendingPathComponent("overlay-seed.ext4"))

        return GuestBundle(
            kernel: guestDir.appendingPathComponent("kernel"),
            initramfs: guestDir.appendingPathComponent("initramfs.cpio.gz"),
            rootfs: guestDir.appendingPathComponent("rootfs.erofs"),
            overlay: overlay
        )
    }

    /// Copies the tiny empty ext4 seed into the user's state dir on first run
    /// and sparsely grows it. macOS has no mkfs.ext4, so shipping a prebuilt
    /// empty filesystem and letting the guest `resize2fs` it on boot is the
    /// only way to create the writable layer without external tooling.
    private static func prepareOverlay(seed: URL, sizeGiB: Int = 8) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let overlay = stateDirectory.appendingPathComponent("overlay.ext4")

        if !fm.fileExists(atPath: overlay.path) {
            guard fm.fileExists(atPath: seed.path) else {
                throw GuestError.missingResource("overlay-seed.ext4")
            }
            try fm.copyItem(at: seed, to: overlay)

            // Sparse-extend. This costs no real disk until the guest writes;
            // the guest's init runs resize2fs to claim the new space.
            let handle = try FileHandle(forWritingTo: overlay)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(sizeGiB) * 1024 * 1024 * 1024)
        }
        return overlay
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        // Chunked so a 60MB rootfs never lands in memory all at once.
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
