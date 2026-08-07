import Foundation

/// Whatever a `DashboardModel` sends commands through.
///
/// Exists so the model can be tested against canned replies without a socket,
/// while the real client stays the thing that talks to the daemon. The Python
/// dashboard got this for free by pointing at a stub `ControlServer`; the same
/// trick works here (see `PythonServerTests`), but a plain in-process double keeps
/// the behavioural tests fast.
public protocol ControlTransport: Sendable {
    func send(_ command: Command) async throws -> Data
}

/// The client half of `src/bigbro/control.py`.
public actor ControlClient: ControlTransport {
    public let socketPath: String
    private let timeout: TimeInterval

    /// Mirrors `config.support_dir()` — including `BIGBRO_HOME`, so a test or a
    /// second instance can be pointed somewhere else without touching the real one.
    public static func defaultSocketPath() -> String {
        let root: String
        if let override = ProcessInfo.processInfo.environment["BIGBRO_HOME"], !override.isEmpty {
            root = override
        } else {
            root = NSHomeDirectory() + "/Library/Application Support/bigbro"
        }
        return root + "/control.sock"
    }

    public init(socketPath: String? = nil, timeout: TimeInterval = 10) {
        self.socketPath = socketPath ?? Self.defaultSocketPath()
        self.timeout = timeout
    }

    /// Sends one command and returns the reply body.
    ///
    /// One connection per command, opened and closed — not pooled. That is not
    /// frugality, it is the protocol: `ControlServer._serve` writes a single frame
    /// and closes in its `finally`, so a reused socket would be dead on the second
    /// command.
    public func send(_ command: Command) async throws -> Data {
        let body = try JSONEncoder().encode(command)
        let path = socketPath
        let timeout = self.timeout

        return try await Self.offMainThread {
            let socket = ControlSocket()
            defer { socket.close() }
            try socket.connect(to: path, timeout: timeout)
            try socket.write(Framing.frame(body))
            guard let reply = try socket.readFrame() else {
                throw ControlError.closedWithoutReplying
            }
            return reply
        }
    }

    /// Sends a command and decodes its reply, failing with the daemon's own words.
    public func send<R: Decodable>(_ command: Command, as type: R.Type) async throws -> R {
        try Reply.decode(type, from: try await send(command))
    }

    /// Sends a command that returns nothing but an envelope.
    @discardableResult
    public func call(_ command: Command) async throws -> Envelope {
        try Reply.check(try await send(command))
    }

    /// An endless stream of daemon events, reconnecting on its own.
    ///
    /// On its own connection, deliberately: a command is short-lived and may be
    /// issued while the UI is mid-render, and interleaving replies with pushed
    /// events on one socket would mean matching them up. `control.py` says the
    /// same thing from the other side.
    ///
    /// The stream never finishes on its own. A daemon that is not running yet is a
    /// normal state — the app can be open before `serve` is — so a failure yields
    /// `.detached` and retries rather than ending. Cancel the consuming task (or
    /// drop the stream) to stop it.
    public nonisolated func events() -> AsyncStream<DaemonEvent> {
        let path = socketPath
        return AsyncStream { continuation in
            let worker = EventStreamWorker(socketPath: path, continuation: continuation)
            continuation.onTermination = { _ in worker.stop() }
            worker.start()
        }
    }

    private static let queue = DispatchQueue(
        label: "com.bigbro.control", qos: .userInitiated, attributes: .concurrent
    )

    /// Socket calls block; the cooperative thread pool must not.
    private static func offMainThread<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Owns the long-lived subscribe connection and the thread blocked on it.
///
/// A thread rather than a task because the read is a blocking `read(2)` that can
/// sit idle for hours on a quiet daemon, and parking a cooperative-pool thread
/// there would be antisocial. Cancellation works by closing the descriptor out
/// from under the read, which is the only thing that interrupts it.
final class EventStreamWorker: @unchecked Sendable {
    /// Same two seconds the Textual dashboard waited between attempts.
    private static let retryDelay: TimeInterval = 2

    private let socketPath: String
    private let continuation: AsyncStream<DaemonEvent>.Continuation
    private let lock = NSLock()
    private var socket: ControlSocket?
    private var stopped = false

    init(socketPath: String, continuation: AsyncStream<DaemonEvent>.Continuation) {
        self.socketPath = socketPath
        self.continuation = continuation
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "bigbro.events"
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let open = socket
        socket = nil
        lock.unlock()
        // Closing here is what unblocks the read; without it the thread would sit
        // in `read(2)` until the daemon happened to say something.
        open?.close()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run() {
        while !isStopped {
            do {
                try attach()
            } catch {
                if isStopped { break }
                continuation.yield(.detached(reason: Self.describe(error)))
            }

            lock.lock()
            let open = socket
            socket = nil
            lock.unlock()
            open?.close()

            if isStopped { break }
            Thread.sleep(forTimeInterval: Self.retryDelay)
        }
        continuation.finish()
    }

    private func attach() throws {
        let socket = ControlSocket()
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        self.socket = socket
        lock.unlock()

        // No read timeout: on this connection silence is the normal case, and a
        // timeout would turn a quiet daemon into an endless reconnect loop.
        try socket.connect(to: socketPath, timeout: 0)
        try socket.write(Framing.frame(try JSONEncoder().encode(Command.subscribe)))

        guard let ack = try socket.readFrame() else { throw ControlError.closedWithoutReplying }
        try Reply.check(ack)
        continuation.yield(.attached)

        while !isStopped {
            guard let frame = try socket.readFrame() else { break }
            // One malformed event should not tear down a stream that is otherwise
            // fine — the daemon's own decoder takes the same view.
            if let event = try? DaemonEvent(from: frame) {
                continuation.yield(event)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? ControlError)?.description ?? error.localizedDescription
    }
}
