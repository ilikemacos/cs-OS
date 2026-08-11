import Foundation
import Virtualization

/// One terminal tab == one vsock connection == one pty + /bin/sh in the guest.
///
/// Using vsock rather than a serial console is what makes real tabs possible:
/// a serial port is a single byte stream you'd have to multiplex by hand, and
/// resize/exit signalling would have to be escaped inline with user output.
final class VsockSession: @unchecked Sendable {
    private let connection: VZVirtioSocketConnection
    private let io: DispatchIO
    private let queue: DispatchQueue
    private var decoder = FrameDecoder()
    private var closed = false
    private let lock = NSLock()

    /// pty output destined for the terminal view. Always called on `queue`.
    var onData: (@Sendable (ArraySlice<UInt8>) -> Void)?
    /// Shell exited, or the transport died. Called at most once.
    var onClose: (@Sendable (Int32?) -> Void)?

    init(connection: VZVirtioSocketConnection) {
        self.connection = connection
        self.queue = DispatchQueue(label: "com.chopstickshq.cs-os.session", qos: .userInteractive)

        // The connection owns its descriptor; DispatchIO must not close it, so
        // we hand ownership back in the cleanup handler instead.
        let fd = connection.fileDescriptor
        var ioRef: DispatchIO?
        ioRef = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in
            _ = ioRef  // keep the channel alive until cleanup actually runs
        }
        guard let channel = ioRef else {
            fatalError("DispatchIO could not be created for vsock fd \(fd)")
        }
        // Deliver bytes as soon as any arrive — buffering adds input latency
        // that is very visible when typing.
        channel.setLimit(lowWater: 1)
        self.io = channel

        startReading()
    }

    private func startReading() {
        io.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.handle(Data(data))
            }
            if error != 0 {
                self.finish(status: nil)
            } else if done {
                // done with no error and no data => peer closed the connection.
                self.finish(status: nil)
            }
        }
    }

    private func handle(_ chunk: Data) {
        let frames: [Frame]
        do {
            frames = try decoder.push(chunk)
        } catch {
            // A framing violation means the guest agent is out of sync or
            // wedged; there is no safe way to resynchronise a stream protocol,
            // so tear the session down rather than emit garbage.
            NSLog("cs-OS: vsock framing error: \(error). Closing session.")
            finish(status: nil)
            return
        }

        for frame in frames {
            switch frame.type {
            case .data:
                onData?(frame.payload[...])
            case .exit:
                finish(status: frame.payload.first.map(Int32.init) ?? 0)
                return
            case .ping:
                send(Frame(type: .ping, payload: []))
            case .resize:
                break  // host-to-guest only; ignore if echoed back
            }
        }
    }

    func write(_ bytes: ArraySlice<UInt8>) {
        send(Frame.data(bytes))
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        send(Frame.resize(cols: cols, rows: rows))
    }

    private func send(_ frame: Frame) {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return }

        let encoded = frame.encoded()
        encoded.withUnsafeBytes { raw in
            let dd = DispatchData(bytes: raw)
            io.write(offset: 0, data: dd, queue: queue) { _, _, error in
                if error != 0 {
                    NSLog("cs-OS: vsock write failed, errno \(error)")
                }
            }
        }
    }

    /// Idempotent: the read handler can report both an error and completion.
    private func finish(status: Int32?) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        io.close()
        connection.close()
        onClose?(status)
    }

    func close() {
        finish(status: nil)
    }
}
