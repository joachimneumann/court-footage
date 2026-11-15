@preconcurrency import AVFoundation
import AVKit
import UIKit
import VideoToolbox

enum CameraFacing: Sendable, Equatable {
    case back, front

    fileprivate var opposite: Self { self == .back ? .front : .back }
    fileprivate var position: AVCaptureDevice.Position { self == .back ? .back : .front }
}

struct CameraZoomState: Sendable, Equatable {
    let factor: Double
    let minimum: Double
    let maximum: Double
    let presets: [Double]
}

struct CameraControls: Sendable, Equatable {
    let zoom: CameraZoomState
    let canFlip: Bool
    let facingFront: Bool
}

final class CaptureService: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    @MainActor private(set) var captureRotation = CGAffineTransform.identity
    @MainActor private weak var previewView: UIView?
    @MainActor private weak var previewWindow: UIWindow?
    @MainActor private var previewRevision = 0
    @MainActor private var previewCamera: AVCaptureDevice?
    @MainActor private var directionCoordinator: AnyObject?
    @MainActor private var cameraDirectionsReady = false
    @MainActor private var previewRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @MainActor private var previewRotationObservation: NSKeyValueObservation?

    private let captureQueue = DispatchQueue(label: "PickleballReplay.Capture", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "PickleballReplay.CaptureOutput", qos: .userInitiated)
    private let pendingVideo = DispatchSemaphore(value: 3)
    private let pendingAudio = DispatchSemaphore(value: 5)
    private let onVideo: @Sendable (CMSampleBuffer) -> Void
    private let onAudio: @Sendable (CMSampleBuffer) -> Void
    private let onInterruption: @Sendable () -> Void
    private let onCameraControls: @Sendable (CameraControls) -> Void
    private let clockLock = NSLock()
    private var captureClock: CMClock?

    // The capture queue owns the session topology and the encoder.
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var camera: AVCaptureDevice?
    private var cameraDirections: CameraDirections?
    private var facing: CameraFacing = .back
    private var activeQuality: VideoQuality?
    private var canFlip = false
    private var lastControls: CameraControls?
    private var zoomObservers: [NSKeyValueObservation] = []
    private var audioFormat: CMFormatDescription?
    private var encoder: VTCompressionSession?
    private var observers: [NSObjectProtocol] = []
    private var pressureObservation: NSKeyValueObservation?
    private var nominalFrameDuration = CMTime(value: 1, timescale: 30)
    private var generation = 0
    private var running = false

    init(
        onVideo: @escaping @Sendable (CMSampleBuffer) -> Void,
        onAudio: @escaping @Sendable (CMSampleBuffer) -> Void,
        onInterruption: @escaping @Sendable () -> Void,
        onCameraControls: @escaping @Sendable (CameraControls) -> Void = { _ in }
    ) {
        self.onVideo = onVideo
        self.onAudio = onAudio
        self.onInterruption = onInterruption
        self.onCameraControls = onCameraControls
        super.init()
    }

    @MainActor
    func setPreviewView(_ view: UIView) {
        guard let window = view.window else { return }
        guard previewView !== view || previewWindow !== window else {
            updatePreviewRotation()
            return
        }
        previewView = view
        previewWindow = window
        previewRevision += 1
        configurePreviewRotation()
        if #available(iOS 27.1, *) {
            let revision = previewRevision
            cameraDirectionsReady = false
            captureQueue.async { self.cameraDirections = nil }
            directionCoordinator = AVCaptureDeviceDirectionCoordinator(
                view: view,
                deviceTypes: Self.cameraTypes
            ) { [weak self, weak view] directions in
                guard let self, let view, let window = view.window,
                      self.previewRevision == revision,
                      self.previewWindow === window else { return }
                // AVKit reports the map on the main queue. Resolve devices on the capture queue.
                self.updateCameraDirections(
                    CameraDirections(
                        back: Set(directions.backwardFacingDeviceDescriptors.map(\.uniqueID)),
                        front: Set(directions.forwardFacingDeviceDescriptors.map(\.uniqueID))
                    ),
                    previewRevision: revision
                )
            }
        }
    }

    @MainActor
    func start(
        orientation: UIInterfaceOrientation,
        settings: RecordingSettings,
        facing: CameraFacing = .back
    ) async throws {
        try await waitForCameraDirections()
        try Task.checkCancellation()
        let captureOrientation: AVCaptureVideoOrientation = switch orientation {
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .portraitUpsideDown: .portraitUpsideDown
        default: .portrait
        }
        let device: AVCaptureDevice = try await withCheckedThrowingContinuation { continuation in
            captureQueue.async {
                do {
                    continuation.resume(returning: try self.startCapture(settings: settings, facing: facing))
                } catch {
                    self.stopCapture()
                    continuation.resume(throwing: error)
                }
            }
        }
        let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        let degrees = rotation.videoRotationAngleRelative(toDeviceOrientation: captureOrientation)
        captureRotation = CGAffineTransform(rotationAngle: degrees * .pi / 180)
        previewCamera = device
        configurePreviewRotation()
    }

    @MainActor
    private func waitForCameraDirections() async throws {
        guard #available(iOS 27.1, *) else { return }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        // AVKit announces the first map asynchronously. Keep startup cancelable while
        // the current preview attaches and its camera map reaches the capture queue.
        while !cameraDirectionsReady || previewView?.window == nil || previewView?.window !== previewWindow {
            guard clock.now < deadline else { throw CaptureError.cameraDirectionsUnavailable }
            try await clock.sleep(until: min(deadline, clock.now + .milliseconds(20)))
        }
    }

    @MainActor
    func stop() async {
        await withCheckedContinuation { continuation in
            captureQueue.async {
                self.stopCapture()
                continuation.resume()
            }
        }
        previewCamera = nil
        configurePreviewRotation()
    }

    @MainActor
    func setZoom(_ factor: Double) {
        guard factor.isFinite else { return }
        captureQueue.async {
            guard self.running, let camera = self.camera else { return }
            do {
                try camera.lockForConfiguration()
                self.applyZoom(CGFloat(factor), toLockedCamera: camera)
                camera.unlockForConfiguration()
            } catch {
                // Keep showing the camera's actual factor if the hardware is busy.
            }
            self.publishCameraControls(for: camera)
        }
    }

    func tapTime() -> CMTime {
        let host = CMClock.hostTimeClock
        let now = host.time
        guard let clock = clockLock.withLock({ captureClock }) else { return .invalid }
        return host.convertTime(now, to: clock)
    }

    @MainActor
    private func configurePreviewRotation() {
        previewRotationObservation = nil
        previewRotationCoordinator = nil
        guard let layer = previewView?.layer as? AVCaptureVideoPreviewLayer,
              let previewCamera else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: previewCamera, previewLayer: layer)
        previewRotationCoordinator = coordinator
        updatePreviewRotation()
        previewRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview) {
            [weak self] _, _ in
            Task { @MainActor in self?.updatePreviewRotation() }
        }
    }

    @MainActor
    private func updatePreviewRotation() {
        guard let layer = previewView?.layer as? AVCaptureVideoPreviewLayer,
              let connection = layer.connection,
              let degrees = previewRotationCoordinator?.videoRotationAngleForHorizonLevelPreview,
              connection.isVideoRotationAngleSupported(degrees) else { return }
        connection.videoRotationAngle = degrees
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    private func updateCameraDirections(_ directions: CameraDirections, previewRevision: Int) {
        captureQueue.async {
            self.cameraDirections = directions
            Task { @MainActor in
                guard self.previewRevision == previewRevision else { return }
                self.cameraDirectionsReady = true
            }
            guard let camera = self.camera, let quality = self.activeQuality else { return }
            if !directions.contains(camera, facing: self.facing) {
                self.interruptCapture()
            } else {
                self.updateCanFlip(quality: quality)
                self.publishCameraControls(for: camera)
            }
        }
    }

    private static var cameraTypes: [AVCaptureDevice.DeviceType] {
        var types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
            .builtInTrueDepthCamera, .builtInWideAngleCamera,
            .builtInUltraWideCamera, .builtInTelephotoCamera
        ]
        if #available(iOS 27.1, *) {
            types += [.builtInOuterUltraWideCamera, .builtInInnerUltraWideCamera]
        }
        return types
    }

    private struct CameraDirections: Sendable {
        let back: Set<String>
        let front: Set<String>

        func ids(facing: CameraFacing) -> Set<String> {
            facing == .back ? back : front
        }

        func contains(_ camera: AVCaptureDevice, facing: CameraFacing) -> Bool {
            let ids = ids(facing: facing)
            if ids.contains(camera.uniqueID) { return true }
            // Some direction maps describe the lenses rather than the rear virtual camera.
            let constituents = camera.constituentDevices
            return !constituents.isEmpty && constituents.allSatisfy { ids.contains($0.uniqueID) }
        }
    }

    private func availableCameras(facing: CameraFacing) -> [AVCaptureDevice] {
        let cameraTypes = Self.cameraTypes
        if #available(iOS 27.1, *) {
            guard let cameraDirections else { return [] }
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: cameraTypes, mediaType: .video, position: .unspecified
            )
            let discovered = discovery.devices.filter { cameraDirections.contains($0, facing: facing) }
            let knownIDs = Set(discovered.map(\.uniqueID))
            let additional = cameraDirections.ids(facing: facing).subtracting(knownIDs)
                .compactMap { AVCaptureDevice(uniqueID: $0) }
            let candidates = discovered + additional
            return cameraTypes.flatMap { type in candidates.filter { $0.deviceType == type } }
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: cameraTypes, mediaType: .video, position: facing.position
        )
        return discovery.devices
    }

    private func startCapture(settings: RecordingSettings, facing: CameraFacing) throws -> AVCaptureDevice {
        if running, let camera { return camera }
        if #available(iOS 27.1, *), cameraDirections == nil {
            throw CaptureError.cameraDirectionsUnavailable
        }
        let candidates = availableCameras(facing: facing)
        guard !candidates.isEmpty else { throw CaptureError.noCamera }
        guard let selectedCamera = candidates.first(where: { $0.supportsSessionPreset(settings.quality.capturePreset) }) else {
            throw CaptureError.unsupportedQuality(settings.quality)
        }

        let videoInput = try AVCaptureDeviceInput(device: selectedCamera)
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.automaticallyConfiguresOutputBufferDimensions = false
        video.deliversPreviewSizedOutputBuffers = false
        video.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        video.setSampleBufferDelegate(self, queue: outputQueue)

        let audio = settings.audioEnabled ? try makeAudioCapture() : nil
        try configureSession(videoInput: videoInput, video: video, audio: audio, quality: settings.quality)
        try configureCamera(selectedCamera)
        encoder = try makeEncoder(quality: settings.quality)
        camera = selectedCamera
        self.facing = facing
        activeQuality = settings.quality
        videoOutput = video
        audioOutput = audio?.output
        generation += 1
        installObservers(for: generation, camera: selectedCamera, audioEnabled: settings.audioEnabled)

        session.startRunning()
        guard session.isRunning, let clock = session.synchronizationClock else {
            throw CaptureError.couldNotStart
        }
        clockLock.withLock { captureClock = clock }
        running = true
        updateCanFlip(quality: settings.quality)
        publishCameraControls(for: selectedCamera)
        return selectedCamera
    }

    private func makeAudioCapture() throws -> (input: AVCaptureDeviceInput, output: AVCaptureAudioDataOutput) {
        guard let microphone = AVCaptureDevice.default(for: .audio) else { throw CaptureError.noMicrophone }
        let input = try AVCaptureDeviceInput(device: microphone)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: outputQueue)
        return (input, output)
    }

    private func configureSession(
        videoInput: AVCaptureDeviceInput,
        video: AVCaptureVideoDataOutput,
        audio: (input: AVCaptureDeviceInput, output: AVCaptureAudioDataOutput)?,
        quality: VideoQuality
    ) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.sessionPreset != .high, session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        session.automaticallyConfiguresApplicationAudioSession = audio != nil
        guard session.canAddInput(videoInput) else { throw CaptureError.noCamera }
        session.addInput(videoInput)
        guard session.canSetSessionPreset(quality.capturePreset) else {
            throw CaptureError.unsupportedQuality(quality)
        }
        session.sessionPreset = quality.capturePreset
        guard session.canAddOutput(video) else { throw CaptureError.unsupportedQuality(quality) }
        session.addOutput(video)
        if let audio {
            guard session.canAddInput(audio.input) else { throw CaptureError.noMicrophone }
            session.addInput(audio.input)
            guard session.canAddOutput(audio.output) else { throw CaptureError.noMicrophone }
            session.addOutput(audio.output)
        }
        if let connection = video.connection(with: .video) {
            // The movie gets an orientation transform. Keep the live video buffers in sensor space.
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
    }

    private func configureCamera(_ camera: AVCaptureDevice) throws {
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        if camera.isFocusModeSupported(.continuousAutoFocus) {
            camera.focusMode = .continuousAutoFocus
        }
        if camera.isExposureModeSupported(.continuousAutoExposure) {
            camera.exposureMode = .continuousAutoExposure
        }
        if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            camera.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if camera.activeFormat.supportedColorSpaces.contains(.sRGB) {
            camera.activeColorSpace = .sRGB
        }
        if camera.isAutoVideoFrameRateEnabled {
            camera.isAutoVideoFrameRateEnabled = false
        }
        nominalFrameDuration = CMTime(value: 1, timescale: 30)
        setFrameRate(30, onLockedCamera: camera)
        camera.videoZoomFactor = camera.minAvailableVideoZoomFactor
    }

    private func updateCanFlip(quality: VideoQuality) {
        canFlip = availableCameras(facing: facing.opposite).contains {
            $0.supportsSessionPreset(quality.capturePreset)
        }
    }

    private func zoomRange(for camera: AVCaptureDevice) -> ClosedRange<CGFloat> {
        let minimum = camera.minAvailableVideoZoomFactor
        let maximum = min(camera.maxAvailableVideoZoomFactor, camera.activeFormat.videoMaxZoomFactor)
        let hardware = minimum...max(minimum, maximum)
        guard let recommended = camera.activeFormat.systemRecommendedVideoZoomRange,
              hardware.overlaps(recommended) else { return hardware }
        return minimum...min(hardware.upperBound, recommended.upperBound)
    }

    private func zoomMultiplier(for camera: AVCaptureDevice) -> CGFloat {
        let multiplier = camera.displayVideoZoomFactorMultiplier
        return multiplier.isFinite && multiplier > 0 ? multiplier : 1
    }

    private func zoomStops(
        for camera: AVCaptureDevice, range: ClosedRange<CGFloat>, multiplier: CGFloat
    ) -> [CGFloat] {
        let switchover = camera.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let native = camera.activeFormat.secondaryNativeResolutionZoomFactors
        var labels = Set<CGFloat>()
        // Prefer the camera's exact stop when a fallback would show the same label.
        return (switchover + native + [range.lowerBound, 1 / multiplier])
            .filter { range.contains($0) && labels.insert(($0 * multiplier * 10).rounded()).inserted }
            .sorted()
    }

    private func applyZoom(_ displayFactor: CGFloat, toLockedCamera camera: AVCaptureDevice) {
        let range = zoomRange(for: camera)
        let multiplier = zoomMultiplier(for: camera)
        // Recover the exact native threshold when the user taps a displayed preset.
        let preset = zoomStops(for: camera, range: range, multiplier: multiplier).first {
            let displayStop = $0 * multiplier
            return abs(displayStop - displayFactor) < 0.000001
                || (displayFactor == 1 && (displayStop * 10).rounded() == 10)
        }
        let requested = preset ?? displayFactor / multiplier
        let factor = min(max(requested, range.lowerBound), range.upperBound)
        if camera.videoZoomFactor != factor {
            camera.videoZoomFactor = factor
        }
    }

    private func publishCameraControls(for camera: AVCaptureDevice) {
        let range = zoomRange(for: camera)
        let multiplier = zoomMultiplier(for: camera)
        let current = min(max(camera.videoZoomFactor, range.lowerBound), range.upperBound)
        let presets = zoomStops(for: camera, range: range, multiplier: multiplier).map { Double($0 * multiplier) }
        let controls = CameraControls(
            zoom: CameraZoomState(factor: Double(current * multiplier),
                                  minimum: Double(range.lowerBound * multiplier),
                                  maximum: Double(range.upperBound * multiplier),
                                  presets: presets),
            canFlip: canFlip,
            facingFront: facing == .front
        )
        guard controls != lastControls else { return }
        lastControls = controls
        onCameraControls(controls)
    }

    private func setFrameRate(_ rate: Int32, onLockedCamera camera: AVCaptureDevice) {
        let supported = camera.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= Double(rate) && Double(rate) <= $0.maxFrameRate
        }
        guard supported else { return }
        let frameDuration = CMTime(value: 1, timescale: rate)
        camera.activeVideoMinFrameDuration = frameDuration
        nominalFrameDuration = frameDuration
    }

    private func installObservers(for generation: Int, camera: AVCaptureDevice, audioEnabled: Bool) {
        let center = NotificationCenter.default
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: nil) {
                [weak self] _ in self?.handleInterruption(generation: generation)
            })
        }
        if audioEnabled {
            observers.append(center.addObserver(
                forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: nil
            ) { [weak self] notification in
                guard let context = notification.userInfo?[AVAudioSession.deactivationContextKey]
                        as? AVAudioSession.DeactivationContext,
                      context.source == .system else { return }
                self?.handleInterruption(generation: generation)
            })
        }
        pressureObservation = camera.observe(\.systemPressureState, options: [.new]) { [weak self] _, change in
            guard let pressure = change.newValue?.level else { return }
            self?.captureQueue.async { [weak self] in
                guard let self, self.generation == generation, let camera = self.camera, self.running else { return }
                if pressure == .serious || pressure == .critical {
                    do {
                        try camera.lockForConfiguration()
                        self.setFrameRate(24, onLockedCamera: camera)
                        camera.unlockForConfiguration()
                    } catch {
                        // AVFoundation reports a session interruption if capture can't continue.
                    }
                } else if pressure == .shutdown {
                    self.interruptCapture()
                }
            }
        }
        let zoomProperties: [KeyPath<AVCaptureDevice, CGFloat>] = [
            \.videoZoomFactor, \.minAvailableVideoZoomFactor, \.maxAvailableVideoZoomFactor,
            \.displayVideoZoomFactorMultiplier
        ]
        zoomObservers = zoomProperties.map { property in
            camera.observe(property, options: [.new]) { [weak self] _, _ in
                self?.captureQueue.async { [weak self] in
                    guard let self, self.running, self.generation == generation, let camera = self.camera else {
                        return
                    }
                    self.publishCameraControls(for: camera)
                }
            }
        }
    }

    private func handleInterruption(generation: Int) {
        captureQueue.async {
            guard self.generation == generation else { return }
            self.interruptCapture()
        }
    }

    private func interruptCapture() {
        guard running else { return }
        stopCapture()
        onInterruption()
    }

    private func stopCapture() {
        running = false
        generation += 1
        clockLock.withLock { captureClock = nil }
        pressureObservation = nil
        zoomObservers.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if session.isRunning { session.stopRunning() }
        if let encoder {
            VTCompressionSessionInvalidate(encoder)
            self.encoder = nil
        }
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        if !session.inputs.isEmpty || !session.outputs.isEmpty {
            session.beginConfiguration()
            session.outputs.forEach(session.removeOutput)
            session.inputs.forEach(session.removeInput)
            session.commitConfiguration()
        }
        camera = nil
        activeQuality = nil
        canFlip = false
        lastControls = nil
        videoOutput = nil
        audioOutput = nil
        audioFormat = nil
    }

    private func makeEncoder(quality: VideoQuality) throws -> VTCompressionSession {
        let (width, height) = quality.captureDimensions
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
            encoderSpecification: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
            ] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw CaptureError.couldNotEncode(quality) }

        let bitrate = quality.videoBitrate
        let settings: [String: Any] = [
            kVTCompressionPropertyKey_RealTime as String: true,
            kVTCompressionPropertyKey_AllowFrameReordering as String: false,
            kVTCompressionPropertyKey_ExpectedFrameRate as String: 30,
            kVTCompressionPropertyKey_MaxKeyFrameInterval as String: 30,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration as String: 1.0,
            kVTCompressionPropertyKey_AverageBitRate as String: bitrate,
            kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_H264_Main_AutoLevel
        ]
        guard VTSessionSetProperties(session, propertyDictionary: settings as CFDictionary) == noErr else {
            VTCompressionSessionInvalidate(session)
            throw CaptureError.couldNotEncode(quality)
        }
        // Older encoders can omit optional properties. The ring has an independent memory limit.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowOpenGOP, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 2 as CFNumber)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_DataRateLimits,
            value: [bitrate / 8 * 2, 1] as CFArray
        )
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            throw CaptureError.couldNotEncode(quality)
        }
        return session
    }

    private struct MediaSample: @unchecked Sendable {
        let sample: CMSampleBuffer
    }

    private func encodeVideo(_ sample: CMSampleBuffer) {
        guard let encoder, let pixelBuffer = sample.imageBuffer, sample.presentationTimeStamp.isNumeric else { return }
        let duration = sample.duration.isNumeric && sample.duration > .zero ? sample.duration : nominalFrameDuration
        let generation = generation
        let status = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: pixelBuffer, presentationTimeStamp: sample.presentationTimeStamp,
            duration: duration, frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, flags, output in
            guard let self else { return }
            if status != noErr {
                self.handleInterruption(generation: generation)
            } else if !flags.contains(.frameDropped), let output {
                let frame = MediaSample(sample: output)
                self.captureQueue.async {
                    guard self.running, self.generation == generation else { return }
                    self.onVideo(frame.sample)
                }
            }
        }
        if status != noErr { interruptCapture() }
    }

    private func handleSample(_ sample: CMSampleBuffer, output: AVCaptureOutput) {
        guard running else { return }
        if output === videoOutput {
            encodeVideo(sample)
        } else if output === audioOutput, let format = sample.formatDescription {
            if let audioFormat, !CMFormatDescriptionEqual(audioFormat, otherFormatDescription: format) {
                interruptCapture()
                return
            }
            audioFormat = format
            onAudio(sample)
        }
    }

    private enum CaptureError: LocalizedError {
        case noCamera, noMicrophone, couldNotStart, cameraDirectionsUnavailable
        case unsupportedQuality(VideoQuality), couldNotEncode(VideoQuality)

        var errorDescription: String? {
            switch self {
            case .noCamera: "The selected camera is unavailable."
            case .noMicrophone: "The microphone is unavailable."
            case .couldNotStart: "The camera couldn't start. Try again."
            case .cameraDirectionsUnavailable: "The camera preview isn’t ready. Try again."
            case .unsupportedQuality(let quality):
                "This camera doesn’t support \(quality.captureResolution). Choose a different video quality in Settings."
            case .couldNotEncode(let quality):
                "The encoder couldn’t start at \(quality.captureResolution). Try again or choose a lower video quality."
            }
        }
    }
}

private extension VideoQuality {
    var capturePreset: AVCaptureSession.Preset {
        switch self {
        case .hd: .hd1280x720
        case .fullHD: .hd1920x1080
        case .ultraHD: .hd4K3840x2160
        }
    }

    var captureDimensions: (Int32, Int32) {
        switch self {
        case .hd: (1280, 720)
        case .fullHD: (1920, 1080)
        case .ultraHD: (3840, 2160)
        }
    }

    var captureResolution: String {
        switch self {
        case .hd: "720p"
        case .fullHD: "1080p"
        case .ultraHD: "4K"
        }
    }
}

extension CaptureService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Session start/stop can wait for output callbacks. Keep this queue free to return,
        // and cap the number of capture-owned buffers retained across the handoff.
        let pending = output is AVCaptureVideoDataOutput ? pendingVideo : pendingAudio
        guard pending.wait(timeout: .now()) == .success else { return }
        let frame = MediaSample(sample: sampleBuffer)
        captureQueue.async {
            defer { pending.signal() }
            self.handleSample(frame.sample, output: output)
        }
    }
}
