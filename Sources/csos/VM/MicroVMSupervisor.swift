import Foundation
import Virtualization

/// Owns the single Linux microVM that backs every tab.
///
/// Unlike `ContainerBackend` (one lightweight VM per container), the microVM
/// backend boots *one* kernel and multiplexes tabs over vsock. That is what
/// keeps idle RAM near 120MB on a 4GB machine: a second tab costs a pty and a
/// /bin/sh, not another kernel.
///
/// Threading: `VZVirtualMachine` is not thread-safe and must be driven on the
/// queue it was constructed with. This actor serialises callers; `vmQueue`
/// serialises the framework.
actor MicroVMSupervisor {
    static let shared = MicroVMSupervisor()

    /// Guest port paned listens on. Must match GUEST_VSOCK_PORT in paned.c.
    static let vsockPort: UInt32 = 1024

    private nonisolated let vmQueue = DispatchQueue(
        label: "com.chopstickshq.csos.vm", qos: .userInitiated)
    private var vm: VZVirtualMachine?
    private var socketDevice: VZVirtioSocketDevice?
    /// Guards against two tabs racing to boot the VM at once.
    private var bootTask: Task<Void, Error>?

    // MARK: - Sizing

    /// The stated system minimum is 4GB total RAM, so the guest must stay
    /// modest by default. The balloon device returns pages to macOS when the
    /// guest is idle, making this closer to a ceiling than a reservation.
    static func defaultMemoryBytes() -> UInt64 {
        let host = ProcessInfo.processInfo.physicalMemory
        let target: UInt64
        switch host {
        case ..<(6 << 30):  target = 512 << 20   // 4GB host: stay out of the way
        case ..<(12 << 30): target = 1 << 30     // 8GB host
        default:            target = 2 << 30     // 16GB+
        }
        return min(max(target, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                   VZVirtualMachineConfiguration.maximumAllowedMemorySize)
    }

    static func defaultCPUCount() -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        // Leave headroom for the host UI; a terminal VM gains little past 4.
        let target = max(1, min(cores - 1, 4))
        return min(max(target, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                   VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    }

    // MARK: - Configuration

    private static func makeConfiguration(guest: GuestBundle) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = defaultCPUCount()
        config.memorySize = defaultMemoryBytes()

        let bootLoader = VZLinuxBootLoader(kernelURL: guest.kernel)
        bootLoader.initialRamdiskURL = guest.initramfs
        // `quiet` keeps boot under a second by not spending it on console I/O.
        // vda = read-only erofs userland, vdb = the user's writable overlay.
        bootLoader.commandLine = "console=hvc0 quiet loglevel=3 panic=-1 csos.overlay=/dev/vdb"
        config.bootLoader = bootLoader

        let rootAttachment = try VZDiskImageStorageDeviceAttachment(url: guest.rootfs, readOnly: true)
        let overlayAttachment = try VZDiskImageStorageDeviceAttachment(url: guest.overlay, readOnly: false)
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: rootAttachment),
            VZVirtioBlockDeviceConfiguration(attachment: overlayAttachment)
        ]

        // NAT specifically: it needs no root and no restricted entitlement.
        // Bridged mode would require com.apple.vm.networking, which Apple only
        // grants by application — avoided deliberately so cs-OS stays sudo-free.
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]

        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Kernel console to a log file, for diagnosing boot failures in the field.
        let logURL = GuestBundle.stateDirectory.appendingPathComponent("boot.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: nil, fileHandleForWriting: logHandle)
            config.serialPorts = [serial]
        }

        try config.validate()
        return config
    }

    // MARK: - Lifecycle

    /// Boots the VM if it is not already running. Concurrent callers await the
    /// same boot rather than starting a second machine.
    func ensureBooted() async throws {
        if socketDevice != nil { return }
        if let existing = bootTask {
            try await existing.value
            return
        }
        let task = Task { try await self.boot() }
        bootTask = task
        do {
            try await task.value
        } catch {
            bootTask = nil
            throw error
        }
    }

    private func boot() async throws {
        let guest = try GuestBundle.load()
        let config = try Self.makeConfiguration(guest: guest)
        let machine = VZVirtualMachine(configuration: config, queue: vmQueue)
        self.vm = machine

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                vmQueue.async {
                    machine.start { cont.resume(with: $0) }
                }
            }
        } catch {
            self.vm = nil
            // The overwhelmingly likely cause is a missing or stripped
            // com.apple.security.virtualization entitlement, which surfaces as
            // an opaque failure. Say something actionable instead.
            throw BackendError.vmStartFailed(
                """
                \(error.localizedDescription)

                This usually means the app bundle lost its code signature (for \
                example, it was copied in a way that stripped it). Reinstalling \
                cs-OS will restore it.
                """)
        }

        self.socketDevice = await withCheckedContinuation { cont in
            vmQueue.async {
                cont.resume(returning: machine.socketDevices.first as? VZVirtioSocketDevice)
            }
        }
        guard socketDevice != nil else {
            throw BackendError.vmStartFailed("The guest exposed no vsock device.")
        }
    }

    /// Opens a fresh pty + shell in the guest. One call per tab.
    func openSession() async throws -> VsockSession {
        try await ensureBooted()
        guard let device = socketDevice else { throw BackendError.notRunning }

        let port = Self.vsockPort
        let connection: VZVirtioSocketConnection = try await withCheckedThrowingContinuation { cont in
            vmQueue.async {
                device.connect(toPort: port) { cont.resume(with: $0) }
            }
        }
        return VsockSession(connection: connection)
    }

    /// Shuts the whole machine down. Only meaningful once the last tab closes.
    func shutdown() async {
        guard let machine = vm else { return }
        _ = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            vmQueue.async {
                guard machine.canRequestStop else {
                    cont.resume(throwing: BackendError.notRunning); return
                }
                do { try machine.requestStop(); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
        vm = nil
        socketDevice = nil
        bootTask = nil
    }
}
