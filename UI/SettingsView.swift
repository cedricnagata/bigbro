import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            DevicesSettingsTab()
                .tabItem { Label("Devices", systemImage: "iphone") }
        }
        // Sized for the General tab, which is the crowded one: fifteen model rows, each with
        // a name, size, capability badges, status line and up to two buttons. At the old
        // 480pt the buttons wrapped under the badges and every row needed two lines.
        //
        // `ideal` rather than a fixed `width`/`height`, so the window opens roomy but stays
        // resizable; `min` stops it being dragged narrow enough to wrap the rows again.
        .frame(
            minWidth: 620, idealWidth: 780,
            minHeight: 480, idealHeight: 680
        )
        .padding()
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var mlxEngine: MLXEngine
    @EnvironmentObject private var speechEngine: SpeechEngine

    // Persisted rather than @State: which sections you care about is a stable preference, and
    // re-collapsing eleven language models on every launch would be its own annoyance. All
    // open by default — nothing is hidden until the user decides to hide it.
    @AppStorage("bigbro.settings.languageExpanded") private var languageExpanded = true
    @AppStorage("bigbro.settings.visionExpanded") private var visionExpanded = true
    @AppStorage("bigbro.settings.ttsExpanded") private var ttsExpanded = true
    @AppStorage("bigbro.settings.sttExpanded") private var sttExpanded = true

    var body: some View {
        Form {
            Section(isExpanded: $languageExpanded) {
                ForEach(ModelCatalog.language) { model in
                    ModelRow(model: model)
                }
            } header: {
                SectionHeader(title: "Language models", subtitle: summary(for: ModelCatalog.language))
            }

            Section(isExpanded: $visionExpanded) {
                ForEach(ModelCatalog.vision) { model in
                    ModelRow(model: model)
                }
            } header: {
                SectionHeader(title: "Vision models", subtitle: summary(for: ModelCatalog.vision))
            }

            Section(isExpanded: $ttsExpanded) {
                VoiceModelRow(kind: .tts)
            } header: {
                SectionHeader(title: "TTS models", subtitle: summary(for: .tts))
            }

            Section(isExpanded: $sttExpanded) {
                VoiceModelRow(kind: .stt)
            } header: {
                SectionHeader(title: "STT models", subtitle: summary(for: .stt))
            }
        }
        .formStyle(.grouped)
    }

    /// One line of state for a collapsed section, so folding it away doesn't also hide whether
    /// anything in it is running.
    private func summary(for models: [BigBroModel]) -> String {
        let running = models.filter { mlxEngine.isRunning($0.id) }.count
        let downloaded = models.filter { mlxEngine.isDownloaded($0.id) }.count
        if downloaded == 0 { return "none downloaded" }
        if running == 0 { return "\(downloaded) downloaded" }
        return "\(downloaded) downloaded, \(running) running"
    }

    private func summary(for kind: SpeechEngine.ModelKind) -> String {
        switch speechEngine.state(kind) {
        case .notDownloaded, .downloading: return "not downloaded"
        case .downloaded, .starting, .failed: return "downloaded"
        case .running: return "downloaded, running"
        }
    }
}

/// A section title with a state summary beside it. The disclosure control comes from
/// `Section(isExpanded:)` itself, so there is deliberately no chevron here to duplicate it.
private struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("· \(subtitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One row per catalog model: what it can do, its download/load state, and a button to fetch
/// it.
///
/// The capability badges are the point of the row. Which model is selected changes whether
/// tool calls and reasoning work at all, and that difference is invisible at request time —
/// an unsupported tool is dropped, not refused — so it has to be legible here instead.
private struct ModelRow: View {
    @EnvironmentObject var mlxEngine: MLXEngine
    @EnvironmentObject var modelDownloader: ModelDownloader
    let model: BigBroModel

    @State private var confirmingRemove = false
    @State private var actionError: String?

    var body: some View {
        let state = mlxEngine.state(model.id)
        let progress = modelDownloader.progress[model.id]

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon(for: state))
                    .foregroundStyle(tint(for: state))
                Text(model.displayName)
                Text(String(format: "%.1f GB", model.approximateGB))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                actions(for: state)
            }

            CapabilityBadges(model: model)

            if let progress, progress.error == nil, !progress.done {
                ProgressView(value: progress.percent)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                Text("\(progress.status) — \(Int((progress.percent * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(statusLine(for: state))
                    .font(.caption2)
                    .foregroundStyle(state.isFailed ? .red : .secondary)
            }

            if let actionError {
                Text(actionError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "Remove \(model.displayName)?",
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove Download", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes about \(String(format: "%.1f", model.approximateGB)) GB from disk. Using this model again re-downloads it.")
        }
    }

    /// Four operations, but never all at once — which apply depends entirely on where the
    /// model is, and offering "Stop" for something that isn't running is just noise.
    @ViewBuilder
    private func actions(for state: MLXEngine.ModelRunState) -> some View {
        switch state {
        case .notDownloaded:
            Button("Download") { modelDownloader.startDownload(model.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)

        case .downloading, .starting:
            ProgressView().controlSize(.small)

        case .downloaded, .failed:
            HStack(spacing: 6) {
                Button("Run") { run() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Remove") { confirmingRemove = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

        case .running:
            HStack(spacing: 6) {
                Button("Stop") { mlxEngine.stop(model.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Remove") { confirmingRemove = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func run() {
        actionError = nil
        Task {
            do { try await mlxEngine.run(model) }
            catch { actionError = error.localizedDescription }
        }
    }

    private func remove() {
        actionError = nil
        do { try mlxEngine.remove(model) }
        catch { actionError = "Could not remove: \(error.localizedDescription)" }
    }

    private func statusLine(for state: MLXEngine.ModelRunState) -> String {
        switch state {
        case .notDownloaded:       return "Not downloaded"
        case .downloading:         return "Downloading…"
        case .downloaded:          return "Downloaded — not using memory. Starts on first use."
        case .starting:            return "Starting — loading weights into memory"
        case .running:             return "Running — in memory, answers immediately"
        case .failed(let message): return "Error: \(message)"
        }
    }

    private func icon(for state: MLXEngine.ModelRunState) -> String {
        switch state {
        case .notDownloaded:            return "circle.dotted"
        case .downloading, .starting:   return "arrow.down.circle"
        case .downloaded:               return "internaldrive"
        case .running:                  return "bolt.circle.fill"
        case .failed:                   return "exclamationmark.circle.fill"
        }
    }

    private func tint(for state: MLXEngine.ModelRunState) -> Color {
        switch state {
        case .notDownloaded:            return .secondary
        case .downloading, .starting:   return .blue
        case .downloaded:               return .secondary
        case .running:                  return .green
        case .failed:                   return .red
        }
    }
}

extension MLXEngine.ModelRunState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// What a model can and cannot do, at a glance.
private struct CapabilityBadges: View {
    let model: BigBroModel

    var body: some View {
        HStack(spacing: 4) {
            badge(model.supportsTools ? "Tools" : "No tools",
                  "wrench.and.screwdriver", on: model.supportsTools)
            badge(model.supportsImages ? "Images" : "Text only",
                  "photo", on: model.supportsImages)
            badge(reasoningLabel, "brain", on: model.reasoning.producesTrace)
        }
    }

    private var reasoningLabel: String {
        switch model.reasoning {
        case .none:                        return "No reasoning"
        case .harmony:                     return "Reasoning (low/med/high)"
        case .thinkTags(let togglable):    return togglable ? "Reasoning (on/off)" : "Always reasons"
        }
    }

    /// The same symbol either way, with the label carrying the negation.
    ///
    /// An earlier version derived an "off" symbol by appending `.badge.ellipsis` to the base
    /// name. That is not a real variant of most symbols — `photo.badge.ellipsis` and
    /// `wrench.and.screwdriver.badge.ellipsis` don't exist — and a missing symbol logs and
    /// renders as blank rather than failing the build. Only names written out in full are used
    /// here now.
    private func badge(_ text: String, _ icon: String, on: Bool) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(on ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .clipShape(Capsule())
            .opacity(on ? 1 : 0.6)
    }
}

/// One row per speech model kind (Kokoro, Parakeet): its lifecycle state, and buttons to
/// download / run / stop / remove it. Mirrors `ModelRow`, but tracks state on `SpeechEngine`
/// directly rather than through `ModelDownloader` — speech models aren't part of the wire
/// protocol's required-model handshake, so there's no peer-facing download to coordinate.
private struct VoiceModelRow: View {
    @EnvironmentObject var speechEngine: SpeechEngine
    let kind: SpeechEngine.ModelKind

    @State private var confirmingRemove = false
    @State private var actionError: String?

    var body: some View {
        let state = speechEngine.state(kind)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon(for: state))
                    .foregroundStyle(tint(for: state))
                Text(kind.displayName)
                Spacer(minLength: 8)
                actions(for: state)
            }

            if case .downloading(let progress) = state {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                Text("Downloading — \(Int((progress * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(statusLine(for: state))
                    .font(.caption2)
                    .foregroundStyle(state.isFailed ? .red : .secondary)
            }

            if let actionError {
                Text(actionError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "Remove \(kind.displayName)?",
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove Download", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Using \(kind.displayName) again re-downloads it.")
        }
    }

    /// Four operations, but never all at once — which apply depends entirely on where the
    /// model is, and offering "Stop" for something that isn't running is just noise.
    @ViewBuilder
    private func actions(for state: SpeechEngine.ModelRunState) -> some View {
        switch state {
        case .notDownloaded:
            Button("Download") { download() }
                .buttonStyle(.bordered)
                .controlSize(.small)

        case .downloading, .starting:
            ProgressView().controlSize(.small)

        case .downloaded, .failed:
            HStack(spacing: 6) {
                Button("Run") { run() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Remove") { confirmingRemove = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

        case .running:
            HStack(spacing: 6) {
                Button("Stop") { speechEngine.stop(kind) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Remove") { confirmingRemove = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func download() {
        actionError = nil
        Task {
            do { try await speechEngine.download(kind) }
            catch { actionError = error.localizedDescription }
        }
    }

    private func run() {
        actionError = nil
        Task {
            do { try await speechEngine.run(kind) }
            catch { actionError = error.localizedDescription }
        }
    }

    private func remove() {
        actionError = nil
        do { try speechEngine.remove(kind) }
        catch { actionError = "Could not remove: \(error.localizedDescription)" }
    }

    private func statusLine(for state: SpeechEngine.ModelRunState) -> String {
        switch state {
        case .notDownloaded:       return "Not downloaded"
        case .downloading:         return "Downloading…"
        case .downloaded:          return "Downloaded — not using memory. Starts on first use."
        case .starting:            return "Starting — loading weights into memory"
        case .running:             return "Running — in memory, answers immediately"
        case .failed(let message): return "Error: \(message)"
        }
    }

    private func icon(for state: SpeechEngine.ModelRunState) -> String {
        switch state {
        case .notDownloaded:            return "circle.dotted"
        case .downloading, .starting:   return "arrow.down.circle"
        case .downloaded:               return "internaldrive"
        case .running:                  return "bolt.circle.fill"
        case .failed:                   return "exclamationmark.circle.fill"
        }
    }

    private func tint(for state: SpeechEngine.ModelRunState) -> Color {
        switch state {
        case .notDownloaded:            return .secondary
        case .downloading, .starting:   return .blue
        case .downloaded:               return .secondary
        case .running:                  return .green
        case .failed:                   return .red
        }
    }
}

extension SpeechEngine.ModelRunState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Devices

private struct DevicesSettingsTab: View {
    @EnvironmentObject var pairingManager: PairingManager
    @State private var confirmRemoveAll = false

    var body: some View {
        Form {
            Section("Paired Devices") {
                if pairingManager.approvedDevices.isEmpty {
                    Text("No paired devices")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pairingManager.approvedDevices.sorted(), id: \.self) { deviceId in
                        DeviceRow(deviceId: deviceId)
                    }
                }
            }

            if !pairingManager.approvedDevices.isEmpty {
                Section {
                    HStack {
                        Button("Refresh") {
                            pairingManager.refreshAll()
                        }
                        Spacer()
                        Button("Remove All", role: .destructive) {
                            confirmRemoveAll = true
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove all paired devices?",
            isPresented: $confirmRemoveAll,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) {
                pairingManager.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All paired devices will need to pair again to use BigBro.")
        }
    }
}

private struct DeviceRow: View {
    @EnvironmentObject var pairingManager: PairingManager
    @EnvironmentObject var mlxEngine: MLXEngine
    @EnvironmentObject var modelDownloader: ModelDownloader
    let deviceId: String

    var body: some View {
        let connected = pairingManager.connectedDeviceIds.contains(deviceId)
        let requiredModels = pairingManager.deviceRequiredModels[deviceId] ?? []
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 10, height: 10)
                .padding(.top, 4)
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(pairingManager.displayName(for: deviceId))
                    .lineLimit(1)
                Text(connected ? "Connected" : "Disconnected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if connected && !requiredModels.isEmpty {
                    ForEach(requiredModels, id: \.self) { model in
                        DeviceModelStatusRow(model: model)
                    }
                }
            }
            Spacer()
            VStack(spacing: 6) {
                if connected {
                    Button("Disconnect") {
                        pairingManager.disconnect(deviceId: deviceId)
                    }
                    .buttonStyle(.bordered)
                }
                Button("Remove") {
                    pairingManager.remove(deviceId: deviceId)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
    }
}

/// A model a device declared it needs, shown against the catalog entry it resolves to.
///
/// The two can differ: clients predate the catalog and send Ollama-style tags, so
/// `qwen3-vl:30b` resolves to whichever Qwen VL model is actually available. A name matching
/// nothing resolves to nil and is shown as unrecognized rather than offered for download,
/// since there is nothing to pull.
private struct DeviceModelStatusRow: View {
    @EnvironmentObject var mlxEngine: MLXEngine
    @EnvironmentObject var modelDownloader: ModelDownloader
    let model: String

    private var resolved: BigBroModel? { ModelCatalog.resolve(model) }

    var body: some View {
        let satisfied = mlxEngine.isRequiredModelSatisfied(model)
        let progress = resolved.flatMap { modelDownloader.progress[$0.id] }
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: satisfied ? "checkmark.circle.fill" : (progress != nil ? "arrow.down.circle" : "xmark.circle.fill"))
                    .foregroundStyle(satisfied ? .green : (progress != nil ? .blue : .red))
                Text(resolved.map { "\(model) → \($0.displayName)" } ?? "\(model) — not a model BigBro knows")
                    .font(.caption)
                Spacer(minLength: 8)
                if let resolved, !satisfied, progress == nil {
                    Button("Download") {
                        modelDownloader.startDownload(resolved.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            if let progress {
                if let err = progress.error {
                    Text("Error: \(err)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else {
                    ProgressView(value: progress.percent)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                    Text("\(progress.status) — \(Int((progress.percent * 100).rounded()))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
