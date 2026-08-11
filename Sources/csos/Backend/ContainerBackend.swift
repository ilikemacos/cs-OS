// Compiled only when the Containerization SPM package is available.
//
// SwiftPM cannot run on every machine (CLT 26.5 ships a libPackageDescription
// exporting no Package symbols), so the Makefile's local swiftc pipeline builds
// the microVM backend alone and leaves this out. CI, which has a working
// SwiftPM, defines CSOS_CONTAINERIZATION and gets both.
#if CSOS_CONTAINERIZATION

import Containerization
import ContainerizationError
import ContainerizationOS
import Foundation

/// Linux backend built on Apple's Containerization framework (macOS 26+).
///
/// Each session is one OCI image running in its own lightweight VM. We hand
/// the guest process the *child* half of a host PTY pair and read the *parent*
/// half — so from SwiftTerm's point of view this is indistinguishable from a
/// local shell, and job control / TIOCGWINSZ / SIGWINCH all behave.
actor ContainerBackend: LinuxBackend {

    // MARK: Runtime assets

    /// Only the kernel ships in the bundle. The guest init comes from Apple's
    /// published OCI image (see `initfsReference`), which means cs-OS needs no
    /// Linux build toolchain to produce a release — just a kernel download.
    struct Assets {
        var kernel: URL
        var stateRoot: URL

        /// Resolve from the .app bundle, falling back to `./.build/assets` so
        /// `swift run` works during development without a bundle.
        static func resolve() throws -> Assets {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("cs-OS", isDirectory: true)
            try FileManager.default.createDirectory(
                at: support, withIntermediateDirectories: true)

            let candidates: [URL] = [
                Bundle.main.resourceURL?.appendingPathComponent("linux", isDirectory: true),
                URL(fileURLWithPath: ".build/assets", isDirectory: true),
            ].compactMap { $0 }

            for dir in candidates {
                let kernel = dir.appendingPathComponent("vmlinux")
                if FileManager.default.fileExists(atPath: kernel.path) {
                    return Assets(kernel: kernel, stateRoot: support)
                }
            }
            throw BackendError.missingAsset("vmlinux")
        }
    }

    /// Apple publishes the guest init (`vminitd`) as a public OCI image. The tag
    /// must track the Containerization version pinned in Package.swift — the
    /// vsock/gRPC contract between host and guest is versioned together.
    static let initfsReference = "ghcr.io/apple/containerization/vminit:0.33.3"

    // MARK: State

    private let id: String
    private let image: String
    private let assets: Assets

    private var container: LinuxContainer?
    private var parentPTY: Terminal?
    private var readSource: DispatchSourceRead?
    private var continuation: AsyncStream<ArraySlice<UInt8>>.Continuation?
    private var stopped = false

    let output: AsyncStream<ArraySlice<UInt8>>

    init(id: String = UUID().uuidString.prefix(12).lowercased(),
         image: String = "docker.io/library/alpine:latest") throws {
        self.id = String(id)
        self.image = image
        self.assets = try Assets.resolve()

        var cont: AsyncStream<ArraySlice<UInt8>>.Continuation!
        self.output = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    // MARK: Lifecycle

    func start() async throws {
        let kernel = Kernel(path: assets.kernel, platform: .linuxArm)

        // Resolves the guest init from the registry on first launch and caches
        // it in the image store; subsequent launches are offline.
        var manager = try await ContainerManager(
            kernel: kernel,
            initfsReference: Self.initfsReference,
            root: assets.stateRoot,
            network: try VmnetNetwork()
        )

        // 120x40 is a placeholder; the view resizes us before first paint.
        let (parent, child) = try Terminal.create(
            initialSize: Terminal.Size(width: 120, height: 40))
        self.parentPTY = parent

        let container = try await manager.create(
            id,
            reference: image,
            rootfsSizeInBytes: UInt64(4096).mib(),
            readOnly: false,
            networking: true
        ) { config in
            config.cpus = 2
            config.memoryInBytes = UInt64(1024).mib()
            config.hostname = "cs-os"
            config.process.setTerminalIO(terminal: child)
            config.process.arguments = ["/bin/sh", "-l"]
            config.process.workingDirectory = "/root"
            config.process.environmentVariables = [
                "TERM=xterm-256color",
                "PS1=\\[\\e[38;5;110m\\]\\w\\[\\e[0m\\] $ ",
                "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            ]
            // Reap zombies so long-lived sessions don't accumulate PIDs.
            config.useInit = true
        }

        try await container.create()
        try await container.start()
        self.container = container

        beginReading(from: parent)
    }

    /// Pump the parent PTY on a GCD read source. This deliberately does *not*
    /// go through FileHandle's readability notifications — those hop through
    /// the main run loop and stutter under heavy output (`yes`, a kernel build).
    private func beginReading(from parent: Terminal) {
        let fd = parent.handle.fileDescriptor
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: DispatchQueue(label: "sh.chopsticks.csos.pty", qos: .userInteractive)
        )
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else {
                if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                    Task { await self?.stop() }
                }
                return
            }
            self?.emit(buf[0..<n])
        }
        source.resume()
        self.readSource = source
    }

    /// nonisolated so the read source can publish without hopping the actor —
    /// the continuation is itself thread-safe.
    private nonisolated func emit(_ slice: ArraySlice<UInt8>) {
        Task { await self.yieldOutput(slice) }
    }

    private func yieldOutput(_ slice: ArraySlice<UInt8>) {
        continuation?.yield(slice)
    }

    // MARK: I/O

    func write(_ bytes: ArraySlice<UInt8>) async {
        guard let parentPTY else { return }
        try? parentPTY.write(Data(bytes))
    }

    func resize(cols: Int, rows: Int) async {
        guard cols > 0, rows > 0 else { return }
        let size = Terminal.Size(width: UInt16(cols), height: UInt16(rows))
        try? parentPTY?.resize(size: size)
        try? await container?.resize(to: size)
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        readSource?.cancel()
        readSource = nil
        continuation?.finish()
        continuation = nil
        try? await container?.stop()
        container = nil
        try? parentPTY?.close()
        parentPTY = nil
    }
}

#endif  // CSOS_CONTAINERIZATION
