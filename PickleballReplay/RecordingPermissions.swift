import SwiftUI

enum RecordingPermission: Equatable, Sendable {
    case camera
    case photos
}

struct RecordingPermissionPrompt: Equatable, Sendable {
    let camera: Bool
    let microphone: Bool
    let photos: Bool

    fileprivate var message: String {
        var reasons: [String] = []
        if camera { reasons.append("The camera keeps recent play ready to save.") }
        if microphone { reasons.append("Microphone access is optional and adds court sound to replays.") }
        if photos { reasons.append("Photos access lets Court Footage add the replays you save to your library.") }
        reasons.append(reasons.count > 1
                       ? "Continue to see the iPhone permission prompts."
                       : "Continue to see the iPhone permission prompt.")
        return reasons.joined(separator: " ")
    }
}

extension View {
    @MainActor
    func recordingPermissionPrompts(_ model: RecordingModel, enabled: Bool = true) -> some View {
        let prompt = enabled ? model.permissionPrompt : nil
        return alert(
            "Permissions for replays",
            isPresented: Binding(
                get: { enabled && model.permissionPrompt != nil },
                // SwiftUI can write false before invoking the button's action.
                // Let that action tell the model what should happen next.
                set: { _ in }
            ),
            presenting: prompt
        ) { _ in
            Button("Continue", action: model.continuePermissionPrompt)
        } message: { prompt in
            Text(prompt.message)
        }
    }
}
