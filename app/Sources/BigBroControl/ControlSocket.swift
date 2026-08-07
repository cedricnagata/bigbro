import Darwin
import Foundation

/// A blocking `AF_UNIX` stream socket speaking the daemon's framing.
///
/// Raw `socket(2)` rather than `NWConnection` with `NWEndpoint.unix`, for two
/// reasons that both come back to error fidelity. A missing socket puts an
/// `NWConnection` into `.waiting(.posix(.ENOENT))` where it retries forever, so
/// reproducing "No running daemon found — start one with: bigbro serve" would mean
/// bolting a timeout on top of a state machine designed not to fail. And the
/// 104-byte `sun_path` limit — which macOS reports as a bare "AF_UNIX path too
/// long" — is checked here up front, the same way and for the same reason
/// `ControlServer.start` checks it.
///
/// Every method blocks. `ControlClient` owns the job of keeping that off the
/// cooperative thread pool.
final class ControlSocket: @unchecked Sendable {
    /// `sun_path` is 104 bytes on Darwin, 108 on Linux. Take the smaller.
    static let maxPathBytes = 104

    private let lock = NSLock()
    private var descriptor: Int32 = -1

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0
    }

    /// Connects, or throws something that says what to do about it.
    ///
    /// A `timeout` of zero means block indefinitely, which is what the event
    /// stream wants: a quiet daemon is not a broken one.
    func connect(to path: String, timeout: TimeInterval) throws {
        let bytes = Array(path.utf8)
        guard bytes.count < Self.maxPathBytes else {
            throw ControlError.pathTooLong(bytes: bytes.count, path: path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.posix(code: errno, operation: "socket") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, size)
            }
        }

        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            // ENOENT: no socket file. ECONNREFUSED: the file is there but nothing
            // is listening — a daemon that crashed without unlinking it. The user
            // does the same thing about both.
            if code == ENOENT || code == ECONNREFUSED {
                throw ControlError.noDaemon(path: path)
            }
            throw ControlError.posix(code: code, operation: "connect")
        }

        if timeout > 0 {
            Self.setTimeout(fd, SO_RCVTIMEO, timeout)
            Self.setTimeout(fd, SO_SNDTIMEO, timeout)
        }

        lock.lock()
        descriptor = fd
        lock.unlock()
    }

    private static func setTimeout(_ fd: Int32, _ option: Int32, _ seconds: TimeInterval) {
        var value = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    private func currentDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw ControlError.closedWithoutReplying }
        return descriptor
    }

    func write(_ data: Data) throws {
        let fd = try currentDescriptor()
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ControlError.posix(code: errno, operation: "write")
                }
                if written == 0 { throw ControlError.closedWithoutReplying }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }

    /// Reads exactly `count` bytes. `nil` means a clean EOF *before any* arrived —
    /// the peer hung up between messages, which is not an error.
    private func readExactly(_ count: Int) throws -> Data? {
        guard count > 0 else { return Data() }
        let fd = try currentDescriptor()
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0

        while filled < count {
            let got: Int = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!.advanced(by: filled), count - filled)
            }
            if got < 0 {
                if errno == EINTR { continue }
                throw ControlError.posix(code: errno, operation: "read")
            }
            if got == 0 {
                // Mid-frame EOF is a truncated message, which is a different
                // problem from a peer that finished and left.
                if filled == 0 { return nil }
                throw ControlError.malformedFrame(
                    "connection closed \(count - filled) bytes into a \(count) byte frame"
                )
            }
            filled += got
        }
        return Data(buffer)
    }

    /// One whole frame, or `nil` at a clean end of stream.
    func readFrame() throws -> Data? {
        guard let prefix = try readExactly(Framing.lengthPrefixBytes) else { return nil }
        let length = try Framing.bodyLength(of: prefix)
        guard length > 0 else { return Data() }
        guard let body = try readExactly(length) else {
            throw ControlError.malformedFrame("connection closed before a \(length) byte body")
        }
        return body
    }

    /// Safe to call from another thread: closing the descriptor is what interrupts
    /// a blocking read, which is how the event stream is cancelled.
    func close() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
    }

    deinit { close() }
}
