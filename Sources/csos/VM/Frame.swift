import Foundation

/// Wire protocol shared with the guest agent (`guest/src/paned.c`).
///
/// A single vsock connection carries one terminal session. Because we need
/// out-of-band window-resize notifications interleaved with pty bytes, the
/// stream is framed rather than raw:
///
///     +--------+------------------+-----------------+
///     | type   | length (u32, BE) | payload         |
///     | 1 byte | 4 bytes          | `length` bytes  |
///     +--------+------------------+-----------------+
///
/// Keep this in lockstep with the `FRAME_*` constants in paned.c.
enum FrameType: UInt8 {
    /// pty bytes, both directions.
    case data = 1
    /// host -> guest, payload is two BE u16: cols, rows.
    case resize = 2
    /// guest -> host, payload is one byte: the shell's exit status.
    case exit = 3
    /// keepalive, either direction, empty payload.
    case ping = 4
}

struct Frame {
    let type: FrameType
    let payload: [UInt8]

    static let headerSize = 5
    /// Guard against a malformed/hostile guest asking us to buffer a gigabyte.
    static let maxPayload = 1 << 20

    func encoded() -> Data {
        var out = Data(capacity: Frame.headerSize + payload.count)
        out.append(type.rawValue)
        let len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: len) { out.append(contentsOf: $0) }
        out.append(contentsOf: payload)
        return out
    }

    static func data(_ bytes: ArraySlice<UInt8>) -> Frame {
        Frame(type: .data, payload: Array(bytes))
    }

    static func resize(cols: Int, rows: Int) -> Frame {
        let c = UInt16(clamping: cols).bigEndian
        let r = UInt16(clamping: rows).bigEndian
        var p: [UInt8] = []
        withUnsafeBytes(of: c) { p.append(contentsOf: $0) }
        withUnsafeBytes(of: r) { p.append(contentsOf: $0) }
        return Frame(type: .resize, payload: p)
    }
}

/// Incremental decoder. vsock gives us arbitrary chunk boundaries, so frames
/// routinely straddle two reads; this accumulates until whole frames exist.
struct FrameDecoder {
    private var buffer: [UInt8] = []

    enum DecodeError: Error {
        case payloadTooLarge(Int)
        case unknownType(UInt8)
    }

    mutating func push(_ incoming: Data) throws -> [Frame] {
        buffer.append(contentsOf: incoming)
        var frames: [Frame] = []

        while buffer.count >= Frame.headerSize {
            let rawType = buffer[0]
            let length =
                (Int(buffer[1]) << 24) | (Int(buffer[2]) << 16) |
                (Int(buffer[3]) << 8) | Int(buffer[4])

            guard length <= Frame.maxPayload else {
                throw DecodeError.payloadTooLarge(length)
            }
            // Whole frame not here yet; wait for the next read.
            guard buffer.count >= Frame.headerSize + length else { break }

            let payload = Array(buffer[Frame.headerSize ..< Frame.headerSize + length])
            buffer.removeFirst(Frame.headerSize + length)

            guard let type = FrameType(rawValue: rawType) else {
                // Unknown frame types are skipped rather than fatal: it lets a
                // newer guest agent add frame kinds without breaking old hosts.
                continue
            }
            frames.append(Frame(type: type, payload: payload))
        }
        return frames
    }
}
