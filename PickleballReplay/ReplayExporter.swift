import AVFoundation
import Foundation

enum ReplayExporter {
    private enum ExportError: LocalizedError {
        case missingVideo
        case unsupportedFormat
        case unfinishedFile

        var errorDescription: String? {
            switch self {
            case .missingVideo: "There was no recorded video to save."
            case .unsupportedFormat: "The replay's video or audio format couldn't be saved."
            case .unfinishedFile: "The replay file couldn't be completed."
            }
        }
    }

    static func firstFrame(in url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_920, height: 1_920)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let frame = try? await generator.image(at: .zero) {
            return frame.image
        }

        // A track can begin slightly after the movie's start when audio starts first.
        guard !Task.isCancelled else { return nil }
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        return try? await generator.image(at: .zero).image
    }

    static func write(_ snapshot: ReplaySnapshot, to url: URL) async throws {
        guard let videoFormat = snapshot.video.first?.formatDescription else {
            throw ExportError.missingVideo
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists)
        }

        let writer = try AVAssetWriter(url: url, fileType: .mov)
        writer.movieTimeScale = 60_000
        // Skip the extra pass to move the movie index to the front for large local replays.
        writer.shouldOptimizeForNetworkUse = snapshot.retainedMemoryBytes > 0

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                       sourceFormatHint: videoFormat)
        video.transform = snapshot.rotation
        guard writer.canAdd(video) else { throw ExportError.unsupportedFormat }
        let audio = try makeAudioInput(for: snapshot)
        do {
            if #available(iOS 26.0, *) {
                try await writeWithReceivers(snapshot, writer: writer, video: video, audio: audio)
            } else {
                try await writeWithInputs(snapshot, writer: writer, video: video, audio: audio)
            }
            try Task.checkCancellation()
            // MOV uses the source-time interval as the playable edit and retains
            // the preceding keyframe for decoding when the clip starts mid-GOP.
            writer.endSession(atSourceTime: snapshot.end)
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? ExportError.unfinishedFile }
        } catch {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func makeAudioInput(for snapshot: ReplaySnapshot) throws -> AVAssetWriterInput? {
        guard let firstAudio = snapshot.audio.first else { return nil }
        guard let audioFormat = firstAudio.formatDescription,
              let audioStream = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee
        else { throw ExportError.unsupportedFormat }
        return AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioStream.mSampleRate,
                AVNumberOfChannelsKey: audioStream.mChannelsPerFrame,
                AVEncoderBitRateKey: RecordingSettings.audioBitrate
            ],
            sourceFormatHint: audioFormat
        )
    }

    @available(iOS 26.0, *)
    private static func writeWithReceivers(
        _ snapshot: ReplaySnapshot, writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput?
    ) async throws {
        let videoReceiver = writer.inputReceiver(for: video)
        let audioReceiver: AVAssetWriterInput.SampleBufferReceiver?
        if let audio {
            guard writer.canAdd(audio) else { throw ExportError.unsupportedFormat }
            audioReceiver = writer.inputReceiver(for: audio)
        } else {
            audioReceiver = nil
        }
        try writer.start()
        writer.startSession(atSourceTime: snapshot.start)
        if let audioReceiver {
            async let videoWrite: Void = writeSamples(snapshot.video, to: videoReceiver)
            async let audioWrite: Void = writeSamples(snapshot.audio, to: audioReceiver)
            do {
                _ = try await (videoWrite, audioWrite)
            } catch {
                // Release a sibling waiting for writer capacity before joining it.
                if writer.status == .writing { writer.cancelWriting() }
                throw error
            }
        } else {
            try await writeSamples(snapshot.video, to: videoReceiver)
        }
    }

    @available(iOS 26.0, *)
    private static func writeSamples(
        _ samples: [ReplayMediaSample], to receiver: sending AVAssetWriterInput.SampleBufferReceiver
    ) async throws {
        defer { receiver.finish() }
        let reader = ReplayDiskStorage.Reader()
        for sample in samples {
            try Task.checkCancellation()
            nonisolated(unsafe) let buffer = try sample.load(using: reader)
            try await receiver.append(CMReadySampleBuffer(unsafeBuffer: buffer))
        }
    }

    private static func writeWithInputs(
        _ snapshot: ReplaySnapshot, writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput?
    ) async throws {
        writer.add(video)
        var tracks = [(input: video, samples: snapshot.video[...])]
        if let audio {
            guard writer.canAdd(audio) else { throw ExportError.unsupportedFormat }
            writer.add(audio)
            tracks.append((input: audio, samples: snapshot.audio[...]))
        }
        guard writer.startWriting() else { throw writer.error ?? ExportError.unfinishedFile }
        writer.startSession(atSourceTime: snapshot.start)

        let reader = ReplayDiskStorage.Reader()
        while !tracks.isEmpty {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? ExportError.unfinishedFile }
            var madeProgress = false
            // Give both tracks a chance to write so neither blocks the other while interleaving.
            for index in tracks.indices.reversed() {
                let input = tracks[index].input
                guard input.isReadyForMoreMediaData, let sample = tracks[index].samples.first else { continue }
                guard input.append(try sample.load(using: reader)) else {
                    throw writer.error ?? ExportError.unfinishedFile
                }
                madeProgress = true
                tracks[index].samples.removeFirst()
                if tracks[index].samples.isEmpty {
                    input.markAsFinished()
                    tracks.remove(at: index)
                }
            }
            if !madeProgress { try await Task.sleep(for: .milliseconds(5)) }
        }
    }
}
