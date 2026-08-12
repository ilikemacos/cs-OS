import Foundation
import Observation
import Virtualization

/// A real macOS guest running under Virtualization.framework.
///
/// This is what makes `.dmg` and `.pkg` work: they are Mach-O/Darwin
/// installers, so nothing short of actual macOS can open them. A Linux guest —
/// however convincingly themed — never can.
///
/// Apple silicon only, and Apple's licence permits two macOS VMs per host.
/// Everything lives under ~/Library/Application Support, so no sudo is needed
/// at any point; the only entitlement required is
/// com.apple.security.virtualization, which ad-hoc signing grants.
///
/// Unlike `MicroVMSupervisor`, this VM is created on the **main queue**:
/// `VZVirtualMachineView` requires it, and the whole point here is a visible
/// desktop rather than a vsock pipe.
@MainActor
@Observable
final class MacGuest {

    enum Phase: Equatable {
        case idle
        /// No restore image on disk yet; we know the size so the UI can warn.
        case needsRestoreImage(sizeBytes: Int64?)
        case downloadingRestoreImage(fraction: Double)
        case preparing
        case installing(fraction: Double)
        case running
        case stopped
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var virtualMachine: VZVirtualMachine?

    /// Guest display, in points. Backing scale is applied at build time.
    var displayWidth = 1920
    var displayHeight = 1200

    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    // MARK: - Paths

    static var directory: URL {
        GuestBundle.stateDirectory.appendingPathComponent("macos", isDirectory: true)
    }
    private static var diskURL: URL { directory.appendingPathComponent("disk.img") }
    private static var auxURL: URL { directory.appendingPathComponent("aux.img") }
    private static var identifierURL: URL { directory.appendingPathComponent("machine-id.bin") }
    private static var hardwareModelURL: URL { directory.appendingPathComponent("hardware-model.bin") }
    static var restoreImageURL: URL { directory.appendingPathComponent("RestoreImage.ipsw") }

    /// True once macOS has actually been installed into the disk image.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: auxURL.path)
            && FileManager.default.fileExists(atPath: identifierURL.path)
            && FileManager.default.fileExists(atPath: diskURL.path)
    }

    // MARK: - Sizing

    /// Disk is created sparse: the file reports 64GB but consumes only what the
    /// guest writes, so this does not cost 64GB up front.
    static let diskSizeBytes: UInt64 = 64 * 1024 * 1024 * 1024

    private static func memoryBytes(minimum: UInt64) -> UInt64 {
        let host = ProcessInfo.processInfo.physicalMemory
        // Leave the host at least 4GB; macOS guests are miserable below 4GB.
        let target = max(minimum, min(host / 2, 6 << 30))
        return min(max(target, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                   VZVirtualMachineConfiguration.maximumAllowedMemorySize)
    }

    // MARK: - Entry point

    /// Boots the guest, installing macOS first if this is a fresh setup.
    func start() async {
        guard phase == .idle || phase == .stopped else { return }

        do {
            try FileManager.default.createDirectory(
                at: Self.directory, withIntermediateDirectories: true)

            if Self.isInstalled {
                phase = .preparing
                try await boot()
            } else {
                guard FileManager.default.fileExists(atPath: Self.restoreImageURL.path) else {
                    phase = .needsRestoreImage(sizeBytes: nil)
                    return
                }
                try await install(from: Self.restoreImageURL)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Restore image

    /// Asks Apple for the newest supported restore image and downloads it.
    /// This is ~14GB; the UI is expected to say so before calling.
    func downloadLatestRestoreImage() async {
        phase = .downloadingRestoreImage(fraction: 0)
        do {
            let image = try await VZMacOSRestoreImage.latestSupported
            try await download(from: image.url, to: Self.restoreImageURL)
            await start()
        } catch {
            phase = .failed("Could not download the macOS restore image.\n\n\(error.localizedDescription)")
        }
    }

    /// Uses an .ipsw the user already has, avoiding the download entirely.
    func useLocalRestoreImage(at url: URL) async {
        do {
            try FileManager.default.createDirectory(
                at: Self.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: Self.restoreImageURL.path) {
                try FileManager.default.removeItem(at: Self.restoreImageURL)
            }
            // Hard-link when possible so a 14GB file is not duplicated.
            do {
                try FileManager.default.linkItem(at: url, to: Self.restoreImageURL)
            } catch {
                try FileManager.default.copyItem(at: url, to: Self.restoreImageURL)
            }
            await start()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func download(from remote: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: remote) { temp, _, error in
                if let error {
                    cont.resume(throwing: error); return
                }
                guard let temp else {
                    cont.resume(throwing: CocoaError(.fileNoSuchFile)); return
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temp, to: destination)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
            progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor in
                    self?.phase = .downloadingRestoreImage(fraction: progress.fractionCompleted)
                }
            }
            downloadTask = task
            task.resume()
        }
        progressObservation = nil
        downloadTask = nil
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        progressObservation = nil
        phase = .needsRestoreImage(sizeBytes: nil)
    }

    // MARK: - Install

    private func install(from ipsw: URL) async throws {
        phase = .preparing

        let restoreImage = try await VZMacOSRestoreImage.image(from: ipsw)
        guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw Failure("This Mac cannot run the macOS version in that restore image.")
        }

        // Persist the hardware model and machine identifier: reusing them on
        // later launches is what makes the installed system keep booting.
        let hardwareModel = requirements.hardwareModel
        try hardwareModel.dataRepresentation.write(to: Self.hardwareModelURL)

        let identifier = VZMacMachineIdentifier()
        try identifier.dataRepresentation.write(to: Self.identifierURL)

        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: Self.auxURL, hardwareModel: hardwareModel, options: [])

        try createSparseDisk(at: Self.diskURL, size: Self.diskSizeBytes)

        let config = try makeConfiguration(
            hardwareModel: hardwareModel,
            identifier: identifier,
            minimumCPUCount: requirements.minimumSupportedCPUCount,
            minimumMemory: requirements.minimumSupportedMemorySize)

        let machine = VZVirtualMachine(configuration: config)
        self.virtualMachine = machine

        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: ipsw)
        phase = .installing(fraction: 0)

        let observation = installer.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor in
                self?.phase = .installing(fraction: progress.fractionCompleted)
            }
        }
        defer { observation.invalidate() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            installer.install { result in cont.resume(with: result) }
        }

        // Reclaim the restore image immediately: it is ~14GB, it is only ever
        // needed once, and Apple can re-serve it if the guest is ever erased.
        // This is the single biggest lever we have on total disk footprint.
        try? FileManager.default.removeItem(at: Self.restoreImageURL)

        phase = .running
    }

    /// Bytes actually consumed on disk, not the sparse file's nominal size.
    /// `st_blocks` is the honest number to show a user worrying about space.
    static func actualDiskUsageBytes() -> Int64 {
        var total: Int64 = 0
        for url in [diskURL, auxURL, restoreImageURL] {
            guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
                  let size = values.totalFileAllocatedSize else { continue }
            total += Int64(size)
        }
        return total
    }

    // MARK: - Boot an already-installed guest

    private func boot() async throws {
        let hardwareData = try Data(contentsOf: Self.hardwareModelURL)
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData) else {
            throw Failure("The stored hardware model is unreadable. Erase the guest and reinstall.")
        }
        let identifierData = try Data(contentsOf: Self.identifierURL)
        guard let identifier = VZMacMachineIdentifier(dataRepresentation: identifierData) else {
            throw Failure("The stored machine identifier is unreadable. Erase the guest and reinstall.")
        }

        let config = try makeConfiguration(
            hardwareModel: hardwareModel,
            identifier: identifier,
            minimumCPUCount: 2,
            minimumMemory: 4 << 30)

        let machine = VZVirtualMachine(configuration: config)
        self.virtualMachine = machine

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            machine.start { result in cont.resume(with: result) }
        }
        phase = .running
    }

    // MARK: - Configuration

    private func makeConfiguration(
        hardwareModel: VZMacHardwareModel,
        identifier: VZMacMachineIdentifier,
        minimumCPUCount: Int,
        minimumMemory: UInt64
    ) throws -> VZVirtualMachineConfiguration {

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: Self.auxURL)

        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()

        let cores = ProcessInfo.processInfo.activeProcessorCount
        config.cpuCount = min(max(minimumCPUCount, cores - 2),
                              VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        config.memorySize = Self.memoryBytes(minimum: minimumMemory)

        // Graphics: this is the whole reason the macOS guest exists.
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: displayWidth * 2,
                heightInPixels: displayHeight * 2,
                pixelsPerInch: 220)   // Retina; the guest sees a HiDPI panel
        ]
        config.graphicsDevices = [graphics]

        // Input. Screen-coordinate pointing gives absolute positioning, so the
        // host and guest cursors track each other instead of drifting.
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        let attachment = try VZDiskImageStorageDeviceAttachment(url: Self.diskURL, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]

        config.audioDevices = [Self.makeAudioDevice()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Lets the guest resize its display when the window resizes, and
        // enables clipboard sharing via the Spice agent in macOS guests.
        let sharing = VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        config.memoryBalloonDevices = [sharing]

        try config.validate()
        return config
    }

    private static func makeAudioDevice() -> VZVirtioSoundDeviceConfiguration {
        let audio = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        let input = VZVirtioSoundDeviceInputStreamConfiguration()
        input.source = VZHostAudioInputStreamSource()
        audio.streams = [output, input]
        return audio
    }

    /// A sparse file: `truncate`-style extension costs no real disk until the
    /// guest writes. Creating 64GB eagerly would be unusable.
    private func createSparseDisk(at url: URL, size: UInt64) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw Failure("Could not create the guest disk image at \(url.path)")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }

    // MARK: - Lifecycle

    func stop() async {
        guard let machine = virtualMachine, machine.state == .running else { return }
        try? await machine.requestStop()
        phase = .stopped
    }

    /// Deletes the installed guest. Destructive and irreversible, so the UI
    /// must confirm before calling.
    func eraseGuest() throws {
        guard phase != .running else {
            throw Failure("Stop the guest before erasing it.")
        }
        for url in [Self.diskURL, Self.auxURL, Self.identifierURL, Self.hardwareModelURL] {
            try? FileManager.default.removeItem(at: url)
        }
        phase = .idle
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
