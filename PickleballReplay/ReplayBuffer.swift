import AVFoundation
import CoreGraphics
import Foundation

enum ReplayMediaSample: @unchecked Sendable {
    enum Timing {
        case video(CMSampleTimingInfo, [CMSampleBuffer.PerSampleAttachmentsDictionary.Element])
        case audio(start: CMTime, sampleCount: Int)
    }

    // Memory samples have an owned header that is never mutated after insertion.
    case memory(CMSampleBuffer)
    case disk(ReplayDiskStorage.Location, CMFormatDescription, Timing)

    var formatDescription: CMFormatDescription? {
        switch self {
        case .memory(let buffer): buffer.formatDescription
        case .disk(_, let format, _): format
        }
    }

    func load(using reader: ReplayDiskStorage.Reader) throws -> CMSampleBuffer {
        switch self {
        case .memory(let buffer):
            return buffer
        case .disk(let location, let format, let timing):
            let payload = try reader.read(location)
            var sample: CMSampleBuffer?
            let status: OSStatus
            switch timing {
            case .video(var timing, let attachments):
                var size = CMBlockBufferGetDataLength(payload)
                status = CMSampleBufferCreateReady(
                    allocator: nil, dataBuffer: payload, formatDescription: format,
                    sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                    sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
                )
                if status == noErr, let sample {
                    for (key, value) in attachments { sample.sampleAttachments[0][key] = value }
                }
            case .audio(let start, let sampleCount):
                status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: nil, dataBuffer: payload, formatDescription: format,
                    sampleCount: sampleCount, presentationTimeStamp: start,
                    packetDescriptions: nil, sampleBufferOut: &sample
                )
            }
            guard status == noErr, let sample else { throw CocoaError(.fileReadCorruptFile) }
            return sample
        }
    }
}

struct ReplaySnapshot: @unchecked Sendable {
    let video: [ReplayMediaSample]
    let audio: [ReplayMediaSample]
    let start: CMTime
    let end: CMTime
    let rotation: CGAffineTransform
    let retainedMemoryBytes: Int

    var durationSeconds: Double { (end - start).seconds }
}

final class ReplayBuffer: @unchecked Sendable {
    private struct Sample {
        let media: ReplayMediaSample
        let start: CMTime
        let end: CMTime
        let bytes: Int
        let isSync: Bool
    }

    private static let discontinuity = CMTime(value: 1, timescale: 4)
    private static let videoByteLimit = 192 * 1_024 * 1_024
    private static let audioByteLimit = 32 * 1_024 * 1_024

    private let lock = NSLock()
    private var video: ArraySlice<Sample> = []
    private var audio: ArraySlice<Sample> = []
    private var videoBytes = 0
    private var audioBytes = 0
    private var diskStorage: ReplayDiskStorage?
    private var storageFailed = false
    private var settings = RecordingSettings()
    private var nextClipStart: CMTime?

    private var clipDuration: CMTime {
        CMTime(value: Int64(settings.clipDuration), timescale: 1)
    }

    private var retentionDuration: CMTime {
        // Keep the ignored interval and some time for the capture queue to drain.
        clipDuration + CMTime(value: Int64(settings.ignoredSeconds) + 2, timescale: 1)
    }

    func availableSeconds(endingAt end: CMTime) -> Double {
        lock.withLock { clipRange(endingAt: end)?.duration.seconds ?? 0 }
    }

    var latestPlayableTime: CMTime {
        lock.withLock { playableRange?.end ?? .invalid }
    }

    var didFailToStoreFootage: Bool {
        lock.withLock { storageFailed }
    }

    func reset() {
        lock.withLock {
            removeAllSamples()
            diskStorage = nil
            storageFailed = false
        }
    }

    func reset(settings: RecordingSettings, videoBitrate: Int? = nil) {
        lock.withLock {
            self.settings = settings
            removeAllSamples()
            // The encoder can briefly reach twice its average bitrate. Keep enough space for the leading GOP.
            let maximumVideoBytes = videoBitrate.map {
                Int64($0) * 2 * Int64(settings.clipDuration + settings.ignoredSeconds + 3) / 8
            } ?? 0
            diskStorage = settings.usesDiskReplayBuffer || maximumVideoBytes > Self.videoByteLimit ? ReplayDiskStorage() : nil
            storageFailed = false
        }
    }

    func beginNextClip(at time: CMTime) {
        lock.withLock {
            guard time.isNumeric else {
                removeAllSamples()
                return
            }
            nextClipStart = time
            // Keep the preceding keyframe for decoding, even when the new clip starts mid-GOP.
            evictVideo(before: time)
            evictAudio(before: time)
        }
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        lock.withLock {
            let time = sample.presentationTimeStamp
            guard !storageFailed, time.isNumeric, sample.isValid, CMSampleBufferDataIsReady(sample),
                  let payload = sample.dataBuffer else { return }
            let bytes = CMBlockBufferGetDataLength(payload)
            guard (1...Self.videoByteLimit).contains(bytes) else { return }

            if let previous = video.last {
                guard time > previous.start else { return }
                if time - previous.end > Self.discontinuity ||
                    sample.formatDescription != previous.media.formatDescription {
                    video = []
                    videoBytes = 0
                }
            }

            let isSync = Self.isSyncSample(sample)
            guard isSync || !video.isEmpty else { return }
            guard let media = storeVideo(sample, payload: payload, byteCount: bytes) else { return }
            let duration = sample.duration
            let frameDuration = duration.isNumeric && duration > .zero
                ? duration : CMTime(value: 1, timescale: 30)
            let end = time + frameDuration
            video.append(Sample(media: media, start: time, end: end, bytes: bytes, isSync: isSync))
            videoBytes += bytes
            evictVideo(before: end - retentionDuration)
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        lock.withLock {
            let time = sample.presentationTimeStamp
            guard !storageFailed, settings.audioEnabled, time.isNumeric, sample.isValid, CMSampleBufferDataIsReady(sample),
                  let format = sample.formatDescription, let payload = sample.dataBuffer,
                  CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mFormatID
                    == kAudioFormatLinearPCM else { return }
            let bytes = CMBlockBufferGetDataLength(payload)
            guard (1...Self.audioByteLimit).contains(bytes) else { return }

            if let previous = audio.last {
                guard time > previous.start else { return }
                if time - previous.end > Self.discontinuity || format != previous.media.formatDescription {
                    audio = []
                    audioBytes = 0
                }
            }

            guard let stored = storeAudio(sample, payload: payload, format: format, byteCount: bytes),
                  stored.duration.isNumeric, stored.duration > .zero else { return }
            let end = time + stored.duration
            audio.append(Sample(media: stored.media, start: time, end: end, bytes: bytes, isSync: true))
            audioBytes += bytes
            evictAudio(before: end - retentionDuration)
        }
    }

    func snapshot(endingAt requestedEnd: CMTime, rotation: CGAffineTransform) -> ReplaySnapshot? {
        lock.withLock {
            guard let range = clipRange(endingAt: requestedEnd),
                  let syncIndex = video.lastIndex(where: { $0.isSync && $0.start <= range.start })
            else { return nil }

            // Keep a preceding keyframe for decode. The movie edit hides it when it
            // precedes the clip start. For audio, include the packet overlapping the start.
            let videoSamples = video[syncIndex...].prefix(while: { $0.start < range.end })
            let audioSamples = audio.drop(while: { $0.end <= range.start })
                .prefix(while: { $0.start < range.end })
            guard !videoSamples.isEmpty, !settings.audioEnabled || !audioSamples.isEmpty else { return nil }
            let retainedMemoryBytes = diskStorage == nil
                ? videoSamples.reduce(0) { $0 + $1.bytes } + audioSamples.reduce(0) { $0 + $1.bytes }
                : 0
            return ReplaySnapshot(video: videoSamples.map(\.media), audio: audioSamples.map(\.media),
                                  start: range.start, end: range.end, rotation: rotation,
                                  retainedMemoryBytes: retainedMemoryBytes)
        }
    }

    // The caller holds the lock.
    private func clipRange(endingAt requestedEnd: CMTime) -> CMTimeRange? {
        guard requestedEnd.isNumeric, let range = playableRange else { return nil }
        let end = min(requestedEnd, range.end)
        let start = max(range.start, end - clipDuration, nextClipStart ?? range.start)
        guard end > start else { return nil }
        return CMTimeRange(start: start, end: end)
    }

    // The caller holds the lock. The first retained video sample is always a keyframe.
    private var playableRange: CMTimeRange? {
        guard let firstVideo = video.first, let lastVideo = video.last else { return nil }
        if !settings.audioEnabled {
            return CMTimeRange(start: firstVideo.start, end: lastVideo.end)
        }
        guard let firstAudio = audio.first, let lastAudio = audio.last else { return nil }
        let start = max(firstVideo.start, firstAudio.start)
        let end = min(lastVideo.end, lastAudio.end)
        guard end > start else { return nil }
        return CMTimeRange(start: start, end: end)
    }

    private func removeAllSamples() {
        nextClipStart = nil
        video = []
        audio = []
        videoBytes = 0
        audioBytes = 0
    }

    private func evictVideo(before time: CMTime) {
        // Preserve the GOP spanning the cutoff so the very start remains decodable.
        var first = video.startIndex
        var last = video.endIndex
        while first < last {
            let middle = first + (last - first) / 2
            if video[middle].start <= time {
                first = middle + 1
            } else {
                last = middle
            }
        }
        if let keep = video[..<first].lastIndex(where: \.isSync) {
            removeVideoPrefix(keep - video.startIndex)
        }
        while diskStorage == nil && videoBytes > Self.videoByteLimit {
            let keep = video.dropFirst().firstIndex(where: \.isSync) ?? video.endIndex
            removeVideoPrefix(keep - video.startIndex)
        }
    }

    private func removeVideoPrefix(_ count: Int) {
        guard count > 0 else { return }
        videoBytes -= video.prefix(count).reduce(0) { $0 + $1.bytes }
        video.removeFirst(count)
        // A slice avoids moving the whole buffer per frame. Compact occasionally
        // to release the evicted samples and their temporary files.
        if video.startIndex >= 1_024 || video.isEmpty { video = Array(video)[...] }
    }

    private func evictAudio(before time: CMTime) {
        var count = 0
        for sample in audio {
            guard sample.end <= time || (diskStorage == nil && audioBytes > Self.audioByteLimit) else { break }
            audioBytes -= sample.bytes
            count += 1
        }
        audio.removeFirst(count)
        if audio.startIndex >= 1_024 || audio.isEmpty { audio = Array(audio)[...] }
    }

    private func storeVideo(_ sample: CMSampleBuffer, payload: CMBlockBuffer, byteCount: Int) -> ReplayMediaSample? {
        if let diskStorage {
            // VideoToolbox delivers one encoded frame in each sample buffer.
            guard sample.numSamples == 1, let format = sample.formatDescription,
                  let timing = try? sample.sampleTimingInfo(at: 0),
                  let location = store(payload, byteCount: byteCount, in: diskStorage) else { return nil }
            let attachments = sample.sampleAttachments.first.map { Array($0) } ?? []
            return .disk(location, format, .video(timing, attachments))
        } else {
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopy(allocator: nil, sampleBuffer: sample,
                                           sampleBufferOut: &copy) == noErr, let copy else { return nil }
            return .memory(copy)
        }
    }

    private func storeAudio(_ sample: CMSampleBuffer, payload: CMBlockBuffer, format: CMFormatDescription,
                            byteCount: Int) -> (media: ReplayMediaSample, duration: CMTime)? {
        let time = sample.presentationTimeStamp
        if let diskStorage {
            guard let location = store(payload, byteCount: byteCount, in: diskStorage) else { return nil }
            return (.disk(location, format, .audio(start: time, sampleCount: sample.numSamples)), sample.duration)
        }

        // Capture can reuse its PCM memory. Copy it before keeping it for later exports.
        var copiedPayload: CMBlockBuffer?
        guard CMBlockBufferCreateContiguous(
            allocator: nil, sourceBuffer: payload, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: kCMBlockBufferAlwaysCopyDataFlag, blockBufferOut: &copiedPayload
        ) == noErr, let copiedPayload else { return nil }
        var copy: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: copiedPayload, formatDescription: format,
            sampleCount: sample.numSamples, presentationTimeStamp: time,
            packetDescriptions: nil, sampleBufferOut: &copy
        ) == noErr, let copy else { return nil }
        return (.memory(copy), copy.duration)
    }

    private func store(_ payload: CMBlockBuffer, byteCount: Int,
                       in diskStorage: ReplayDiskStorage) -> ReplayDiskStorage.Location? {
        do {
            return try diskStorage.store(payload, byteCount: byteCount)
        } catch {
            storageFailed = true
            return nil
        }
    }

    private static func isSyncSample(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[String: Any]]
        return attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true
    }

}
