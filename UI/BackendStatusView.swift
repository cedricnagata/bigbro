import SwiftUI

/// Renders one backend's reachability: a coloured dot, a status line, and — when the backend
/// is running and has detail to show — an expandable list.
///
/// Generic over the monitor so every backend shares a single view; all backend-specific copy
/// arrives through `BackendStatusReporting`.
struct BackendStatusView<Monitor: BackendStatusReporting>: View {
    @ObservedObject var monitor: Monitor
    @State private var expanded = false

    var body: some View {
        if monitor.status == .running && !monitor.detailItems.isEmpty {
            VStack(alignment: .trailing, spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text(statusText)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if expanded {
                    ForEach(monitor.detailItems, id: \.self) { item in
                        Text(item)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 1)
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .foregroundStyle(monitor.status == .unreachable ? .red : .primary)
            }
        }
    }

    private var statusColor: Color {
        switch monitor.status {
        case .disabled:    return .secondary
        case .unknown:     return .secondary
        case .running:     return .green
        case .unreachable: return .red
        }
    }

    private var statusText: String {
        switch monitor.status {
        case .disabled:    return "Off"
        case .unknown:     return "Checking…"
        case .running:     return monitor.runningSummary
        case .unreachable: return monitor.unreachableHint
        }
    }
}
