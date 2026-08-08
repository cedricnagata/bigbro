import Foundation
import Observation

/// Everything the dashboard knows, and every rule about when to re-read it.
///
/// This is the part of `tui.py` that was never really about Textual: which command
/// each action sends, when an event can be applied in place and when the daemon
/// has to be asked again, and which pairing requests have already been put to the
/// user. Keeping it here — with no SwiftUI in sight — is what lets those rules be
/// tested without a window server, and it is why `BigBroControl` is a separate
/// target.
///
/// The daemon stays the authority on ordering and on state wording. Nothing here
/// sorts a model list.
/// `@Observable` rather than `ObservableObject`: it is in the Observation module,
/// not SwiftUI, so the library stays free of any UI framework while still driving
/// one. macOS 14 is the floor for both.
@Observable
@MainActor
public final class DashboardModel {
    /// Matches the Textual log's backlog. Enough to scroll through an incident,
    /// bounded so a daemon that logs all night cannot grow without limit.
    public static let logCapacity = 2000

    public struct LogLine: Sendable, Equatable, Identifiable {
        public let id: Int
        public let level: String
        public let message: String
    }

    public private(set) var status: Status?
    public private(set) var groups: [ModelGroup] = []
    public private(set) var devices: [Device] = []
    public private(set) var pending: [PendingRequest] = []
    public private(set) var settings: SettingsValues?
    public private(set) var editableSettings: [String] = []
    public private(set) var logLines: [LogLine] = []

    /// The request the UI should be showing, if any. Set only through the rules in
    /// `raisePrompt`, so a retried request cannot stack a second sheet.
    public private(set) var prompt: PendingRequest?

    /// Whether the event stream is currently attached to a daemon.
    public private(set) var isAttached = false

    /// The last thing worth telling the user — a rejected setting, a lost stream.
    public private(set) var lastMessage: String?

    private let transport: ControlTransport
    private var prompted: Set<String> = []
    private var nextLogID = 0

    /// Model ids with a command in flight, against the state they were in when it
    /// was sent.
    ///
    /// The four model verbs all answer immediately and report the real work as
    /// events — `models.start` especially, because holding the reply through a
    /// twelve gigabyte load would look like a freeze. That is right for the
    /// daemon and wrong for a button, which otherwise sits there looking unpressed
    /// for several seconds. Remembering the state at the time of the request lets
    /// the spinner clear on the first event that actually changes something,
    /// rather than on a timer or a guess.
    private var inFlight: [String: String] = [:]
    private var inFlightExpiry: [String: Task<Void, Never>] = [:]

    /// How long a spinner may run before giving up on ever hearing back. A
    /// backstop for a dropped event, not the normal path — a stuck spinner is
    /// worse than an early one.
    private static let inFlightTimeout: Duration = .seconds(30)

    public init(transport: ControlTransport) {
        self.transport = transport
    }

    // MARK: - Reading

    /// Re-reads everything. Cheap enough to be the answer to most events.
    public func refresh() async {
        do {
            let status = try await send(.status, as: Status.self)
            self.status = status

            let pairing = try await send(.pairList, as: PairList.self)
            devices = pairing.devices
            pending = pairing.pending

            let settingsReply = try await send(.settingsGet, as: SettingsReply.self)
            settings = settingsReply.settings
            editableSettings = settingsReply.editable ?? []

            await refreshModels()

            // A request parked before this client attached never produced an event
            // we saw, so the only way to notice it is to look. Without this, a
            // phone that asked while the app was closed waits out its timeout with
            // nobody ever being asked.
            for request in pending {
                raisePrompt(for: request)
            }
        } catch {
            lastMessage = Self.describe(error)
        }
    }

    /// Re-reads just the model panes — the daemon's ranking, re-fetched rather
    /// than re-sorted here, so there is one ordering and it lives in one place.
    public func refreshModels() async {
        do {
            groups = try await send(.modelsList, as: ModelsList.self).groups
            settleBusy()
        } catch {
            lastMessage = Self.describe(error)
        }
    }

    // MARK: - Events

    public func handle(_ event: DaemonEvent) async {
        switch event {
        case .log(let level, _, let message):
            append(level: level, message: message)

        case .pairingRequested(let request):
            raisePrompt(for: request)

        case .pairingResolved, .peerConnected, .peerDisconnected:
            await refresh()

        case .modelState(let model, let state):
            await applyState(state, to: model)

        case .downloadProgress(let progress):
            await applyState(progress.displayState, to: progress.model)

        case .settingsChanged(let values):
            settings = values

        case .attached:
            isAttached = true
            lastMessage = nil
            await refresh()

        case .detached(let reason):
            isAttached = false
            lastMessage = reason

        case .unknown:
            // A newer daemon saying something this build predates. Not an error.
            break
        }
    }

    /// Writes one model's state, and decides whether that was a reordering.
    ///
    /// Rows are ranked by how far along a model is, so a genuine stage change has
    /// to re-sort — but download progress arrives twice a second, and rebuilding
    /// the table that often would fight the selection and flicker. Comparing only
    /// the leading word separates the two: "downloading 12%" → "downloading 13%"
    /// is the same stage and lands in place, while "downloading 100%" →
    /// "downloaded" is a move and goes back to the daemon for the new order.
    private func applyState(_ state: String?, to modelID: String) async {
        guard let location = locate(modelID) else { return }

        let previous = Self.leadingWord(groups[location.group].models[location.entry].state)
        let current = Self.leadingWord(state)
        let moved = !(state ?? "").isEmpty && previous != current

        if let state, !state.isEmpty {
            groups[location.group].models[location.entry].state = state
        }
        if moved {
            await refreshModels()
        }
        settleBusy()
    }

    private func locate(_ modelID: String) -> (group: Int, entry: Int)? {
        for (group, candidate) in groups.enumerated() {
            if let entry = candidate.models.firstIndex(where: { $0.id == modelID }) {
                return (group, entry)
            }
        }
        return nil
    }

    static func leadingWord(_ state: String?) -> String {
        state?.split(separator: " ").first.map(String.init) ?? ""
    }

    private func append(level: String, message: String) {
        logLines.append(LogLine(id: nextLogID, level: level, message: message))
        nextLogID += 1
        if logLines.count > Self.logCapacity {
            logLines.removeFirst(logLines.count - Self.logCapacity)
        }
    }

    // MARK: - Pairing

    /// One prompt per device. The daemon re-announces a parked request when the
    /// phone retries, and a sheet per retry would bury the Approve button under
    /// copies of itself.
    private func raisePrompt(for request: PendingRequest) {
        guard !prompted.contains(request.deviceId) else { return }
        prompted.insert(request.deviceId)
        prompt = request
    }

    /// Answers whatever is on screen. Dismissing without choosing is a denial —
    /// the phone is waiting either way, and silence would strand it.
    public func resolvePrompt(approved: Bool) async {
        guard let request = prompt else { return }
        prompt = nil
        await resolve(deviceId: request.deviceId, approved: approved)
    }

    public func resolve(deviceId: String, approved: Bool) async {
        prompted.remove(deviceId)
        do {
            try await call(approved ? .pairApprove(deviceId) : .pairDeny(deviceId))
        } catch {
            lastMessage = Self.describe(error)
        }
        await refresh()
    }

    public func forget(deviceId: String) async { await run(.pairRemove(deviceId)) }
    public func disconnect(deviceId: String) async { await run(.pairDisconnect(deviceId)) }
    public func forgetEveryDevice() async { await run(.pairRemoveAll) }

    // MARK: - Models

    /// `models.start` answers the moment it has begun, because loading a 12 GB
    /// model takes long enough that holding the reply would look like a freeze.
    /// Real progress arrives as events, so none of these wait for completion.
    public func download(_ model: String) async { await act(.modelsDownload(model), on: model) }
    public func start(_ model: String) async { await act(.modelsStart(model), on: model) }
    public func stop(_ model: String) async { await act(.modelsStop(model), on: model) }
    public func delete(_ model: String) async { await act(.modelsDelete(model), on: model) }

    /// Whether a command for this model has been sent and nothing has come back.
    public func isBusy(_ modelID: String) -> Bool { inFlight[modelID] != nil }

    private func act(_ command: Command, on modelID: String) async {
        markBusy(modelID)
        do {
            try await call(command)
        } catch {
            lastMessage = Self.describe(error)
            // A refused command produces no state change, so nothing would ever
            // arrive to clear the spinner.
            clearBusy(modelID)
        }
    }

    private func markBusy(_ modelID: String) {
        inFlight[modelID] = stateOf(modelID) ?? ""
        inFlightExpiry[modelID]?.cancel()
        inFlightExpiry[modelID] = Task { [weak self] in
            try? await Task.sleep(for: Self.inFlightTimeout)
            guard !Task.isCancelled else { return }
            self?.clearBusy(modelID)
        }
    }

    private func clearBusy(_ modelID: String) {
        inFlight.removeValue(forKey: modelID)
        inFlightExpiry.removeValue(forKey: modelID)?.cancel()
    }

    /// Clears any spinner whose model has moved on since its command was sent.
    private func settleBusy() {
        for (modelID, sentAt) in inFlight where stateOf(modelID) != sentAt {
            clearBusy(modelID)
        }
    }

    private func stateOf(_ modelID: String) -> String? {
        guard let at = locate(modelID) else { return nil }
        return groups[at.group].models[at.entry].state
    }

    // MARK: - Settings

    /// Writes one setting. Returns whether the daemon accepted it.
    ///
    /// On rejection the local value is deliberately left alone, so the caller can
    /// reset the field to what is still true rather than leaving a port on screen
    /// that nothing is listening on.
    @discardableResult
    public func set(_ key: String, to value: JSONValue) async -> Bool {
        do {
            let reply = try await send(.settingsSet(key: key, value: value), as: SettingsReply.self)
            settings = reply.settings
            lastMessage = reply.message
            return true
        } catch {
            lastMessage = Self.describe(error)
            return false
        }
    }

    // MARK: - Plumbing

    private func send<R: Decodable>(_ command: Command, as type: R.Type) async throws -> R {
        try Reply.decode(type, from: try await transport.send(command))
    }

    private func call(_ command: Command) async throws {
        try Reply.check(try await transport.send(command))
    }

    private func run(_ command: Command, reread: Bool = true) async {
        do {
            try await call(command)
        } catch {
            lastMessage = Self.describe(error)
        }
        if reread { await refresh() }
    }

    private static func describe(_ error: Error) -> String {
        (error as? ControlError)?.description ?? error.localizedDescription
    }
}
