import Foundation

struct PairingRequest: Identifiable, Codable, Hashable {
    let id: String        // device_id
    let deviceName: String
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "device_id"
        case deviceName = "device_name"
        case receivedAt
    }
}

enum PairingStatus {
    case pending
    case approved(token: String)
    case denied
}
