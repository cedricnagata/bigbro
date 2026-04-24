import Foundation
import Combine

@MainActor
final class OllamaMonitor: ObservableObject {
    static let baseURL = "http://localhost:11434"

    enum Status { case unknown, running, unreachable }

    @Published var status: Status = .unknown
    @Published var installedModels: [String] = []

    private var pollTask: Task<Void, Never>?

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        do {
            let url = URL(string: "\(Self.baseURL)/api/tags")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                status = .unreachable
                installedModels = []
                return
            }
            status = .running
            installedModels = models.compactMap { $0["name"] as? String }
        } catch {
            status = .unreachable
            installedModels = []
        }
    }

    func isInstalled(_ model: String) -> Bool {
        installedModels.contains { $0 == model || $0.hasPrefix(model + ":") }
    }

    func missingModels(from required: [String]) -> [String] {
        required.filter { !isInstalled($0) }
    }
}
