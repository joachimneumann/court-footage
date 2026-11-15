import Foundation

struct RecordingSettings: Codable, Equatable, Sendable {
    static let allowedDurations = 5...60
    static let clipDurationStep = 5
    static let allowedIgnoredSeconds = 0...10
    static let audioBitrate = 128_000

    var audioEnabled = true
    var clipDuration = 30
    var ignoredSeconds = 2
    var quality = VideoQuality.fullHD

    private static let storageKey = "recordingSettings"

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }

        let boundedDuration = min(max(value.clipDuration, allowedDurations.lowerBound), allowedDurations.upperBound)
        value.clipDuration = (boundedDuration + clipDurationStep / 2) / clipDurationStep * clipDurationStep
        value.ignoredSeconds = min(max(value.ignoredSeconds, allowedIgnoredSeconds.lowerBound), allowedIgnoredSeconds.upperBound)
        return value
    }

    func save(to defaults: UserDefaults) {
        if let encoded = try? JSONEncoder().encode(self) {
            defaults.set(encoded, forKey: Self.storageKey)
        }
    }
}

enum VideoQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case hd, fullHD, ultraHD

    var id: Self { self }

    var title: String {
        switch self {
        case .hd: "720p HD"
        case .fullHD: "1080p Full HD"
        case .ultraHD: "4K Ultra HD"
        }
    }

    var videoBitrate: Int {
        switch self {
        case .hd: 3_500_000
        case .fullHD: 6_000_000
        case .ultraHD: 16_000_000
        }
    }

    func estimatedBytes(durationSeconds: Int, includeAudio: Bool) -> Int64 {
        let audioBitrate = includeAudio ? RecordingSettings.audioBitrate : 0
        return Int64(videoBitrate + audioBitrate) * Int64(durationSeconds) / 8
    }
}
