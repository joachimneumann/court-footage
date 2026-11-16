@preconcurrency import AVFoundation
import Observation
import Photos
import UIKit

struct SavedReplay: Identifiable {
    let url: URL
    let thumbnail: CGImage?
    let durationSeconds: Double
    var id: URL { url }
}

@MainActor
@Observable
final class RecordingModel {
    enum Phase {
        case idle, starting, recording, interrupted
    }

    private(set) var phase: Phase = .idle
    private(set) var availableSeconds: Double = 0
    private(set) var status: String?
    private(set) var saveCount = 0
    private(set) var cameraControls: CameraControls?
    private(set) var permissionPrompt: RecordingPermissionPrompt?
    private(set) var blockedRequiredPermissions: [RecordingPermission] = []
    private(set) var recentReplay: SavedReplay?
    private(set) var replaySecondsRemaining = 0
    var isSaving: Bool { saveCount > 0 }
    var isBufferFull: Bool { availableSeconds.isFinite && availableSeconds >= Double(activeSettings.clipDuration) }
    var canSaveReplay: Bool { phase == .recording && !isSaving && recentReplay == nil }

    var settings: RecordingSettings {
        didSet {
            if settings != oldValue { settings.save(to: preferences) }
        }
    }
    private(set) var activeSettings: RecordingSettings

    private var microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    var canEnableAudio: Bool {
        microphoneAuthorization == .authorized || microphoneAuthorization == .notDetermined
    }
    var audioEnabledInSettings: Bool { settings.audioEnabled && canEnableAudio }

    private var requestedRecordingSettings: RecordingSettings {
        var requested = settings
        requested.audioEnabled = audioEnabledInSettings
        return requested
    }

    let demoMode: Bool

    @ObservationIgnored lazy var capture = CaptureService(
        onVideo: { [buffer] in buffer.appendVideo($0) },
        onAudio: { [buffer] in buffer.appendAudio($0) },
        onInterruption: { [weak self] in
            Task { @MainActor in self?.interrupt() }
        },
        onCameraControls: { [weak self] controls in
            Task { @MainActor in
                guard let self, self.phase == .starting || self.phase == .recording else { return }
                self.cameraControls = controls
            }
        }
    )

    private struct Tap {
        let time: CMTime
        let deadline: ContinuousClock.Instant
        let showsThumbnail: Bool
    }

    private struct QueuedReplay {
        let snapshot: ReplaySnapshot
        let showsThumbnail: Bool
    }

    private struct PermissionExplanation {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct RequiredPermissionsDenied: Error {
        let permissions: [RecordingPermission]
    }

    @ObservationIgnored private let buffer = ReplayBuffer()
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var replayDismissTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var pendingTaps: [Tap] = []
    @ObservationIgnored private var queuedReplays: [QueuedReplay] = []
    @ObservationIgnored private var retainedExportMemoryBytes = 0
    @ObservationIgnored private var rotation: CGAffineTransform = .identity
    @ObservationIgnored private var foregroundOrientation: UIInterfaceOrientation?
    @ObservationIgnored private var cameraFacing: CameraFacing = .back
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var retriedWhileStarting = false
    @ObservationIgnored private var permissionExplanation: PermissionExplanation?
    @ObservationIgnored private var permissionRequestInProgress = false
    @ObservationIgnored private var playingReplay: SavedReplay?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let saved = RecordingSettings.load(from: preferences)
        settings = saved
        activeSettings = saved

        #if DEBUG && targetEnvironment(simulator)
        demoMode = ProcessInfo.processInfo.arguments.contains("--demo")
        #else
        demoMode = false
        #endif

        // A previous run can have been terminated before its temporary export was removed.
        try? FileManager.default.removeItem(at: Self.exportDirectory)
        ReplayDiskStorage.removeTemporaryFiles()
    }

    func startWhenActive(orientation: UIInterfaceOrientation) {
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        let enteredForeground = foregroundOrientation == nil
        foregroundOrientation = orientation
        guard enteredForeground || (phase == .interrupted && recoveryTask == nil) else { return }
        start(facing: cameraFacing)
    }

    private func start(facing: CameraFacing) {
        guard foregroundOrientation != nil,
              phase == .idle || phase == .interrupted else { return }
        let requested = requestedRecordingSettings
        activeSettings = requested
        phase = .starting
        availableSeconds = 0
        status = nil
        cameraControls = nil
        blockedRequiredPermissions = []

        let previousStop = stopTask
        startTask = Task {
            await previousStop?.value
            guard !Task.isCancelled else { return }
            do {
                if !demoMode {
                    try await authorizeCapture(audioEnabled: requested.audioEnabled)
                    try Task.checkCancellation()
                    guard let orientation = foregroundOrientation else { return }

                    microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
                    var sessionSettings = requested
                    sessionSettings.audioEnabled = requested.audioEnabled && microphoneAuthorization == .authorized
                    activeSettings = sessionSettings
                    buffer.reset(settings: sessionSettings)
                    try await capture.start(orientation: orientation, settings: sessionSettings, facing: facing)
                    try Task.checkCancellation()
                    rotation = capture.captureRotation
                } else {
                    cameraControls = Self.previewControls(facing: facing)
                }
                cameraFacing = facing
                retriedWhileStarting = false
                phase = .recording
                UIApplication.shared.isIdleTimerDisabled = true
                observeProgress()
            } catch is CancellationError {
                // The stop path owns teardown, including a start that was still in flight.
            } catch let denial as RequiredPermissionsDenied {
                guard !Task.isCancelled else { return }
                showRequiredPermissionRecovery(denial)
            } catch {
                guard !Task.isCancelled else { return }
                await capture.stop()
                guard !Task.isCancelled else { return }
                buffer.reset()
                phase = .idle
                status = error.localizedDescription
                cameraControls = nil
            }
        }
    }

    func applyRecordingSettingsIfNeeded() {
        guard requestedRecordingSettings != activeSettings, foregroundOrientation != nil else { return }
        if phase == .recording || phase == .starting {
            finishCapture(interrupted: false)
        }
        recoveryTask?.cancel()
        recoveryTask = nil
        start(facing: cameraFacing)
    }

    func setZoom(_ factor: Double) {
        guard phase == .recording, let cameraControls, factor.isFinite else { return }
        if demoMode {
            let zoom = min(cameraControls.zoom.maximum, max(cameraControls.zoom.minimum, factor))
            self.cameraControls = Self.previewControls(facing: cameraFacing, factor: zoom)
        } else {
            capture.setZoom(factor)
        }
    }

    func flipCamera() {
        guard phase == .recording, !isSaving, let cameraControls, cameraControls.canFlip else { return }
        let otherCamera: CameraFacing = cameraControls.facingFront ? .back : .front
        finishCapture(interrupted: false)
        start(facing: otherCamera)
    }

    private static func previewControls(facing: CameraFacing, factor: Double? = nil) -> CameraControls {
        let front = facing == .front
        let minimum = front ? 1.0 : 0.5
        return CameraControls(
            zoom: CameraZoomState(factor: factor ?? minimum, minimum: minimum, maximum: front ? 3 : 10,
                                  presets: front ? [1] : [0.5, 1, 2, 5]),
            canFlip: true,
            facingFront: front
        )
    }

    func sceneDidEnterBackground() {
        foregroundOrientation = nil
        retriedWhileStarting = false
        recoveryTask?.cancel()
        recoveryTask = nil
        if phase == .recording || phase == .starting {
            finishCapture(interrupted: true)
        }
    }

    func continuePermissionPrompt() {
        guard let explanation = permissionExplanation else { return }
        permissionExplanation = nil
        permissionPrompt = nil
        explanation.continuation.resume()
    }

    func openPermissionSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func showRequiredPermissionRecovery(_ denial: RequiredPermissionsDenied) {
        phase = .idle
        blockedRequiredPermissions = denial.permissions
        status = nil
    }

    private func requestPermission<Result>(
        explaining prompt: RecordingPermissionPrompt,
        _ request: @MainActor () async throws -> Result
    ) async throws -> Result {
        // Keep the explanation and its system alert together if requests overlap.
        while permissionRequestInProgress || permissionPrompt != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        permissionRequestInProgress = true
        defer { permissionRequestInProgress = false }
        try await explainPermission(prompt)
        return try await request()
    }

    private func explainPermission(_ prompt: RecordingPermissionPrompt) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                permissionExplanation = PermissionExplanation(id: id, continuation: continuation)
                permissionPrompt = prompt
            }
        } onCancel: {
            Task { @MainActor in
                guard let explanation = self.permissionExplanation, explanation.id == id else { return }
                self.permissionExplanation = nil
                self.permissionPrompt = nil
                explanation.continuation.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
    }

    func saveReplay(showsThumbnail: Bool = true) {
        guard canSaveReplay else { return }
        if demoMode {
            guard availableSeconds > 0 else {
                status = Self.noFootageMessage
                return
            }
            status = nil
            saveCount += 1
            Task {
                try? await Task.sleep(for: .seconds(2))
                status = "Simulator preview · no video saved"
                saveCount -= 1
            }
            return
        }

        let end = clipEnd(at: capture.tapTime())
        guard end.isNumeric else { return }

        status = nil
        saveCount += 1
        pendingTaps.append(Tap(time: end, deadline: clock.now + .milliseconds(180), showsThumbnail: showsThumbnail))
        preparePendingSaves()
    }

    func openRecentReplay() -> SavedReplay? {
        guard !isSaving, playingReplay == nil, let replay = recentReplay else { return nil }
        playingReplay = replay
        return replay
    }

    func finishReplayPlayback() {
        guard let replay = playingReplay else { return }
        playingReplay = nil
        if recentReplay?.url != replay.url {
            try? FileManager.default.removeItem(at: replay.url)
        }
    }

    func dismissRecentReplay(id: URL) {
        guard recentReplay?.id == id else { return }
        discardRecentReplay()
    }

    private func offerRecentReplay(_ replay: SavedReplay) {
        discardRecentReplay()
        recentReplay = replay
        beginNextClip()

        let countdownSeconds = 10
        let startedAt = clock.now
        replaySecondsRemaining = countdownSeconds
        replayDismissTask = Task { [weak self, clock] in
            for elapsed in 1...countdownSeconds {
                try? await clock.sleep(until: startedAt + .seconds(elapsed))
                guard let self, !Task.isCancelled else { return }
                replaySecondsRemaining = countdownSeconds - elapsed
            }
            self?.dismissRecentReplay(id: replay.id)
        }
    }

    private func beginNextClip() {
        availableSeconds = 0
        if phase == .recording {
            buffer.beginNextClip(at: capture.tapTime())
            observeProgress()
        }
    }

    private func discardRecentReplay() {
        guard let replay = recentReplay else { return }
        replayDismissTask?.cancel()
        replayDismissTask = nil
        recentReplay = nil
        replaySecondsRemaining = 0
        if playingReplay?.url != replay.url {
            try? FileManager.default.removeItem(at: replay.url)
        }
    }

    private func observeProgress() {
        progressTask?.cancel()
        let startTime = clock.now
        progressTask = Task {
            while !Task.isCancelled, phase == .recording {
                if buffer.didFailToStoreFootage {
                    finishCapture(interrupted: false)
                    status = "Couldn’t store the replay buffer. Free up storage or choose a shorter clip."
                    return
                }
                if demoMode {
                    let elapsed = startTime.duration(to: clock.now).components
                    let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                    availableSeconds = min(Double(activeSettings.clipDuration), max(0, seconds - Double(activeSettings.ignoredSeconds)))
                } else {
                    availableSeconds = buffer.availableSeconds(endingAt: clipEnd(at: capture.tapTime()))
                    preparePendingSaves()
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func clipEnd(at time: CMTime) -> CMTime {
        time - CMTime(value: Int64(activeSettings.ignoredSeconds), timescale: 1)
    }

    private static let noFootageMessage = "Collecting footage. Tap again in a moment."

    private func interrupt() {
        guard phase == .recording || phase == .starting else { return }
        let wasRecording = phase == .recording
        finishCapture(interrupted: true)
        guard (wasRecording || !retriedWhileStarting), foregroundOrientation != nil else { return }
        retriedWhileStarting = true

        recoveryTask = Task {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            recoveryTask = nil
            guard UIApplication.shared.applicationState == .active else { return }
            start(facing: cameraFacing)
        }
    }

    private func finishCapture(interrupted: Bool) {
        startTask?.cancel()
        progressTask?.cancel()
        progressTask = nil
        preparePendingSaves(force: true)
        phase = interrupted ? .interrupted : .idle
        cameraControls = nil
        availableSeconds = 0
        UIApplication.shared.isIdleTimerDisabled = false

        let previousStart = startTask
        startTask = nil
        stopTask = Task {
            await previousStart?.value
            if !demoMode { await capture.stop() }
            buffer.reset()
        }
    }

    private func preparePendingSaves(force: Bool = false) {
        let latest = buffer.latestPlayableTime
        while let tap = pendingTaps.first,
              force || (latest.isNumeric && latest >= tap.time) || clock.now >= tap.deadline {
            pendingTaps.removeFirst()
            guard let snapshot = buffer.snapshot(endingAt: tap.time, rotation: rotation) else {
                saveCount -= 1
                status = Self.noFootageMessage
                continue
            }

            // Count memory-backed samples even if the exporter holds them after eviction.
            let maximumExportBytes = 256 * 1_024 * 1_024
            guard retainedExportMemoryBytes + snapshot.retainedMemoryBytes <= maximumExportBytes else {
                saveCount -= 1
                status = "Photos is still saving clips. Try again in a moment."
                continue
            }

            retainedExportMemoryBytes += snapshot.retainedMemoryBytes
            queuedReplays.append(QueuedReplay(snapshot: snapshot, showsThumbnail: tap.showsThumbnail))
        }

        guard !queuedReplays.isEmpty, exportTask == nil else { return }
        exportTask = Task { await exportQueuedClips() }
    }

    private func exportQueuedClips() async {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save replay to Photos") { [weak self] in
            Task { @MainActor in
                self?.exportTask?.cancel()
                self?.endBackgroundTask()
            }
        }
        defer {
            endBackgroundTask()
            exportTask = nil
        }

        while !queuedReplays.isEmpty {
            let replay = queuedReplays.removeFirst()
            defer {
                retainedExportMemoryBytes -= replay.snapshot.retainedMemoryBytes
                saveCount -= 1
            }

            do {
                try Task.checkCancellation()
                let saved = try await saveToPhotos(replay.snapshot, showsThumbnail: replay.showsThumbnail)
                if replay.showsThumbnail {
                    offerRecentReplay(saved)
                } else {
                    try? FileManager.default.removeItem(at: saved.url)
                    beginNextClip()
                    status = "Saved to Photos"
                }
            } catch let denial as RequiredPermissionsDenied {
                if phase == .recording || phase == .starting {
                    finishCapture(interrupted: false)
                }
                showRequiredPermissionRecovery(denial)
            } catch {
                status = "Couldn’t save to Photos. \(error.localizedDescription)"
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "CourtReplayExports", directoryHint: .isDirectory)
    }

    private func saveToPhotos(_ clip: ReplaySnapshot, showsThumbnail: Bool) async throws -> SavedReplay {
        try Self.requireRecordingAndPhotosAccess()
        try Task.checkCancellation()

        let directory = Self.exportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: UUID().uuidString).appendingPathExtension("mov")
        do {
            try await ReplayExporter.write(clip, to: url)
            try Task.checkCancellation()
            try Self.requireRecordingAndPhotosAccess()
            async let thumbnail = showsThumbnail ? ReplayExporter.firstFrame(in: url) : nil
            // PhotoKit runs its change block off the main actor.
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                let asset = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                // Keep the export until the recording model handles playback or cleanup.
                options.shouldMoveFile = false
                options.originalFilename = "Court Footage.mov"
                asset.addResource(with: .video, fileURL: url, options: options)
            }
            return SavedReplay(url: url, thumbnail: await thumbnail, durationSeconds: clip.durationSeconds)
        } catch {
            try? FileManager.default.removeItem(at: url)
            try Self.requireRecordingAndPhotosAccess()
            throw error
        }
    }

    private func authorizeCapture(audioEnabled: Bool) async throws {
        #if targetEnvironment(simulator)
        throw AccessError.simulator
        #else
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        let photos = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let needsCamera = camera == .notDetermined
        let needsPhotos = photos == .notDetermined
        let needsMicrophone = audioEnabled && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
            && (camera == .authorized || needsCamera) && (photos == .authorized || needsPhotos)

        if needsCamera || needsPhotos || needsMicrophone {
            try await requestPermission(explaining: RecordingPermissionPrompt(
                camera: needsCamera, microphone: needsMicrophone, photos: needsPhotos
            )) {
                if needsCamera {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                    try Task.checkCancellation()
                }
                if needsPhotos {
                    _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    try Task.checkCancellation()
                }
                try Self.requireRecordingAndPhotosAccess()
                if needsMicrophone {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                    try Task.checkCancellation()
                }
            }
        }
        try Self.requireRecordingAndPhotosAccess()
        #endif
    }

    private static func requireRecordingAndPhotosAccess() throws {
        var missing: [RecordingPermission] = []
        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized { missing.append(.camera) }
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) != .authorized { missing.append(.photos) }
        if !missing.isEmpty { throw RequiredPermissionsDenied(permissions: missing) }
    }

    private enum AccessError: LocalizedError {
        case simulator

        var errorDescription: String? {
            switch self {
            case .simulator: "Run Court Footage on an iPhone to record."
            }
        }
    }
}
