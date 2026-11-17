import SwiftUI

@main
struct CourtFootageApp: App {
    @State private var model = RecordingModel()

    var body: some Scene {
        WindowGroup {
            RecordingView(model: model)
                .task { model.connectWatch() }
        }
    }
}
