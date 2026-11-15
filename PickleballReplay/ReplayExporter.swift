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
        writer.shouldOptimizeForNetworkUse = true

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                       sourceFormatHint: videoFormat)
        video.transform = snapshot.rotation
        guard writer.canAdd(video) else { throw ExportError.unsupportedFormat }
        let videoReceiver = writer.inputReceiver(for: video)
        let audioReceiver = try makeAudioReceiver(for: snapshot, writer: writer)
        do {
            try writer.start()
            // MOV uses this source-time interval as the playable edit while still
            // giving the decoder access to the GOP preceding the start.
            writer.startSession(atSourceTime: snapshot.start)
            if let audioReceiver {
                async let videoWrite: Void = writeSamples(snapshot.video, to: videoReceiver)
                async let audioWrite: Void = writeSamples(snapshot.audio, to: audioReceiver)
                do {
                    _ = try await (videoWrite, audioWrite)
                } catch {
                    // Release a sibling waiting for writer capacity before joining it.
                    if writer.status == .writing {
                        writer.cancelWriting()
                    }
                    throw error
                }
            } else {
                try await writeSamples(snapshot.video, to: videoReceiver)
            }
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

    private static func makeAudioReceiver(
        for snapshot: ReplaySnapshot, writer: AVAssetWriter
    ) throws -> sending AVAssetWriterInput.SampleBufferReceiver? {
        guard let firstAudio = snapshot.audio.first else { return nil }
        guard let audioFormat = firstAudio.formatDescription,
              let audioStream = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee
        else { throw ExportError.unsupportedFormat }
        let audio = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioStream.mSampleRate,
                AVNumberOfChannelsKey: audioStream.mChannelsPerFrame,
                AVEncoderBitRateKey: RecordingSettings.audioBitrate
            ],
            sourceFormatHint: audioFormat
        )
        guard writer.canAdd(audio) else { throw ExportError.unsupportedFormat }
        return writer.inputReceiver(for: audio)
    }

    private static func writeSamples(
        _ samples: [ReplayMediaSample], to receiver: sending AVAssetWriterInput.SampleBufferReceiver
    ) async throws {
        defer { receiver.finish() }
        for sample in samples {
            try Task.checkCancellation()
            try await receiver.append(sample)
        }
    }
}
