import SwiftUI

@main
struct CourtReplayApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = RecordingModel()

    var body: some Scene {
        WindowGroup {
            RecordingView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.sceneDidEnterBackground() }
                }
        }
    }
}
