import Foundation

struct RecordingSettings: Codable, Equatable, Sendable {
    static let clipDurations = Array(stride(from: 5, through: 60, by: 5))
        + Array(stride(from: 90, through: 180, by: 30))
        + Array(stride(from: 240, through: 600, by: 60))
        + Array(stride(from: 900, through: 3_600, by: 300))
    static let allowedIgnoredSeconds = 0...10
    static let audioBitrate = 128_000

    var audioEnabled = true
    var clipDuration = 30
    var ignoredSeconds = 2
    var quality = VideoQuality.fullHD
    var savedFrameRate: VideoFrameRate?

    var frameRate: VideoFrameRate {
        get { savedFrameRate ?? .maximum }
        set { savedFrameRate = newValue == .maximum ? nil : newValue }
    }
    var usesDiskReplayBuffer: Bool { clipDuration > 60 }

    var clipDurationIndex: Int {
        get { Self.clipDurations.firstIndex(of: clipDuration) ?? 0 }
        set {
            guard Self.clipDurations.indices.contains(newValue) else { return }
            clipDuration = Self.clipDurations[newValue]
        }
    }

    private static let storageKey = "recordingSettings"

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }

        if !clipDurations.contains(value.clipDuration) {
            value.clipDuration = clipDurations.last { $0 < value.clipDuration } ?? clipDurations[0]
        }
        value.ignoredSeconds = min(max(value.ignoredSeconds, allowedIgnoredSeconds.lowerBound), allowedIgnoredSeconds.upperBound)
        return value
    }

    func save(to defaults: UserDefaults) {
        if let encoded = try? JSONEncoder().encode(self) {
            defaults.set(encoded, forKey: Self.storageKey)
        }
    }
}

enum VideoFrameRate: Int32, Codable, CaseIterable, Sendable {
    case maximum = 0
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60
    case fps120 = 120
    case fps240 = 240

    var limit: Int32? { self == .maximum ? nil : rawValue }

    func matches(_ rate: Double) -> Bool {
        guard let limit else { return true }
        return abs(rate - Double(limit)) <= max(0.05, Double(limit) * 0.0011)
    }

    func isSupported(in ranges: [ClosedRange<Double>]) -> Bool {
        guard limit != nil, !ranges.isEmpty else { return true }
        return supportedRate(in: ranges).map(matches) ?? false
    }

    func supportedRate(in ranges: [ClosedRange<Double>]) -> Double? {
        guard let limit else { return ranges.map(\.upperBound).max() }
        let target = Double(limit)
        let upToTarget = ranges.filter { $0.lowerBound <= target }.map { min($0.upperBound, target) }
        return upToTarget.max() ?? ranges.map(\.lowerBound).min()
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

    func videoBitrate(frameRate: Double) -> Int {
        let bitrateAt30FPS: Int = switch self {
        case .hd: 3_500_000
        case .fullHD: 6_000_000
        case .ultraHD: 16_000_000
        }
        return Int((Double(bitrateAt30FPS) * frameRate / 30).rounded())
    }

    func estimatedBytes(durationSeconds: Int, includeAudio: Bool, frameRate: Double = 30) -> Int64 {
        let audioBitrate = includeAudio ? RecordingSettings.audioBitrate : 0
        return Int64(videoBitrate(frameRate: frameRate) + audioBitrate) * Int64(durationSeconds) / 8
    }
}
