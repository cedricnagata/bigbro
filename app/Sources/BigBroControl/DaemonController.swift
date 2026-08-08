import Foundation
import Observation

/// Starts the Python daemon, or attaches to one that is already running.
///
/// The distinction is the whole design. Someone who ran `bigbro serve` in a
/// terminal and then opens the app must not get a second daemon fighting over
/// port 8765 and the control socket, so the first thing this does is ask whether
/// anyone is already listening. If so it attaches and — importantly — leaves that
/// daemon running on quit. This mirrors the `owns_daemon` flag the Textual
/// dashboard carried between `serve` and `ui`.
///
/// A child `Process` rather than a launchd agent: quitting the app should mean
/// the daemon it started stops, without installing a system service from
/// something the user dragged out of a disk image. Start-at-login is a separate,
/// explicit choice (see `LoginItem`).
@Observable
@MainActor
public final class DaemonController {
    public enum Mode: Equatable, Sendable {
        /// We started it, and we stop it on quit.
        case owned
        /// Someone else started it. Quitting leaves it alone.
        case attached
        case stopped
    }

    /// How long to let `shutdown()` say goodbye to peers, stop Bonjour, unlink
    /// the socket and drop the power assertion. The same ten seconds the Textual
    /// dashboard waited.
    private static let terminationGrace: TimeInterval = 10

    public private(set) var mode: Mode = .stopped
    /// Set when the daemon exits without being asked to. Carries the real reason.
    public private(set) var failure: String?

    /// The daemon's last words, kept off the main actor.
    ///
    /// A pipe's readability handler fires on a Dispatch queue, not here, so this
    /// cannot be actor-isolated state guarded by a lock — it has to be genuinely
    /// nonisolated, with the locking inside.
    private final class StderrTail: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private let limit: Int

        /// Enough to explain a startup crash without holding a log file.
        init(limit: Int = 40) { self.limit = limit }

        func append(_ text: String) {
            lock.lock()
            defer { lock.unlock() }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                lines.append(String(line))
            }
            if lines.count > limit {
                lines.removeFirst(lines.count - limit)
            }
        }

        func clear() {
            lock.lock()
            lines.removeAll()
            lock.unlock()
        }

        var joined: String {
            lock.lock()
            defer { lock.unlock() }
            return lines.joined(separator: "\n")
        }

        var lastLine: String? {
            lock.lock()
            defer { lock.unlock() }
            return lines.last
        }
    }

    private let socketPath: String
    private let client: ControlClient
    private var process: Process?

    /// Which run a termination handler belongs to.
    ///
    /// The handler fires off-actor and cannot carry the `Process` back with it —
    /// `Process` is not Sendable — so identity is a counter instead. It also
    /// distinguishes a crash from a shutdown we asked for: `stop()` bumps this,
    /// so the SIGTERM it sends does not come back as a failure alert.
    private var run = 0
    private let stderr = StderrTail()

    public init(client: ControlClient) {
        self.client = client
        self.socketPath = client.socketPath
    }

    public var isRunning: Bool { mode != .stopped }

    /// Stopping is offered for anything that is running, including a daemon
    /// started elsewhere. An orphan — one whose app crashed, or one from a
    /// terminal window since closed — is otherwise visible here and stoppable
    /// nowhere, while still holding the Mac awake.
    public var canStop: Bool { mode != .stopped }

    /// Quitting stops the daemon, whoever started it.
    ///
    /// The alternative — leaving an attached daemon running — meant closing the
    /// app could leave the Mac awake with nothing visible holding it, which is
    /// the behaviour this replaces. Still worth knowing which one you are ending,
    /// so the menu says when it was started elsewhere.
    public var stopsOnQuit: Bool { mode != .stopped }
    public var startedElsewhere: Bool { mode == .attached }

    /// Attaches if a daemon is already up, otherwise starts one.
    public func startOrAttach() async {
        if await isDaemonListening() {
            mode = .attached
            return
        }
        await start()
    }

    private func isDaemonListening() async -> Bool {
        do {
            _ = try await client.send(.status, as: Status.self)
            return true
        } catch {
            // ENOENT (no socket) and ECONNREFUSED (a socket left by a daemon that
            // crashed) both mean nobody is serving. Neither needs cleaning up here:
            // `ControlServer.start` unlinks a stale socket before it binds.
            return false
        }
    }

    public func start() async {
        guard process == nil else { return }
        guard let launch = Self.resolveLaunch() else {
            failure = """
                Could not find the bundled Python runtime, and no `bigbro` on PATH. \
                Reinstall BigBro, or set BIGBRO_DAEMON_COMMAND to a command that runs it.
                """
            return
        }

        failure = nil
        stderr.clear()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: launch.executable)
        task.arguments = launch.arguments

        // A deliberately small environment, with one entry that is load-bearing:
        // `computer_name()` shells out to `scutil --get ComputerName`, and without
        // a PATH it silently falls back to the hostname — so the Bonjour name every
        // iPhone sees degrades from "Cedric's MacBook Pro" to "cedrics-macbook-pro".
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "PYTHONNOUSERSITE": "1",
            "PYTHONUNBUFFERED": "1",
        ]
        // Note what is *not* set: HF_HOME. Weights stay in the default
        // ~/.cache/huggingface so the app and a `uv tool install`ed CLI share one
        // cache instead of each downloading twelve gigabytes.
        if let home = ProcessInfo.processInfo.environment["BIGBRO_HOME"] {
            environment["BIGBRO_HOME"] = home
        }
        task.environment = environment

        let errorPipe = Pipe()
        task.standardError = errorPipe
        task.standardOutput = Pipe()

        // Both pipes must be drained even when nobody reads them: a Process whose
        // 64 KB pipe buffer fills blocks the child on write.
        let tail = stderr
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            tail.append(text)
        }
        (task.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        run += 1
        let thisRun = run
        task.terminationHandler = { [weak self] finished in
            guard let self else { return }
            let status = finished.terminationStatus
            Task { @MainActor in self.daemonExited(run: thisRun, status: status) }
        }

        do {
            try task.run()
        } catch {
            failure = "Could not start the daemon: \(error.localizedDescription)"
            return
        }

        process = task
        mode = .owned
    }

    public var recentStderr: String { stderr.joined }

    /// The daemon went away without being asked to.
    ///
    /// Reporting only "cannot find a control socket" would describe the symptom
    /// and hide the cause, so the exit status and the tail of stderr — where the
    /// port conflict or the import error actually is — go into the message.
    private func daemonExited(run finished: Int, status: Int32) {
        // A handler from a daemon we already replaced, or one we stopped on purpose.
        guard finished == run else { return }
        process = nil
        mode = .stopped

        failure = stderr.lastLine.map { "The daemon stopped: \($0)" }
            ?? "The daemon stopped unexpectedly (exit code \(status))."
    }

    /// Stops the daemon, however it was started.
    ///
    /// An owned one gets SIGTERM, which its signal handler turns into a clean
    /// shutdown. An attached one cannot be signalled — we have no handle on a
    /// process we did not spawn — so it is asked over the control socket, which
    /// reaches the same `stop()` on the other side.
    public func stop() async {
        guard mode != .stopped else { return }

        guard mode == .owned, let task = process else {
            try? await client.call(.shutdown)
            mode = .stopped
            return
        }
        process = nil
        // Past this point the termination handler is a stale run, so the exit it
        // reports is not a failure anyone needs telling about.
        run += 1
        // SIGTERM, which `Daemon._install_signal_handlers` turns into a clean
        // shutdown: `bye` to every peer, Bonjour down, socket unlinked, wake lock
        // released.
        task.terminate()

        let deadline = Date().addingTimeInterval(Self.terminationGrace)
        while task.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if task.isRunning {
            kill(task.processIdentifier, SIGKILL)
        }
        mode = .stopped
    }

    public func restart() async {
        await stop()
        await start()
    }

    /// What quitting does. Stops whatever is running, however it was started.
    public func stopOnQuit() async {
        guard stopsOnQuit else { return }
        await stop()
    }

    // MARK: - Finding something to run

    struct Launch: Equatable {
        let executable: String
        let arguments: [String]
    }

    /// Where the daemon comes from, most specific first.
    ///
    /// The bundled interpreter is invoked directly as `python3 -m bigbro` rather
    /// than through a console script: a generated script carries an absolute
    /// shebang from whichever machine built it, and `-m` sidesteps that entirely.
    /// `__main__.py` already guards `if __name__ == "__main__"`, so it works today.
    /// Takes the resources directory rather than a `Bundle` so the resolution
    /// order can be tested without one.
    ///
    /// `nonisolated` because it is pure: environment variables and file checks,
    /// no state on this class. Isolating it would only mean every caller and
    /// every test had to hop to the main actor to ask a question about the disk.
    nonisolated static func resolveLaunch(
        resources: URL? = Bundle.main.resourceURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        pathCandidates: [String] = [
            NSHomeDirectory() + "/.local/bin/bigbro",
            "/opt/homebrew/bin/bigbro",
            "/usr/local/bin/bigbro",
        ]
    ) -> Launch? {
        // Development escape hatch: run against a `uv tool install`ed daemon with
        // no bundled runtime in sight.
        if let override = environment["BIGBRO_DAEMON_COMMAND"], !override.isEmpty {
            var parts = override.split(separator: " ").map(String.init)
            guard !parts.isEmpty else { return nil }
            let executable = parts.removeFirst()
            return Launch(executable: executable, arguments: parts + ["serve", "--no-ui", "--exit-with-parent"])
        }

        if let resources {
            let python = resources.appendingPathComponent("python/bin/python3")
            if fileManager.isExecutableFile(atPath: python.path) {
                return Launch(
                    executable: python.path, arguments: ["-m", "bigbro", "serve", "--no-ui", "--exit-with-parent"]
                )
            }
        }

        for candidate in pathCandidates where fileManager.isExecutableFile(atPath: candidate) {
            return Launch(executable: candidate, arguments: ["serve", "--no-ui", "--exit-with-parent"])
        }

        return nil
    }
}
