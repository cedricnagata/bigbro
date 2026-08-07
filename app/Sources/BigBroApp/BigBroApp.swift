import BigBroControl
import SwiftUI

/// Holds the pieces that outlive any window: the daemon, the socket client, the
/// event pump, and the model every pane reads.
@Observable
@MainActor
final class AppState {
    let client: ControlClient
    let dashboard: DashboardModel
    let daemon: DaemonController

    private var pump: Task<Void, Never>?

    init() {
        let client = ControlClient()
        self.client = client
        self.dashboard = DashboardModel(transport: client)
        self.daemon = DaemonController(client: client)
    }

    func begin() async {
        await daemon.startOrAttach()
        guard pump == nil else { return }
        // One stream for the lifetime of the app. It reconnects on its own, so a
        // daemon that is restarted underneath us reattaches without anything here
        // having to notice.
        let events = client.events()
        pump = Task { @MainActor [dashboard] in
            for await event in events {
                await dashboard.handle(event)
            }
        }
    }

    func end() async {
        pump?.cancel()
        pump = nil
        await daemon.stop()
    }

    var statusLine: String {
        if let failure = daemon.failure { return failure }
        guard let status = dashboard.status else {
            return daemon.isRunning ? "Starting…" : "Not running"
        }
        let devices = status.connected.count == 1 ? "1 device" : "\(status.connected.count) devices"
        return "\(status.name) · port \(status.port) · \(devices) connected"
    }
}

@main
struct BigBroApp: App {
    @State private var state = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("BigBro", id: "dashboard") {
            DashboardView()
                .environment(state)
                .frame(minWidth: 820, minHeight: 480)
                .task { await state.begin() }
        }
        .defaultSize(width: 940, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // The daemon is a background service, so the menu bar — not a window — is
        // where it lives day to day. A pairing request has to be answerable
        // without hunting for a window that may be behind everything else.
        MenuBarExtra("BigBro", systemImage: state.dashboard.isAttached ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash") {
            MenuBarContent(openDashboard: { openWindow(id: "dashboard") })
                .environment(state)
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppState.self) private var state
    let openDashboard: () -> Void

    var body: some View {
        Text(state.statusLine)

        if let prompt = state.dashboard.prompt {
            Divider()
            Text("\(prompt.displayName) wants to pair")
            Button("Approve") { Task { await state.dashboard.resolvePrompt(approved: true) } }
            Button("Deny") { Task { await state.dashboard.resolvePrompt(approved: false) } }
        }

        Divider()
        let running = state.dashboard.groups
            .flatMap(\.models)
            .filter { $0.state.hasPrefix("running") }
        if running.isEmpty {
            Text("No models running")
        } else {
            ForEach(running) { model in
                Button("Stop \(model.name)") { Task { await state.dashboard.stop(model.id) } }
            }
        }

        Divider()
        Button("Open Dashboard") { openDashboard() }
        if state.daemon.canStop {
            Button("Stop Daemon") { Task { await state.daemon.stop() } }
        } else if !state.daemon.isRunning {
            Button("Start Daemon") { Task { await state.daemon.startOrAttach() } }
        }
        Button("Quit BigBro") {
            Task {
                await state.end()
                NSApplication.shared.terminate(nil)
            }
        }
        .keyboardShortcut("q")
    }
}
