import Foundation

struct WatchReplayRequest: Codable, Sendable {
    let id: UUID
    let tappedAt: Date
}

struct WatchReplayReply: Codable, Sendable {
    enum Result: String, Codable, Sendable {
        case saving, saved, cameraUnavailable, busy, noFootage, cancelled, failed
    }

    static let deliveryKey = "replayReply"

    let id: UUID
    let result: Result
}
