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
                    Menu("") {
                        Button("Disconnect") {
                            Task { await state.dashboard.disconnect(deviceId: device.deviceId) }
                        }
                        Button("Forget", role: .destructive) {
                            Task { await state.dashboard.forget(deviceId: device.deviceId) }
                        }
                    }
                }
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
            TableColumn("") { model in
                HStack {
                    if model.state.hasPrefix("not downloaded") {
                        Button("Download") { Task { await state.dashboard.download(model.id) } }
                    } else if model.state.hasPrefix("running") {
                        Button("Stop") { Task { await state.dashboard.stop(model.id) } }
                    } else if model.state.hasPrefix("downloaded") {
                        Button("Start") { Task { await state.dashboard.start(model.id) } }
                    }
                    Menu("") {
                        Button("Delete Weights", role: .destructive) { confirmingDelete = model }
                            .disabled(model.state.hasPrefix("not downloaded"))
                    }
                }
            }
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
                if !state.daemon.canStop && state.daemon.isRunning {
                    Text("This daemon was started elsewhere, so BigBro will not stop it.")
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
    @State private var status = CommandLineTool.status()
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch status {
            case .notInstalled:
                Button("Install Command Line Tool") { install() }
                Text("Adds `bigbro` to ~/.local/bin, so the CLI drives this same daemon.")
                    .font(.caption).foregroundStyle(.secondary)

            case .current:
                Label("`bigbro` is installed", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                if !CommandLineTool.destinationIsOnPath() {
                    // Installed but unreachable looks exactly like installed, so
                    // say it rather than letting "command not found" be the hint.
                    Text("~/.local/bin is not on your PATH — add it to your shell profile.")
                        .font(.caption).foregroundStyle(.orange)
                }

            case .stale(let pointingAt):
                Button("Repair Command Line Tool") { install() }
                Text("The installed `bigbro` points somewhere else (\(pointingAt)). BigBro was probably moved.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func install() {
        problem = nil
        guard CommandLineTool.bundledInterpreter() != nil else {
            problem = "This build has no bundled runtime, so there is nothing to point a shim at."
            return
        }
        do {
            try CommandLineTool.install()
            status = CommandLineTool.status()
        } catch {
            problem = "Could not write the shim: \(error.localizedDescription)"
        }
    }
}
