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
    @EnvironmentObject var ollamaMonitor: OllamaMonitor
    @EnvironmentObject var speechMonitor: SpeechMonitor
    @StateObject private var preview = SpeechPreview()

    var body: some View {
        Form {
            Section {
                LabeledContent(AppSettings.chatBaseURL) {
                    BackendStatusView(monitor: ollamaMonitor)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                LabeledContent("Default Model") {
                    Picker("Default Model", selection: $settings.defaultModel) {
                        if !ollamaMonitor.installedModels.contains(settings.defaultModel) {
                            Text(settings.defaultModel).tag(settings.defaultModel)
                            Divider()
                        }
                        ForEach(ollamaMonitor.installedModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .disabled(ollamaMonitor.installedModels.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } header: {
                Text("Text Generation")
            } footer: {
                Label("Default model is used when the iOS app doesn't specify one.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                Toggle("Enable speech", isOn: $settings.speechEnabled)

                if settings.speechEnabled {
                    LabeledContent(AppSettings.speechBaseURL) {
                        BackendStatusView(monitor: speechMonitor)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    LabeledContent("Voice") {
                        HStack(spacing: 6) {
                            // Free-form rather than a closed list: voice names are not
                            // standardised across backends (af_heart vs alloy vs
                            // en_US-amy-medium), and not every backend can list them.
                            TextField("", text: $settings.ttsVoice)
                                .labelsHidden()
                                .frame(maxWidth: .infinity)

                            if !speechMonitor.availableVoices.isEmpty {
                                Menu("Choose") {
                                    ForEach(speechMonitor.availableVoices, id: \.self) { voice in
                                        Button(voice) { settings.ttsVoice = voice }
                                    }
                                }
                                .fixedSize()
                            }

                            Button(preview.isSynthesizing ? "…" : "Preview") {
                                preview.play(voice: settings.ttsVoice)
                            }
                            .disabled(preview.isSynthesizing || speechMonitor.status != .running)
                        }
                    }

                    LabeledContent("Speech Model") {
                        TextField("", text: $settings.ttsModel)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    LabeledContent("Audio Format") {
                        Picker("Audio Format", selection: $settings.ttsFormat) {
                            ForEach(["pcm", "wav", "mp3", "opus", "flac"], id: \.self) { format in
                                Text(format).tag(format)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    LabeledContent("Transcription Model") {
                        TextField("", text: $settings.sttModel)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

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
                    "Text-to-speech and transcription. Requires a server exposing /v1/audio/speech — LocalAI (port 8080) or Speaches (8000).",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
        .formStyle(.grouped)
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
    @EnvironmentObject var ollamaMonitor: OllamaMonitor
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
                        ModelStatusRow(model: model)
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

private struct ModelStatusRow: View {
    @EnvironmentObject var ollamaMonitor: OllamaMonitor
    @EnvironmentObject var modelDownloader: ModelDownloader
    let model: String

    var body: some View {
        let installed = ollamaMonitor.isInstalled(model)
        let progress = modelDownloader.progress[model]
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: installed ? "checkmark.circle.fill" : (progress != nil ? "arrow.down.circle" : "xmark.circle.fill"))
                    .foregroundStyle(installed ? .green : (progress != nil ? .blue : .red))
                Text(model)
                    .font(.caption)
                Spacer(minLength: 8)
                if !installed && progress == nil {
                    Button("Download") {
                        modelDownloader.startDownload(model)
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
                    Text(progressLabel(progress))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func progressLabel(_ p: ModelDownloader.Progress) -> String {
        if p.bytesTotal > 0 {
            let pct = Int((p.percent * 100).rounded())
            return "\(p.status) — \(pct)% (\(formatBytes(p.bytesCompleted))/\(formatBytes(p.bytesTotal)))"
        }
        return p.status
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
