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
    private(set) var playingReplay: SavedReplay?
    private(set) var replaySecondsRemaining = 0
    private(set) var deviceOrientation: UIDeviceOrientation = .portrait
    var isSaving: Bool { saveCount > 0 }
    var isBufferFull: Bool { availableSeconds.isFinite && availableSeconds >= Double(activeSettings.clipDuration) }
    var canSaveReplay: Bool { phase == .recording && !isSaving && recentReplay == nil }
    var canRetryCamera: Bool { phase == .idle && status != nil && blockedRequiredPermissions.isEmpty }

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
        onConfigured: { [buffer] settings, videoBitrate in buffer.reset(settings: settings, videoBitrate: videoBitrate) },
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
        let rotation: CGAffineTransform
        let showsThumbnail: Bool
        let watchRequestID: UUID?
    }

    private struct QueuedReplay {
        let snapshot: ReplaySnapshot
        let showsThumbnail: Bool
        let watchRequestID: UUID?
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
    @ObservationIgnored private var exportID: UUID?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var pendingTaps: [Tap] = []
    @ObservationIgnored private var queuedReplays: [QueuedReplay] = []
    @ObservationIgnored private var retainedExportMemoryBytes = 0
    @ObservationIgnored private weak var recordingScene: UIWindowScene?
    @ObservationIgnored private var isInForeground = false
    @ObservationIgnored private var foregroundGeneration = 0
    @ObservationIgnored private var cameraFacing: CameraFacing = .back
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var retriedWhileStarting = false
    @ObservationIgnored private var permissionExplanation: PermissionExplanation?
    @ObservationIgnored private var permissionRequestInProgress = false
    @ObservationIgnored private lazy var watch = WatchReplayReceiver { [weak self] request in
        self?.saveReplayFromWatch(request) ?? .cameraUnavailable
    }

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

    func refreshDeviceOrientation() {
        let orientation = UIDevice.current.orientation
        if (orientation.isPortrait || orientation.isLandscape) && orientation != deviceOrientation {
            deviceOrientation = orientation
        }
    }

    func connectWatch() {
        watch.activate()
    }

    func startWhenActive(in scene: UIWindowScene) {
        guard scene.activationState == .foregroundActive else { return }
        recordingScene = scene
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        let enteredForeground = !isInForeground
        isInForeground = true
        guard enteredForeground || (phase == .interrupted && recoveryTask == nil) else { return }
        start(facing: cameraFacing)
    }

    func retryCamera() {
        guard canRetryCamera else { return }
        start(facing: cameraFacing)
    }

    private func start(facing: CameraFacing) {
        guard isInForeground,
              phase == .idle || phase == .interrupted else { return }
        guard recordingScene?.activationState == .foregroundActive else {
            phase = .interrupted
            return
        }
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
                }
                try Task.checkCancellation()
                guard recordingScene?.activationState == .foregroundActive else {
                    phase = .interrupted
                    return
                }

                if !demoMode {
                    microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
                    var sessionSettings = requested
                    sessionSettings.audioEnabled = requested.audioEnabled && microphoneAuthorization == .authorized
                    activeSettings = sessionSettings
                    try await capture.start(settings: sessionSettings, facing: facing)
                    try Task.checkCancellation()
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
        guard requestedRecordingSettings != activeSettings, isInForeground else { return }
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
            facingFront: front,
            frameRate: nil,
            frameRateRanges: [:],
            frameRateLimitedByPressure: false
        )
    }

    func didEnterBackground(in scene: UIWindowScene?) -> Bool {
        guard isInForeground, scene == nil || scene === recordingScene else { return false }
        recordingScene = nil
        isInForeground = false
        foregroundGeneration &+= 1
        cancelReplaySaves()
        discardRecentReplay()
        finishReplayPlayback()
        status = nil
        retriedWhileStarting = false
        recoveryTask?.cancel()
        recoveryTask = nil
        if phase == .recording || phase == .starting {
            finishCapture(interrupted: true)
        }
        return true
    }

    private func cancelReplaySaves() {
        exportTask?.cancel()
        for tap in pendingTaps { watch.report(.cancelled, for: tap.watchRequestID) }
        pendingTaps.removeAll()
        for replay in queuedReplays {
            retainedExportMemoryBytes -= replay.snapshot.retainedMemoryBytes
            watch.report(.cancelled, for: replay.watchRequestID)
        }
        queuedReplays.removeAll()
        // The in-flight exporter still owns its temporary files and memory until it exits.
        saveCount = 0
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
            let generation = foregroundGeneration
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard generation == foregroundGeneration else { return }
                status = "Simulator preview · no video saved"
                saveCount -= 1
            }
            return
        }

        let end = clipEnd(at: capture.tapTime())
        guard end.isNumeric, isInForeground else { return }
        queueReplay(endingAt: end, showsThumbnail: showsThumbnail)
    }

    private func saveReplayFromWatch(_ request: WatchReplayRequest) -> WatchReplayReply.Result {
        guard isInForeground, UIApplication.shared.applicationState == .active, phase == .recording else {
            return .cameraUnavailable
        }
        guard !isSaving else { return .busy }

        // Convert the Watch tap time to the capture clock without applying the iPhone's skip interval.
        let secondsSinceTap = Date.now.timeIntervalSince(request.tappedAt)
        guard secondsSinceTap.isFinite, !demoMode else { return .noFootage }
        let end = capture.tapTime() - CMTime(seconds: max(0, secondsSinceTap), preferredTimescale: 60_000)
        guard end.isNumeric else { return .noFootage }
        queueReplay(endingAt: end, showsThumbnail: false, watchRequestID: request.id)
        return .saving
    }

    private func queueReplay(endingAt end: CMTime, showsThumbnail: Bool, watchRequestID: UUID? = nil) {
        refreshDeviceOrientation()
        let rotation = capture.replayRotation(for: deviceOrientation)

        status = nil
        saveCount += 1
        pendingTaps.append(Tap(time: end, deadline: clock.now + .milliseconds(180),
                               rotation: rotation, showsThumbnail: showsThumbnail, watchRequestID: watchRequestID))
        preparePendingSaves()
    }

    func openRecentReplay() {
        guard isInForeground, !isSaving, playingReplay == nil, let replay = recentReplay else { return }
        playingReplay = replay
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
        guard (wasRecording || !retriedWhileStarting), isInForeground else { return }
        retriedWhileStarting = true

        recoveryTask = Task {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            recoveryTask = nil
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
            guard let snapshot = buffer.snapshot(endingAt: tap.time, rotation: tap.rotation) else {
                saveCount -= 1
                status = Self.noFootageMessage
                watch.report(.noFootage, for: tap.watchRequestID)
                continue
            }

            // Count memory-backed samples even if the exporter holds them after eviction.
            let maximumExportBytes = 256 * 1_024 * 1_024
            guard retainedExportMemoryBytes + snapshot.retainedMemoryBytes <= maximumExportBytes else {
                saveCount -= 1
                status = "Photos is still saving clips. Try again in a moment."
                watch.report(.busy, for: tap.watchRequestID)
                continue
            }

            retainedExportMemoryBytes += snapshot.retainedMemoryBytes
            queuedReplays.append(QueuedReplay(snapshot: snapshot, showsThumbnail: tap.showsThumbnail,
                                              watchRequestID: tap.watchRequestID))
        }

        startNextExportIfNeeded()
    }

    private func startNextExportIfNeeded() {
        guard isInForeground, !queuedReplays.isEmpty, exportTask == nil else { return }
        let generation = foregroundGeneration
        let id = UUID()
        exportID = id
        exportTask = Task { await exportQueuedClips(generation: generation, id: id) }
    }

    private func exportQueuedClips(generation: Int, id: UUID) async {
        defer {
            endBackgroundTask()
            exportID = nil
            exportTask = nil
            startNextExportIfNeeded()
        }
        guard generation == foregroundGeneration, !Task.isCancelled else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save replay to Photos") { [weak self] in
            Task { @MainActor in
                guard let self, self.exportID == id else { return }
                self.exportTask?.cancel()
                self.endBackgroundTask()
            }
        }

        while generation == foregroundGeneration, !Task.isCancelled, !queuedReplays.isEmpty {
            let replay = queuedReplays.removeFirst()
            defer {
                retainedExportMemoryBytes -= replay.snapshot.retainedMemoryBytes
                if generation == foregroundGeneration { saveCount -= 1 }
            }

            do {
                let saved = try await saveToPhotos(replay.snapshot, showsThumbnail: replay.showsThumbnail)
                watch.report(.saved, for: replay.watchRequestID)
                guard generation == foregroundGeneration, !Task.isCancelled else {
                    // Photos may complete a change already submitted before backgrounding.
                    try? FileManager.default.removeItem(at: saved.url)
                    continue
                }
                if replay.showsThumbnail {
                    offerRecentReplay(saved)
                } else {
                    try? FileManager.default.removeItem(at: saved.url)
                    beginNextClip()
                    status = "Saved to Photos"
                }
            } catch {
                guard generation == foregroundGeneration, !Task.isCancelled, !(error is CancellationError) else {
                    watch.report(.cancelled, for: replay.watchRequestID)
                    continue
                }
                if let denial = error as? RequiredPermissionsDenied {
                    if phase == .recording || phase == .starting {
                        finishCapture(interrupted: false)
                    }
                    showRequiredPermissionRecovery(denial)
                } else {
                    status = "Couldn’t save to Photos. \(error.localizedDescription)"
                }
                watch.report(.failed, for: replay.watchRequestID)
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
        try Task.checkCancellation()
        try Self.requireRecordingAndPhotosAccess()

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
            try Task.checkCancellation()
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
