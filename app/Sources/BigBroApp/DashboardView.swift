import BigBroControl
import SwiftUI

/// The seven panes the Textual dashboard had, as a sidebar.
///
/// The four model panes are one view parameterised by family, because the wire
/// already groups them that way — `models.list` returns a group per family, in
/// the daemon's order, and nothing here re-sorts it.
enum Pane: String, CaseIterable, Identifiable, Hashable {
    case devices, language, vision, tts, stt, settings, log

    var id: String { rawValue }

    var title: String {
        switch self {
        case .devices: return "Devices"
        case .language: return "Text"
        case .vision: return "Vision"
        case .tts: return "TTS"
        case .stt: return "STT"
        case .settings: return "Settings"
        case .log: return "Log"
        }
    }

    var symbol: String {
        switch self {
        case .devices: return "iphone"
        case .language: return "text.bubble"
        case .vision: return "eye"
        case .tts: return "waveform"
        case .stt: return "mic"
        case .settings: return "gearshape"
        case .log: return "list.bullet.rectangle"
        }
    }

    /// The catalog family this pane shows, if it shows models at all.
    var family: String? {
        switch self {
        case .language, .vision, .tts, .stt: return rawValue
        default: return nil
        }
    }
}

struct DashboardView: View {
    @Environment(AppState.self) private var state
    @State private var selection: Pane = .devices

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            Group {
                switch selection {
                case .devices: DevicesPane()
                case .settings: SettingsPane()
                case .log: LogPane()
                default: ModelPane(family: selection.family ?? "language")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) { StatusBar() }
        }
        .sheet(item: pairingBinding) { request in
            PairingSheet(request: request)
        }
        .alert(
            "The daemon stopped",
            isPresented: .constant(state.daemon.failure != nil && !state.daemon.isRunning),
            presenting: state.daemon.failure
        ) { _ in
            Button("Restart") { Task { await state.daemon.restart() } }
            Button("Dismiss", role: .cancel) {}
        } message: { failure in
            Text(failure)
        }
    }

    /// A sheet wants a Binding, but the prompt is owned by the model — dismissing
    /// has to go through `resolvePrompt` so the phone is told, rather than just
    /// clearing the sheet and leaving it waiting.
    private var pairingBinding: Binding<PendingRequest?> {
        Binding(
            get: { state.dashboard.prompt },
            set: { newValue in
                if newValue == nil, state.dashboard.prompt != nil {
                    Task { await state.dashboard.resolvePrompt(approved: false) }
                }
            }
        )
    }
}

struct StatusBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(state.dashboard.isAttached ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(state.statusLine)
                .font(.callout)
            Spacer()
            if let memory = state.dashboard.status?.memory {
                Text(memory.summary)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct PairingSheet: View {
    @Environment(AppState.self) private var state
    let request: PendingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(request.displayName) wants to pair")
                .font(.headline)

            if let app = request.appName, !app.isEmpty {
                LabeledContent("App", value: app)
            }
            LabeledContent("Device", value: request.deviceId)
            if !request.requiredModels.isEmpty {
                LabeledContent("Wants", value: request.requiredModels.joined(separator: ", "))
            }

            Text("Approving remembers this device. It will reconnect without asking again.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Deny") { Task { await state.dashboard.resolvePrompt(approved: false) } }
                    .keyboardShortcut(.cancelAction)
                Button("Approve") { Task { await state.dashboard.resolvePrompt(approved: true) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
