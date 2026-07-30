import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            DevicesSettingsTab()
                .tabItem { Label("Devices", systemImage: "iphone") }
        }
        .frame(width: 480)
        .padding()
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var preview = SpeechPreview()

    var body: some View {
        Form {
            Section {
                Picker("Text model", selection: $settings.textModelID) {
                    ForEach(ModelCatalog.language) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                Picker("Vision model", selection: $settings.visionModelID) {
                    ForEach(ModelCatalog.vision) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
            } header: {
                Text("Defaults")
            } footer: {
                Label(
                    "Used when a device doesn't name a model. Requests with images always use the vision model, whichever one was asked for.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }

            Section {
                ForEach(ModelCatalog.language) { model in
                    ModelRow(model: model)
                }
            } header: {
                Text("Language models")
            } footer: {
                Label(
                    "Models differ in what they can do — the badges say which. Tools and reasoning are quietly dropped for a model that lacks them, so a device asking for either gets an answer without them rather than an error.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }

            Section {
                ForEach(ModelCatalog.vision) { model in
                    ModelRow(model: model)
                }
            } header: {
                Text("Vision models")
            }

            Section {
                Toggle("Enable speech", isOn: $settings.speechEnabled)

                if settings.speechEnabled {
                    ForEach(SpeechEngine.ModelKind.allCases, id: \.self) { kind in
                        SpeechModelRow(kind: kind)
                    }

                    LabeledContent("Voice") {
                        HStack(spacing: 6) {
                            // Free-form rather than a closed list: FluidAudio does not
                            // expose an enumerable voice list the way it does for models.
                            TextField("", text: $settings.ttsVoice)
                                .labelsHidden()
                                .frame(maxWidth: .infinity)

                            Button(preview.isSynthesizing ? "…" : "Preview") {
                                preview.play(voice: settings.ttsVoice)
                            }
                            .disabled(preview.isSynthesizing || settings.ttsVoice.isEmpty)
                        }
                    }

                    Text("Which Kokoro speaker to use, e.g. `af_heart`, `am_adam`, `bf_emma`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let error = preview.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Speech")
            } footer: {
                Label(
                    "Text-to-speech (Kokoro) and transcription (Parakeet), both on-device via FluidAudio.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
        .formStyle(.grouped)
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

    var body: some View {
        let loaded = mlxEngine.isLoaded(model.id)
        let downloaded = mlxEngine.isDownloaded(model.id)
        let progress = modelDownloader.progress[model.id]

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: loaded ? "checkmark.circle.fill" : (progress != nil ? "arrow.down.circle" : (downloaded ? "checkmark.circle" : "arrow.down.circle.dotted")))
                    .foregroundStyle(loaded ? .green : (progress != nil ? .blue : (downloaded ? .green : .secondary)))
                Text(model.displayName)
                Text(String(format: "%.1f GB", model.approximateGB))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if !downloaded && progress == nil {
                    Button("Download") {
                        modelDownloader.startDownload(model.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            CapabilityBadges(model: model)

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
            } else if downloaded && !loaded {
                Text("Downloaded — loads on first use")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// What a model can and cannot do, at a glance.
private struct CapabilityBadges: View {
    let model: BigBroModel

    var body: some View {
        HStack(spacing: 4) {
            badge("Tools", "wrench.and.screwdriver", on: model.supportsTools)
            badge("Images", "photo", on: model.supportsImages)
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

    private func badge(_ text: String, _ icon: String, on: Bool) -> some View {
        Label(text, systemImage: on ? icon : "\(icon).badge.ellipsis")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(on ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .clipShape(Capsule())
            .opacity(on ? 1 : 0.65)
    }
}

/// One row per speech model (Kokoro, Parakeet): its download/load state, and a button to
/// fetch it. Mirrors `ModelRow`, but tracks state on `SpeechEngine` directly rather than
/// through `ModelDownloader` — speech models aren't part of the wire protocol's
/// required-model handshake, so there's no peer-facing download to coordinate.
private struct SpeechModelRow: View {
    @EnvironmentObject var speechEngine: SpeechEngine
    let kind: SpeechEngine.ModelKind

    var body: some View {
        let loaded = speechEngine.isLoaded(kind)
        let downloaded = speechEngine.isDownloaded(kind)
        let progress = speechEngine.loadProgress[kind]
        let error = speechEngine.loadErrors[kind]
        let downloading = !loaded && error == nil && progress != nil

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: loaded ? "checkmark.circle.fill" : (downloading ? "arrow.down.circle" : (downloaded ? "checkmark.circle" : "xmark.circle.fill")))
                    .foregroundStyle(loaded ? .green : (downloading ? .blue : (downloaded ? .green : .red)))
                Text(kind.displayName)
                Spacer(minLength: 8)
                if !loaded && !downloading {
                    Button("Download") {
                        Task { try? await speechEngine.ensureLoaded(kind) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if let error {
                Text("Error: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if downloading, let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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
