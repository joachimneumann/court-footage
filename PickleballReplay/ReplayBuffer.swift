import AVFoundation
import CoreGraphics
import Foundation

typealias ReplayMediaSample = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>

struct ReplaySnapshot: @unchecked Sendable {
    let video: [ReplayMediaSample]
    let audio: [ReplayMediaSample]
    let start: CMTime
    let end: CMTime
    let rotation: CGAffineTransform
    let retainedBytes: Int

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
    private var video: [Sample] = []
    private var audio: [Sample] = []
    private var videoBytes = 0
    private var audioBytes = 0
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

    func reset() {
        lock.withLock { removeAllSamples() }
    }

    func reset(settings: RecordingSettings) {
        lock.withLock {
            self.settings = settings
            removeAllSamples()
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
            guard time.isNumeric, sample.isValid, CMSampleBufferDataIsReady(sample),
                  let payload = sample.dataBuffer else { return }
            let bytes = CMBlockBufferGetDataLength(payload)
            guard (1...Self.videoByteLimit).contains(bytes) else { return }

            if let previous = video.last {
                guard time > previous.start else { return }
                if time - previous.end > Self.discontinuity ||
                    sample.formatDescription != previous.media.formatDescription {
                    video.removeAll()
                    videoBytes = 0
                }
            }

            let isSync = Self.isSyncSample(sample)
            guard isSync || !video.isEmpty else { return }
            // Keep an independent sample header and share VideoToolbox's encoded bytes.
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopy(allocator: nil, sampleBuffer: sample,
                                           sampleBufferOut: &copy) == noErr,
                  let copy else { return }
            let duration = sample.duration
            let frameDuration = duration.isNumeric && duration > .zero
                ? duration : CMTime(value: 1, timescale: 30)
            let end = time + frameDuration
            video.append(Sample(media: Self.freezeOwnedSample(copy),
                                start: time, end: end, bytes: bytes, isSync: isSync))
            videoBytes += bytes
            evictVideo(before: end - retentionDuration)
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        lock.withLock {
            let time = sample.presentationTimeStamp
            guard settings.audioEnabled, time.isNumeric, sample.isValid, CMSampleBufferDataIsReady(sample),
                  let format = sample.formatDescription, let payload = sample.dataBuffer,
                  CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mFormatID
                    == kAudioFormatLinearPCM else { return }
            let bytes = CMBlockBufferGetDataLength(payload)
            guard (1...Self.audioByteLimit).contains(bytes) else { return }

            if let previous = audio.last {
                guard time > previous.start else { return }
                if time - previous.end > Self.discontinuity || format != previous.media.formatDescription {
                    audio.removeAll()
                    audioBytes = 0
                }
            }

            // Capture can reuse its PCM memory. Copy it before keeping it for later exports.
            var copiedPayload: CMBlockBuffer?
            guard CMBlockBufferCreateContiguous(
                allocator: nil, sourceBuffer: payload, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                flags: kCMBlockBufferAlwaysCopyDataFlag, blockBufferOut: &copiedPayload
            ) == noErr, let copiedPayload else { return }
            var copy: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: copiedPayload, formatDescription: format,
                sampleCount: sample.numSamples, presentationTimeStamp: time,
                packetDescriptions: nil, sampleBufferOut: &copy
            ) == noErr, let copy, copy.duration.isNumeric, copy.duration > .zero else { return }

            let end = time + copy.duration
            audio.append(Sample(media: Self.freezeOwnedSample(copy),
                                start: time, end: end, bytes: bytes, isSync: true))
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
            let retainedBytes = videoSamples.reduce(0) { $0 + $1.bytes }
                + audioSamples.reduce(0) { $0 + $1.bytes }
            return ReplaySnapshot(video: videoSamples.map(\.media), audio: audioSamples.map(\.media),
                                  start: range.start, end: range.end, rotation: rotation,
                                  retainedBytes: retainedBytes)
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
        video.removeAll()
        audio.removeAll()
        videoBytes = 0
        audioBytes = 0
    }

    private func evictVideo(before time: CMTime) {
        // Preserve the GOP spanning the cutoff so the very start remains decodable.
        if let keep = video.lastIndex(where: { $0.isSync && $0.start <= time }), keep > 0 {
            removeVideoPrefix(keep)
        }
        while videoBytes > Self.videoByteLimit {
            removeVideoPrefix(video.dropFirst().firstIndex(where: \.isSync) ?? video.endIndex)
        }
    }

    private func removeVideoPrefix(_ count: Int) {
        videoBytes -= video.prefix(count).reduce(0) { $0 + $1.bytes }
        video.removeFirst(count)
    }

    private func evictAudio(before time: CMTime) {
        var count = 0
        while count < audio.count && (audio[count].end <= time || audioBytes > Self.audioByteLimit) {
            audioBytes -= audio[count].bytes
            count += 1
        }
        audio.removeFirst(count)
    }

    private static func isSyncSample(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[String: Any]]
        return attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true
    }

    private static func freezeOwnedSample(_ sample: CMSampleBuffer) -> ReplayMediaSample {
        // Both callers create a new sample header through the Core Media out-parameter.
        // They transfer it here without subsequent mutation.
        nonisolated(unsafe) let ownedSample = sample
        return ReplayMediaSample(unsafeBuffer: ownedSample)
    }
}
