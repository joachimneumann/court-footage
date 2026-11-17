import SwiftUI
@preconcurrency import WatchConnectivity
import WatchKit

@main
struct CourtFootageWatchApp: App {
    @State private var remote = WatchReplayRemote()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 10) {
                        Button(action: remote.save) {
                            Label(remote.isSaving ? "Saving…" : "Save Replay", systemImage: "arrow.down.to.line")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.78, green: 0.97, blue: 0.41))
                        .foregroundStyle(.black)
                        .disabled(!remote.isReachable || remote.isSaving)
                        .accessibilityIdentifier("watchSaveReplay")

                        Text(remote.feedback ?? (remote.isReachable
                            ? "Saves to Photos on your iPhone." : "Open Court Footage on your iPhone."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("watchSaveStatus")
                    }
                    .padding(.horizontal, 5)
                }
                .navigationTitle("Court Footage")
            }
            .task { remote.activate() }
        }
    }
}

@MainActor
@Observable
private final class WatchReplayRemote: NSObject, WCSessionDelegate {
    private(set) var isReachable = false
    private(set) var isSaving = false
    private(set) var feedback: LocalizedStringKey?

    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var receivedResult = false
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        updateReachability()
    }

    func save() {
        guard isReachable, !isSaving else { return }
        let request = WatchReplayRequest(id: UUID(), tappedAt: .now)
        guard let data = try? JSONEncoder().encode(request) else { return }
        requestID = request.id
        receivedResult = false
        isSaving = true
        feedback = nil

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            self?.didLoseConfirmation(for: request.id)
        }
        WCSession.default.sendMessageData(data) { [weak self] data in
            guard let reply = try? JSONDecoder().decode(WatchReplayReply.self, from: data) else {
                Task { @MainActor in self?.didLoseConfirmation(for: request.id) }
                return
            }
            Task { @MainActor in self?.receive(reply) }
        } errorHandler: { [weak self] _ in
            Task { @MainActor in self?.didLoseConfirmation(for: request.id) }
        }
    }

    private func receive(_ reply: WatchReplayReply) {
        guard requestID == reply.id, !receivedResult, reply.result != .saving else { return }
        timeoutTask?.cancel()
        receivedResult = true
        isSaving = false
        feedback = switch reply.result {
        case .saving: nil
        case .saved: "Saved to Photos"
        case .cameraUnavailable: "Open Court Footage on your iPhone."
        case .busy: "The iPhone is saving another clip. Try again in a moment."
        case .noFootage: "The camera is still collecting footage. Try again in a moment."
        case .cancelled: "Save canceled. Keep Court Footage open on your iPhone."
        case .failed: "Couldn’t save. Check Court Footage on your iPhone."
        }
        WKInterfaceDevice.current().play(reply.result == .saved ? .success : .failure)
    }

    private func didLoseConfirmation(for id: UUID) {
        guard requestID == id, !receivedResult else { return }
        timeoutTask?.cancel()
        isSaving = false
        feedback = "Check Photos on your iPhone."
        updateReachability()
    }

    private func updateReachability() {
        let session = WCSession.default
        isReachable = session.activationState == .activated && session.isReachable
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {
        Task { @MainActor [weak self] in self?.updateReachability() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.updateReachability() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData data: Data) {
        guard let reply = try? JSONDecoder().decode(WatchReplayReply.self, from: data) else { return }
        Task { @MainActor [weak self] in self?.receive(reply) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let data = userInfo[WatchReplayReply.deliveryKey] as? Data {
            self.session(session, didReceiveMessageData: data)
        }
    }
}
