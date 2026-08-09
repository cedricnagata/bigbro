import BigBroControl
import SwiftUI

@MainActor
struct DevicesPane: View {
    @Environment(AppState.self) private var state
    @State private var confirmingForgetAll = false

    var body: some View {
        VStack(spacing: 0) {
            if !state.dashboard.pending.isEmpty {
                // Pending first, the way the Textual pane ordered them — a device
                // waiting on a decision is the only thing here that is urgent.
                List(state.dashboard.pending) { request in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(request.displayName).bold()
                            Text("awaiting approval").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Deny") {
                            Task { await state.dashboard.resolve(deviceId: request.deviceId, approved: false) }
                        }
                        Button("Approve") {
                            Task { await state.dashboard.resolve(deviceId: request.deviceId, approved: true) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(height: 90)
                Divider()
            }

            Table(state.dashboard.devices) {
                TableColumn("Device") { device in
                    Label(
                        device.name,
                        systemImage: device.connected ? "circle.fill" : "circle"
                    )
                    .foregroundStyle(device.connected ? Color.green : Color.secondary)
                }
                TableColumn("App") { Text($0.appName) }
                TableColumn("ID") { Text(String($0.deviceId.prefix(8))).monospaced() }
                TableColumn("") { device in
                    HStack(spacing: 6) {
                        // Only meaningful while it is actually attached — closing a
                        // connection that is not open does nothing worth offering.
                        ActionButton(
                            title: "Disconnect",
                            enabled: device.connected,
                            width: ActionButton.deviceWidth
                        ) {
                            Task { await state.dashboard.disconnect(deviceId: device.deviceId) }
                        }

                        // Forgetting is not destructive the way deleting weights is:
                        // the device simply has to be approved again next time.
                        ActionButton(title: "Forget", width: ActionButton.deviceWidth) {
                            Task { await state.dashboard.forget(deviceId: device.deviceId) }
                        }
                    }
                }
                .width(min: ActionButton.deviceWidth * 2 + 6, ideal: ActionButton.deviceWidth * 2 + 6)
            }
            .overlay {
                if state.dashboard.devices.isEmpty && state.dashboard.pending.isEmpty {
                    ContentUnavailableView(
                        "No paired devices",
                        systemImage: "iphone.slash",
                        description: Text("Open a BigBroKit app on the same network and it will ask to pair.")
                    )
                }
            }
        }
        .toolbar {
            Button("Forget All", role: .destructive) { confirmingForgetAll = true }
                .disabled(state.dashboard.devices.isEmpty)
        }
        .confirmationDialog(
            "Forget every paired device?",
            isPresented: $confirmingForgetAll,
            titleVisibility: .visible
        ) {
            Button("Forget All", role: .destructive) {
                Task { await state.dashboard.forgetEveryDevice() }
            }
        } message: {
            Text("Each one will have to be approved again the next time it connects.")
        }
    }
}

@MainActor
struct ModelPane: View {
    @Environment(AppState.self) private var state
    let family: String

    @State private var confirmingDelete: ModelEntry?

    /// Wide enough for two buttons at their fixed width plus the gap. Set on the
    /// column as a minimum so narrowing the window takes space from the model
    /// name, which can be truncated harmlessly, rather than from a verb.
    static let actionsWidth: CGFloat = ActionButton.width * 2 + 6

    /// Read straight out of the reply, in the order it arrived. The daemon ranks
    /// these rows by how far along each model is; re-sorting here would be a
    /// second ranking that could disagree with `bigbro models list`.
    private var models: [ModelEntry] {
        state.dashboard.groups.first { $0.family == family }?.models ?? []
    }

    var body: some View {
        Table(models) {
            TableColumn("Model") { model in
                VStack(alignment: .leading) {
                    Text(model.name)
                    Text(model.id).font(.caption).foregroundStyle(.secondary).monospaced()
                }
            }
            TableColumn("Size") { Text(String(format: "%.1f GB", $0.sizeGB)) }
            TableColumn("Can") { model in
                HStack(spacing: 4) {
                    if model.tools { Image(systemName: "wrench.and.screwdriver") }
                    if model.images { Image(systemName: "photo") }
                    if model.reasoning != "none" { Image(systemName: "brain") }
                }
                .foregroundStyle(.secondary)
            }
            TableColumn("State") { model in StateCell(model: model) }
            TableColumn("Memory") { model in
                Text(Formatting.human(model.memory)).monospacedDigit()
            }
            // Two buttons, always both present, each showing the verb that
            // applies right now. A row whose controls move or disappear between
            // states is a row you have to re-read every time it changes; the
            // labels swap instead, and what cannot be done is disabled rather
            // than hidden.
            TableColumn("") { model in
                HStack(spacing: 6) {
                    ActionButton(
                        title: model.runActionIsStop ? "Stop" : "Start",
                        busy: state.dashboard.isBusy(model.id),
                        enabled: model.canRunAction
                    ) {
                        Task {
                            if model.runActionIsStop {
                                await state.dashboard.stop(model.id)
                            } else {
                                await state.dashboard.start(model.id)
                            }
                        }
                    }

                    ActionButton(
                        title: model.weightsActionIsDelete ? "Delete" : "Download",
                        busy: state.dashboard.isBusy(model.id),
                        enabled: model.canWeightsAction
                    ) {
                        if model.weightsActionIsDelete {
                            confirmingDelete = model
                        } else {
                            Task { await state.dashboard.download(model.id) }
                        }
                    }
                }
            }
            .width(min: ModelPane.actionsWidth, ideal: ModelPane.actionsWidth)
        }
        .confirmationDialog(
            "Delete \(confirmingDelete?.name ?? "")?",
            isPresented: .constant(confirmingDelete != nil),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let model = confirmingDelete {
                    Task { await state.dashboard.delete(model.id) }
                }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text("The weights come off disk. Downloading them again takes as long as the first time.")
        }
    }
}

/// A progress bar when there is a fraction to show, otherwise the daemon's words.
///
/// The percentage is already in the state string — `DashboardModel` builds it from
/// the event so a tick changes only the digits — so this parses it back out rather
/// than tracking a second copy that could disagree with the text beside it.
@MainActor
struct StateCell: View {
    let model: ModelEntry

    private var fraction: Double? {
        guard model.state.hasPrefix("downloading"),
              let percent = model.state.split(separator: " ").last?.dropLast(),
              let value = Double(percent)
        else { return nil }
        return value / 100
    }

    var body: some View {
        if let fraction {
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: fraction)
                Text(model.state).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text(model.state)
                .foregroundStyle(model.state.hasPrefix("error") ? Color.red : Color.primary)
        }
    }
}

@MainActor
struct SettingsPane: View {
    @Environment(AppState.self) private var state

    @State private var port: String = ""
    @State private var keepAwake = true
    @State private var logLevel = "INFO"
    @State private var loaded = false

    private func editable(_ key: String) -> Bool {
        state.dashboard.editableSettings.contains(key)
    }

    var body: some View {
        Form {
            Section {
                TextField("Port", text: $port)
                    .disabled(!editable("port"))
                    .onSubmit {
                        Task {
                            let accepted = await state.dashboard.set("port", to: .int(Int(port) ?? -1))
                            // A refusal leaves the daemon's value untouched, so
                            // resetting the field puts something true back on screen
                            // instead of a port nothing is listening on.
                            if !accepted { syncFromModel() }
                        }
                    }

                Toggle("Keep the Mac awake while serving", isOn: $keepAwake)
                    .disabled(!editable("keep_awake"))
                    .onChange(of: keepAwake) { _, value in
                        Task { await state.dashboard.set("keep_awake", to: .bool(value)) }
                    }

                Picker("Log level", selection: $logLevel) {
                    ForEach(["DEBUG", "INFO", "WARNING", "ERROR"], id: \.self) { Text($0) }
                }
                .disabled(!editable("log_level"))
                .onChange(of: logLevel) { _, value in
                    Task { await state.dashboard.set("log_level", to: .string(value)) }
                }
            } footer: {
                if let message = state.dashboard.lastMessage {
                    Text(message).foregroundStyle(.secondary)
                }
            }

            Section {
                // The daemon says a port change needs a restart, and unlike the
                // terminal dashboard this app owns the process, so it can offer one.
                Button("Restart Daemon") { Task { await state.daemon.restart() } }
                    .disabled(!state.daemon.canStop)
                if state.daemon.startedElsewhere {
                    Text("This daemon was started elsewhere. Quitting BigBro will still stop it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Command line") {
                CommandLineToolRow()
            }
        }
        .formStyle(.grouped)
        .onAppear { if !loaded { syncFromModel(); loaded = true } }
        .onChange(of: state.dashboard.settings) { _, _ in syncFromModel() }
    }

    private func syncFromModel() {
        guard let settings = state.dashboard.settings else { return }
        port = String(settings.port)
        keepAwake = settings.keepAwake
        logLevel = settings.logLevel
    }
}

@MainActor
struct LogPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(state.dashboard.logLines) { line in
                        Text(line.message)
                            .font(.caption.monospaced())
                            .foregroundStyle(colour(for: line.level))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(8)
                // Something a RichLog could never do.
                .textSelection(.enabled)
            }
            .onChange(of: state.dashboard.logLines.count) { _, _ in
                if let last = state.dashboard.logLines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .overlay {
                if state.dashboard.logLines.isEmpty {
                    ContentUnavailableView(
                        "No log yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Records appear here as the daemon works.")
                    )
                }
            }
        }
    }

    private func colour(for level: String) -> Color {
        switch level {
        case "ERROR", "CRITICAL": return .red
        case "WARNING": return .orange
        case "DEBUG": return .secondary
        default: return .primary
        }
    }
}

/// Offers to put `bigbro` on PATH, pointing at the interpreter inside this app.
///
/// Someone who installed from the DMG already has a complete Python and MLX
/// stack on disk; making them `uv tool install` a second copy just to run
/// `bigbro pair approve` would be silly.
@MainActor
struct CommandLineToolRow: View {
    @State private var statuses: [CommandLineTool.Scope: CommandLineTool.Status] = [:]
    @State private var userScopeIsOnPath = true
    @State private var problem: String?

    private var allTerminals: CommandLineTool.Status { statuses[.allTerminals] ?? .notInstalled }
    private var thisUser: CommandLineTool.Status { statuses[.thisUser] ?? .notInstalled }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if allTerminals == .current || thisUser == .current {
                installed
            } else {
                offer
            }

            if case .stale(let pointingAt) = allTerminals {
                repair(.allTerminals, pointingAt: pointingAt)
            }
            if case .stale(let pointingAt) = thisUser {
                repair(.thisUser, pointingAt: pointingAt)
            }

            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .task { await refresh() }
    }

    /// Both offered, with the difference stated as what it costs rather than as a
    /// path — "requires your password" is the part of the choice a user can weigh.
    @ViewBuilder private var offer: some View {
        Text("Adds `bigbro` to your shell, driving this same daemon.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("Install for All Terminals…") { install(into: .allTerminals) }
            Button("Just for Me") { install(into: .thisUser) }
        }
        Text(Self.scopeExplanation)
            .font(.caption).foregroundStyle(.secondary)
    }

    /// Stored, not built with `+` inside `Text`. See the note in CommandLineToolOffer:
    /// a long concatenation chain is one expression the release runner's compiler
    /// refuses to type-check in reasonable time.
    private static let scopeExplanation = """
        All terminals installs to /usr/local/bin and asks for your password once. \
        Just for me uses ~/.local/bin, which needs no password but is not on the default PATH.
        """

    private static let notOnPathWarning = """
        ~/.local/bin is not on your PATH. Add it to your shell profile, or install \
        for all terminals instead.
        """

    @ViewBuilder private var installed: some View {
        Label("`bigbro` is installed", systemImage: "checkmark.circle")
            .foregroundStyle(.green)

        if allTerminals == .current {
            Text("/usr/local/bin/bigbro — on PATH in every shell.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("~/.local/bin/bigbro")
                .font(.caption).foregroundStyle(.secondary)
            if !userScopeIsOnPath {
                // Installed but unreachable looks exactly like installed, so say it
                // rather than letting "command not found" be the hint.
                Text(Self.notOnPathWarning)
                    .font(.caption).foregroundStyle(.orange)
                Button("Install for All Terminals…") { install(into: .allTerminals) }
            }
        }
    }

    @ViewBuilder private func repair(_ scope: CommandLineTool.Scope, pointingAt: String) -> some View {
        Button("Repair \(scope == .allTerminals ? "/usr/local/bin" : "~/.local/bin")") {
            install(into: scope)
        }
        Text("That `bigbro` points somewhere else (\(pointingAt)). BigBro was probably moved.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func install(into scope: CommandLineTool.Scope) {
        problem = nil
        do {
            try CommandLineTool.install(into: scope)
        } catch CommandLineTool.Failure.cancelled {
            // They said no. Not a failure to report in red.
        } catch {
            problem = error.localizedDescription
        }
        Task { await refresh() }
    }

    /// The PATH probe starts a login shell, so it stays off the main actor.
    private func refresh() async {
        let scopes = CommandLineTool.Scope.allCases
        statuses = Dictionary(uniqueKeysWithValues: scopes.map { ($0, CommandLineTool.status(for: $0)) })
        userScopeIsOnPath = await Task.detached {
            CommandLineTool.isOnPath(scope: .thisUser)
        }.value
    }
}

/// One of the two verbs on a row: fixed width, and a spinner while it is in flight.
///
/// The width is fixed rather than fitted for two reasons. A fitted button shrinks
/// when the window narrows until "Download" becomes "Downl…", and a verb you
/// cannot read is worse than a column that scrolls. And because these labels swap
/// as state changes — Start to Stop, Download to Delete — a fitted button would
/// also resize under the pointer between one render and the next.
@MainActor
struct ActionButton: View {
    /// Sized for "Download", the longest label the model rows produce.
    static let width: CGFloat = 88
    /// "Disconnect" is longer still.
    static let deviceWidth: CGFloat = 96

    let title: String
    var busy: Bool = false
    var enabled: Bool = true
    var width: CGFloat = ActionButton.width
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // The label stays in the layout while hidden, so the button does
                // not change size when the spinner replaces it.
                Text(title)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(busy ? 0 : 1)
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: width)
        .buttonStyle(.bordered)
        .controlSize(.small)
        // Disabled while in flight as well as when the verb does not apply, so a
        // second press cannot queue a command the first has not answered yet.
        .disabled(!enabled || busy)
    }
}
