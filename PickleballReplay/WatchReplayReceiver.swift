@preconcurrency import WatchConnectivity

@MainActor
final class WatchReplayReceiver: NSObject, WCSessionDelegate {
    private let save: (WatchReplayRequest) -> WatchReplayReply.Result

    init(save: @escaping (WatchReplayRequest) -> WatchReplayReply.Result) {
        self.save = save
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func report(_ result: WatchReplayReply.Result, for id: UUID?) {
        guard let id, let data = try? JSONEncoder().encode(WatchReplayReply(id: id, result: result)) else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessageData(data, replyHandler: nil) { _ in
                Self.deliverWhenReachable(data)
            }
        } else {
            Self.deliverWhenReachable(data)
        }
    }

    // A long export can finish after the player lowers their wrist.
    private nonisolated static func deliverWhenReachable(_ data: Data) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        session.transferUserInfo([WatchReplayReply.deliveryKey: data])
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData data: Data,
                             replyHandler: @escaping @Sendable (Data) -> Void) {
        guard let request = try? JSONDecoder().decode(WatchReplayRequest.self, from: data) else {
            replyHandler(Data())
            return
        }

        Task { @MainActor [weak self] in
            let result = self?.save(request) ?? .cameraUnavailable
            let reply = WatchReplayReply(id: request.id, result: result)
            replyHandler((try? JSONEncoder().encode(reply)) ?? Data())
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
