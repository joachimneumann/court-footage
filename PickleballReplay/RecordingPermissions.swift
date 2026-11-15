import Foundation
import SwiftUI

enum RecordingPermission: Error, LocalizedError, Equatable, Sendable {
    case camera
    case microphone
    case photos

    fileprivate var title: String {
        switch self {
        case .camera: "Camera access is off"
        case .microphone: "Microphone access is off"
        case .photos: "Photos access is off"
        }
    }

    var errorDescription: String? {
        switch self {
        case .camera:
            "Turn on Camera for Court Footage in iPhone Settings to record replays."
        case .microphone:
            "Turn on Microphone in iPhone Settings to record court sound. You can also turn off Audio in Court Footage settings."
        case .photos:
            "Allow Court Footage to add videos to Photos in iPhone Settings to save replays."
        }
    }
}

enum RecordingPermissionPrompt: Equatable, Sendable {
    case explainStartup(camera: Bool, microphone: Bool, photos: Bool)
    case denied(RecordingPermission)

    fileprivate var title: String {
        switch self {
        case .explainStartup: "Permissions for replays"
        case .denied(let permission): permission.title
        }
    }

    fileprivate var message: String {
        switch self {
        case .explainStartup(let camera, let microphone, let photos):
            var reasons: [String] = []
            if camera { reasons.append("The camera keeps recent play ready to save.") }
            if microphone { reasons.append("The microphone captures court sound.") }
            if photos { reasons.append("Photos access lets Court Footage add the replays you save to your library.") }
            reasons.append(reasons.count > 1
                           ? "Continue to see the iPhone permission prompts."
                           : "Continue to see the iPhone permission prompt.")
            return reasons.joined(separator: " ")
        case .denied(let permission):
            return permission.localizedDescription
        }
    }
}

extension View {
    @MainActor
    func recordingPermissionPrompts(_ model: RecordingModel, enabled: Bool = true) -> some View {
        let prompt = enabled ? model.permissionPrompt : nil
        return alert(
            prompt?.title ?? "",
            isPresented: Binding(
                get: { enabled && model.permissionPrompt != nil },
                // SwiftUI can write false before invoking the button's action.
                // Let that action tell the model what should happen next.
                set: { _ in }
            ),
            presenting: prompt
        ) { prompt in
            switch prompt {
            case .explainStartup:
                Button("Continue", action: model.continuePermissionPrompt)
            case .denied:
                Button("Open iPhone Settings", action: model.openPermissionSettings)
                Button("Not now", role: .cancel, action: model.dismissPermissionPrompt)
            }
        } message: { prompt in
            Text(prompt.message)
        }
    }
}
