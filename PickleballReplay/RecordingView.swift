import AVFoundation
import AVKit
import Observation
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct RecordingView: View {
    let model: RecordingModel

    @AppStorage("dimPreviewWhenReady") private var dimsScreen = false
    @State private var preview = PreviewReference()
    @State private var screenDimmer = RecordingScreenDimmer()
    @State private var dimmingTimerGeneration = 0
    @State private var showingSettings = false
    @State private var showsSaveFeedback = false
    @State private var saveRegionFlash: UUID?
    @State private var zoomAtPinchStart: Double?
    @State private var lastCameraControls: CameraControls?
    @State private var zoomPresetSlots: Int?
    @GestureState private var isPinching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase

    private let courtGreen = Color(red: 0.78, green: 0.97, blue: 0.41)
    private let saveRegionShape = RoundedRectangle(cornerRadius: 16)
    private let zoomButtonWidth: CGFloat = 44
    private let zoomCapsulePadding: CGFloat = 3
    private let cameraToolbarHeight: CGFloat = 50
    private let cameraToolbarBottomInset: CGFloat = 46

    private var deviceRotation: Angle {
        switch model.deviceOrientation {
        case .landscapeLeft: .degrees(90)
        case .landscapeRight: .degrees(-90)
        case .portraitUpsideDown: .degrees(180)
        default: .zero
        }
    }

    private var dimmingTimerID: Int? {
        dimsScreen && scenePhase == .active && !showingSettings ? dimmingTimerGeneration : nil
    }

    var body: some View {
        GeometryReader { viewport in
            let previewFrame = cameraLayout(in: viewport)

            ZStack {
                GeometryReader { _ in
                    CameraPreview(capture: model.capture, reference: preview, onGeometryReady: startOnActivePreview)
                        .frame(width: previewFrame.width, height: previewFrame.height)
                        .position(x: previewFrame.midX, y: previewFrame.midY)
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)

                if let replay = model.playingReplay {
                    replayDisplay { _ in
                        SavedReplayPlayer(replay: replay, model: model, preview: preview,
                                          onClose: model.finishReplayPlayback)
                    }
                } else if !model.blockedRequiredPermissions.isEmpty {
                    RequiredPermissionsView(
                        permissions: model.blockedRequiredPermissions,
                        accent: courtGreen,
                        openSettings: model.openPermissionSettings
                    )
                    .overlay(alignment: .topTrailing) {
                        settingsGear()
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                } else if let replay = model.recentReplay, model.phase != .idle, saveRegionFlash == nil {
                    replayCover(replay)
                        .accessibilityAction(.escape) { model.dismissRecentReplay(id: replay.id) }
                } else {
                    cameraWithAccessory(previewFrame: previewFrame)
                        .task(id: dimmingTimerID) { [timerID = dimmingTimerID] in
                            await dimScreenAfterInactivity(timerID: timerID)
                        }
                        .onDisappear { screenDimmer.restore() }
                }
            }
        }
        .background { Color.black.ignoresSafeArea() }
        .preferredColorScheme(.dark)
        .task {
            let device = UIDevice.current
            device.beginGeneratingDeviceOrientationNotifications()
            defer { device.endGeneratingDeviceOrientationNotifications() }

            model.refreshDeviceOrientation()
            for await _ in NotificationCenter.default.notifications(named: UIDevice.orientationDidChangeNotification) {
                model.refreshDeviceOrientation()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
            startOnActivePreview()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            model.didEnterBackground()
            showingSettings = false
            saveRegionFlash = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { notification in
            guard let scene = preview.view?.window?.windowScene, notification.object as? UIScene === scene else { return }
            screenDimmer.restore()
        }
        .sheet(isPresented: $showingSettings, onDismiss: model.applyRecordingSettingsIfNeeded) {
            FootageSettingsView(model: model, dimsScreen: $dimsScreen)
                .tint(courtGreen)
                .recordingPermissionPrompts(model)
        }
        .recordingPermissionPrompts(model, enabled: !showingSettings && !model.isSaving)
        .task(id: model.status) {
            guard let status = model.status else {
                showsSaveFeedback = false
                return
            }
            showsSaveFeedback = true
            AccessibilityNotification.Announcement(status).post()
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { showsSaveFeedback = false }
        }
        .task(id: saveRegionFlash) {
            guard saveRegionFlash != nil else { return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    saveRegionFlash = nil
                }
            }
        }
        .onChange(of: isPinching) { _, pinching in
            if !pinching { zoomAtPinchStart = nil }
        }
        .onChange(of: model.cameraControls, initial: true) { _, controls in
            guard let controls else { return }
            lastCameraControls = controls
            zoomPresetSlots = zoomPresetSlots ?? controls.zoom.presets.count
        }
    }

    private func startOnActivePreview() {
        preview.refreshVideoAspect()
        guard preview.view?.window?.windowScene?.activationState == .foregroundActive else { return }
        model.startWhenActive()
    }

    private func dimScreenAfterInactivity(timerID: Int?) async {
        guard !Task.isCancelled else { return }
        screenDimmer.restore()
        guard let timerID else { return }
        do {
            try await Task.sleep(for: .seconds(15))
        } catch {
            return
        }
        guard !Task.isCancelled, timerID == dimmingTimerID,
              let scene = preview.view?.window?.windowScene,
              scene.activationState == .foregroundActive else { return }
        screenDimmer.dim(scene.screen, animated: !reduceMotion)
    }

    private func restartDimmingTimer() {
        screenDimmer.restore()
        if dimsScreen { dimmingTimerGeneration &+= 1 }
    }

    private func replayDisplay<Content: View>(@ViewBuilder content: @escaping (CGSize) -> Content) -> some View {
        GeometryReader { screen in
            let viewport = model.deviceOrientation.isLandscape
                ? CGSize(width: screen.size.height, height: screen.size.width)
                : screen.size

            content(viewport)
                .frame(width: viewport.width, height: viewport.height)
                .rotationEffect(deviceRotation)
                .position(x: screen.size.width / 2, y: screen.size.height / 2)
        }
        .background { Color.black.ignoresSafeArea() }
    }

    private func replayCover(_ replay: SavedReplay) -> some View {
        replayDisplay { viewport in
            let frame = replay.thumbnail
            let region = frame.map {
                let image = AVMakeRect(aspectRatio: CGSize(width: $0.width, height: $0.height),
                                       insideRect: CGRect(origin: .zero, size: viewport))
                return saveRegion(for: image)
            }
            let cardWidth = min((region?.width ?? viewport.width) * 0.88, 350)
            let confirmation = ViewThatFits(in: .vertical) {
                replayConfirmation(for: replay, spacing: 32)

                ScrollView {
                    replayConfirmation(for: replay, spacing: 16)
                }
                .defaultScrollAnchor(.center, for: .alignment)
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(width: cardWidth)

            ZStack {
                if let frame, let region {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: region.width, height: region.height)
                        .clipShape(saveRegionShape)
                        .overlay { confirmation }
                } else {
                    confirmation
                }
            }
        }
    }

    private func replayConfirmation(for replay: SavedReplay, spacing: CGFloat) -> some View {
        let duration = Duration.seconds(replay.durationSeconds).formatted(.units(
            allowed: [.hours, .minutes, .seconds],
            width: .wide,
            fractionalPart: replay.durationSeconds < 1 ? .show(length: 2) : .hide
        ))
        let seconds = model.replaySecondsRemaining

        return VStack(spacing: spacing) {
            Text(duration)
                .font(.title3.weight(.regular))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color(white: 0.15), in: Capsule())
                .accessibilityIdentifier("replaySavedConfirmation")

            Button(action: model.openRecentReplay) {
                replayButtonLabel(Text("Play video"), foreground: .black, fill: courtGreen)
            }
            .accessibilityHint("Plays the replay just added to Photos")
            .accessibilityIdentifier("playSavedReplay")

            Button {
                model.dismissRecentReplay(id: replay.id)
            } label: {
                replayButtonLabel(Text("Ready for next (\(seconds)s)"), foreground: .white, fill: Color(white: 0.25))
            }
            .accessibilityLabel("Ready for next")
            .accessibilityValue("\(seconds) seconds")
            .accessibilityIdentifier("readyForNextReplay")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private func replayButtonLabel(_ title: Text, foreground: Color, fill: Color) -> some View {
        title
            .font(.headline)
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
    }

    @ViewBuilder
    private func cameraWithAccessory(previewFrame: CGRect) -> some View {
        if #available(iOS 27.1, *) {
            cameraScreen(previewFrame: previewFrame).sceneAccessory {
                if model.phase == .recording && !showingSettings {
                    CameraCaptureAccessory {
                        ReplayCaptureAccessoryView(model: model, accent: courtGreen, onBackgroundTouch: restartDimmingTimer)
                    }
                }
            }
        } else {
            cameraScreen(previewFrame: previewFrame)
        }
    }

    private func cameraScreen(previewFrame: CGRect) -> some View {
        let isRecording = model.phase == .recording
        let canUseCameraControls = isRecording && scenePhase == .active
        let camera = canUseCameraControls ? model.cameraControls : nil
        let showCameraControls = scenePhase == .active && (isRecording || model.phase == .starting)

        return ZStack {
            if model.demoMode && isRecording {
                GeometryReader { _ in
                    let video = previewFrame
                    CourtArtwork()
                        .padding(.horizontal, video.width * 0.08)
                        .padding(.vertical, video.height * 0.20)
                        .scaleEffect(model.cameraControls?.zoom.factor ?? 1)
                        .frame(width: video.width, height: video.height)
                        .background(Color(red: 0.10, green: 0.35, blue: 0.26))
                        .clipped()
                        .position(x: video.midX, y: video.midY)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            if camera != nil {
                previewInteraction(in: previewFrame)
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(RecordingTouchObserver { _ in restartDimmingTimer() })
                    .ignoresSafeArea()
            }

            if showCameraControls, let displayedCamera = camera ?? lastCameraControls {
                FixedCameraToolbar(bottomInset: cameraToolbarBottomInset) {
                    cameraAccessories(displayedCamera)
                        .disabled(camera == nil)
                }
                .ignoresSafeArea()
            } else if model.phase == .idle, model.status != nil {
                FixedCameraToolbar(bottomInset: cameraToolbarBottomInset) {
                    settingsGear()
                        .frame(height: cameraToolbarHeight)
                }
                .ignoresSafeArea()
            }

            if model.phase == .starting || (canUseCameraControls && camera == nil) {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel("Starting camera")
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                feedbackToast.allowsHitTesting(false)
                if scenePhase == .active && model.canRetryCamera {
                    Button("Try again", action: model.retryCamera)
                        .buttonStyle(.borderedProminent)
                        .tint(courtGreen)
                        .foregroundStyle(.black)
                        .accessibilityIdentifier("retryCamera")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
        }
    }

    private func previewInteraction(in previewFrame: CGRect) -> some View {
        let pinch = MagnifyGesture()
            .updating($isPinching) { _, pinching, _ in pinching = true }
            .onChanged { value in
                guard let zoom = model.cameraControls?.zoom else { return }
                let initial = zoomAtPinchStart ?? zoom.factor
                zoomAtPinchStart = initial
                model.setZoom(initial * Double(value.magnification))
            }

        return GeometryReader { _ in
            let isInSaveArea: (CGPoint) -> Bool = { location in
                guard let region = liveSaveRegion(in: previewFrame) else { return false }
                return saveRegionShape.path(in: region).contains(location)
            }
            let tap = SpatialTapGesture().onEnded { value in
                if isInSaveArea(value.location) {
                    saveFromPreview()
                }
            }

            Color.clear
                .accessibilityHidden(true)
                .overlay {
                    if let region = liveSaveRegion(in: previewFrame) {
                        Color.clear
                            .frame(width: region.width, height: region.height)
                            .overlay { saveRegionFeedback.opacity(saveRegionFlash == nil ? 0 : 1) }
                            .contentShape(saveRegionShape)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Save replay")
                            .accessibilityHint(saveHint)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { saveFromPreview() }
                            .accessibilityZoomAction { action in
                                guard let zoom = model.cameraControls?.zoom else { return }
                                restartDimmingTimer()
                                switch action.direction {
                                case .zoomIn: model.setZoom(zoom.factor * 1.2)
                                case .zoomOut: model.setZoom(zoom.factor / 1.2)
                                @unknown default: break
                                }
                            }
                            .accessibilitySortPriority(2)
                            .accessibilityIdentifier("saveReplay")
                            .position(x: region.midX, y: region.midY)
                    }
                }
                .contentShape(Rectangle())
                .gesture(pinch.exclusively(before: tap))
                .gesture(RecordingTouchObserver { location in
                    if !isInSaveArea(location) { restartDimmingTimer() }
                })
        }
        .ignoresSafeArea()
        .onDisappear { saveRegionFlash = nil }
    }

    private func previewSize(in viewport: GeometryProxy) -> CGSize {
        let insets = viewport.safeAreaInsets
        return CGSize(width: viewport.size.width + insets.leading + insets.trailing,
                      height: viewport.size.height + insets.top + insets.bottom)
    }

    private func liveSaveRegion(in frame: CGRect) -> CGRect? {
        if model.demoMode { return saveRegion(for: frame) }
        guard let video = preview.videoRect(in: frame.size) else { return nil }
        return saveRegion(for: video.offsetBy(dx: frame.minX, dy: frame.minY))
    }

    private func saveRegion(for video: CGRect) -> CGRect {
        return video.insetBy(dx: video.width * 0.1, dy: video.height * 0.1)
    }

    private var saveRegionFeedback: some View {
        saveRegionShape.fill(.white.opacity(0.20))
            .overlay { saveRegionShape.strokeBorder(courtGreen, lineWidth: 2) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func saveFromPreview() {
        guard model.canSaveReplay else { return }
        saveRegionFlash = UUID()
        model.saveReplay()
    }

    private func cameraLayout(in viewport: GeometryProxy) -> CGRect {
        let size = previewSize(in: viewport)
        let screen = CGRect(origin: .zero, size: size)
        let landscape = size.width > size.height
        let aspect: CGSize?
        if model.demoMode {
            aspect = CGSize(width: 9, height: 16)
        } else {
            aspect = preview.videoAspect.map { CGSize(width: $0, height: 1) }
        }

        let insets = viewport.safeAreaInsets
        let rightToLeft = layoutDirection == .rightToLeft
        let leftInset = rightToLeft ? insets.trailing : insets.leading
        let rightInset = rightToLeft ? insets.leading : insets.trailing
        guard landscape else {
            guard let aspect else { return screen }
            let fitted = AVMakeRect(aspectRatio: aspect, insideRect: screen)
            return fitted.offsetBy(dx: 0, dy: min(0, insets.top - fitted.minY))
        }

        let toolbarSpace = cameraToolbarBottomInset + cameraToolbarHeight + 6
        let right = max(rightInset, toolbarSpace)
        let area = CGRect(x: leftInset, y: 0, width: max(0, size.width - leftInset - right), height: size.height)
        let fitted = aspect.map { AVMakeRect(aspectRatio: $0, insideRect: area) } ?? area
        return CGRect(x: area.minX, y: fitted.minY, width: fitted.width, height: fitted.height)
    }

    private func cameraAccessories(_ camera: CameraControls) -> some View {
        let zoom = camera.zoom
        let zoomLength = CGFloat(zoomPresetSlots ?? zoom.presets.count) * zoomButtonWidth + 2 * zoomCapsulePadding
        let atPreset = zoom.presets.contains { abs($0 - zoom.factor) < 0.05 }
        let visiblePresets = zoom.presets.filter { !camera.facingFront || ($0 * 10).rounded() != 10 }

        return VStack(spacing: 6) {
            if !atPreset {
                Text("\(zoomTitle(zoom.factor))×")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .rotationEffect(deviceRotation)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.84), in: Capsule())
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Current zoom \(zoomTitle(zoom.factor)) times")
                    .accessibilityIdentifier("currentZoom")
            }

            HStack(spacing: 8) {
                zoomPicker(visiblePresets, factor: zoom.factor)
                    .frame(minWidth: 0, maxWidth: zoomLength, alignment: .trailing)
                    .frame(height: cameraToolbarHeight)
                if camera.canFlip { cameraFlipButton(camera) }
                settingsGear()
            }
        }
        .frame(maxWidth: 360)
        .foregroundStyle(.white)
        .gesture(RecordingTouchObserver { _ in restartDimmingTimer() })
    }

    @ViewBuilder
    private func zoomPicker(_ presets: [Double], factor: Double) -> some View {
        if presets.isEmpty {
            Color.clear.allowsHitTesting(false).accessibilityHidden(true)
        } else {
            ViewThatFits(in: .horizontal) {
                zoomPresets(presets, factor: factor).fixedSize(horizontal: true, vertical: false)

                ScrollView(.horizontal) {
                    zoomPresets(presets, factor: factor)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private func zoomPresets(_ presets: [Double], factor: Double) -> some View {
        HStack(spacing: 0) {
            ForEach(presets, id: \.self) { preset in
                let selected = abs(factor - preset) < 0.05
                Button {
                    model.setZoom(preset)
                } label: {
                    Text("\(zoomTitle(preset))×")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .foregroundStyle(selected ? courtGreen : .white)
                        .rotationEffect(deviceRotation)
                        .frame(width: zoomButtonWidth, height: zoomButtonWidth)
                        .background(selected ? .white.opacity(0.18) : .clear, in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel("Zoom \(zoomTitle(preset)) times")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("zoomPreset_\(preset)")
            }
        }
        .padding(zoomCapsulePadding)
        .background {
            Capsule().fill(.black.opacity(0.84)).allowsHitTesting(false)
        }
        .buttonStyle(.plain)
    }

    private func cameraFlipButton(_ camera: CameraControls) -> some View {
        Button(action: model.flipCamera) {
            cameraControlIcon("arrow.triangle.2.circlepath.camera", labelRotation: deviceRotation)
        }
        .buttonStyle(.plain)
        .disabled(model.isSaving)
        .accessibilityLabel(camera.facingFront ? "Switch to rear camera" : "Switch to front camera")
        .accessibilityHint("Starts a fresh replay buffer")
        .accessibilityIdentifier("flipCamera")
    }

    private func settingsGear() -> some View {
        Button {
            saveRegionFlash = nil
            showingSettings = true
        } label: {
            cameraControlIcon("gearshape", labelRotation: deviceRotation)
        }
        .buttonStyle(.plain)
        .disabled(model.isSaving)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("recordingSettings")
    }

    private func cameraControlIcon(_ symbol: String, labelRotation: Angle) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .rotationEffect(labelRotation)
            .frame(width: 46, height: 46)
            .background(.black.opacity(0.84), in: Circle())
            .contentShape(Circle())
    }

    private func zoomTitle(_ factor: Double) -> String {
        factor.formatted(.number.precision(.fractionLength(0...1)))
    }

    @ViewBuilder
    private var feedbackToast: some View {
        if let status = model.status, showsSaveFeedback || model.phase != .recording {
            toast(status)
        }
    }

    private func toast(_ message: String) -> some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 13))
            .frame(maxWidth: 320)
            .accessibilityIdentifier("recordingStatus")
    }

    private var saveHint: Text {
        let options = model.activeSettings
        let duration = Duration.seconds(options.clipDuration)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
        if options.ignoredSeconds == 0 {
            return Text("Saves up to the last \(duration)")
        }
        let skipped = Duration.seconds(options.ignoredSeconds).formatted(.units(allowed: [.seconds], width: .wide))
        return Text("Saves up to \(duration), skipping the last \(skipped)")
    }
}

private struct FixedCameraToolbar<Content: View>: UIViewControllerRepresentable {
    let bottomInset: CGFloat
    @ViewBuilder let content: Content

    func makeUIViewController(context: Context) -> Controller {
        Controller(content: content, bottomInset: bottomInset)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.controls.rootView = content
        controller.view.setNeedsLayout()
    }

    final class Controller: UIViewController {
        let controls: UIHostingController<Content>
        private let bottomInset: CGFloat
        private let portraitSurface = UIView()
        private let counterRotationSurface = UIView()
        private var isRotating = false

        init(content: Content, bottomInset: CGFloat) {
            controls = UIHostingController(rootView: content)
            self.bottomInset = bottomInset
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("Use init(content:bottomInset:)") }

        override func loadView() {
            view = ToolbarHitView(controlsView: controls.view)
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            controls.safeAreaRegions = []
            controls.view.backgroundColor = .clear
            view.addSubview(portraitSurface)
            portraitSurface.addSubview(counterRotationSurface)
            addChild(controls)
            counterRotationSurface.addSubview(controls.view)
            controls.didMove(toParent: self)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if !isRotating { layoutInScreenCoordinates() }
        }

        override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            guard !coordinator.targetTransform.isIdentity else { return }
            isRotating = true
            // The portrait surface shares the window's pivot and cancels its rotation.
            let rotation = coordinator.targetTransform
            let halfTurn = CGAffineTransform(rotationAngle: -atan2(rotation.b, rotation.a) / 2)
            let transform = portraitSurface.transform.concatenating(halfTurn)
            let registered = coordinator.animate(alongsideTransition: { [weak self] _ in
                self?.portraitSurface.center = CGPoint(x: size.width / 2, y: size.height / 2)
                self?.portraitSurface.transform = transform
                // Two shorter arcs preserve the direction of a 180-degree turn.
                self?.counterRotationSurface.transform = halfTurn
            }, completion: { [weak self] _ in
                self?.isRotating = false
                self?.layoutInScreenCoordinates()
            })
            if !registered { isRotating = false }
        }

        private func layoutInScreenCoordinates() {
            guard let space = view.window?.windowScene?.screen.fixedCoordinateSpace,
                  !view.bounds.isEmpty else { return }
            let portraitBounds = view.convert(view.bounds, to: space)
            let center = CGPoint(x: portraitBounds.midX, y: portraitBounds.midY)
            let origin = space.convert(center, to: view)
            let unitX = space.convert(CGPoint(x: center.x + 1, y: center.y), to: view)
            let angle = atan2(unitX.y - origin.y, unitX.x - origin.x)
            portraitSurface.bounds = CGRect(origin: .zero, size: portraitBounds.size)
            portraitSurface.center = origin
            portraitSurface.transform = CGAffineTransform(rotationAngle: angle)
            counterRotationSurface.transform = .identity
            counterRotationSurface.frame = portraitSurface.bounds

            let proposedSize = CGSize(width: max(0, portraitBounds.width - 32), height: portraitBounds.height)
            let size = controls.sizeThatFits(in: proposedSize)
            controls.view.frame = CGRect(x: (portraitBounds.width - size.width) / 2,
                                         y: portraitBounds.height - bottomInset - size.height,
                                         width: size.width, height: size.height)
        }
    }

    private final class ToolbarHitView: UIView {
        let controlsView: UIView

        init(controlsView: UIView) {
            self.controlsView = controlsView
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("Use init(controlsView:)") }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            controlsView.point(inside: convert(point, to: controlsView), with: event)
        }
    }
}

@MainActor
private final class RecordingScreenDimmer {
    private var original: (screen: UIScreen, brightness: CGFloat)?
    private var fade: Task<Void, Never>?

    func dim(_ screen: UIScreen, animated: Bool) {
        guard original?.screen !== screen else { return }
        restore()

        let brightness = screen.brightness
        let target = min(brightness, max(0.08, brightness * 0.22))
        guard target < brightness else { return }
        original = (screen, brightness)

        guard animated else {
            screen.brightness = target
            return
        }

        fade = Task {
            let steps = 20
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                let progress = CGFloat(step) / CGFloat(steps)
                screen.brightness = brightness + (target - brightness) * progress
            }
        }
    }

    func restore() {
        fade?.cancel()
        fade = nil
        if let original {
            self.original = nil
            original.screen.brightness = original.brightness
        }
    }
}

private struct RecordingTouchObserver: UIGestureRecognizerRepresentable {
    let onTouch: @MainActor (CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> TouchRecognizer {
        let recognizer = TouchRecognizer(target: nil, action: nil)
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: TouchRecognizer, context: Context) {
        recognizer.onTouch = { onTouch(context.converter.localLocation) }
    }

    final class TouchRecognizer: UIGestureRecognizer {
        var onTouch: (@MainActor () -> Void)?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouch?()
            // Observe the touch without recognizing a gesture that could compete with saving or zooming.
            state = .failed
        }
    }
}

private struct ReplayCaptureAccessoryView: View {
    let model: RecordingModel
    let accent: Color
    let onBackgroundTouch: @MainActor () -> Void
    @State private var feedback: String?

    var body: some View {
        GeometryReader { display in
            let insets = display.safeAreaInsets
            let sideMargin = max(24, insets.leading, insets.trailing)
            let verticalMargin = max(12, insets.top, insets.bottom)

            controls
                .frame(maxWidth: 320)
                .padding(.leading, sideMargin - insets.leading)
                .padding(.trailing, sideMargin - insets.trailing)
                .padding(.top, verticalMargin - insets.top)
                .padding(.bottom, verticalMargin - insets.bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            Color.black
                .gesture(RecordingTouchObserver { _ in onBackgroundTouch() })
                .ignoresSafeArea()
        }
        .overlay(alignment: .bottom) {
            if let feedback {
                Text(feedback)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(16)
            }
        }
        .preferredColorScheme(.dark)
        .task(id: model.status) {
            feedback = model.status
            guard feedback != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { feedback = nil }
        }
    }

    private var controls: some View {
        let duration = Double(model.activeSettings.clipDuration)
        let available = model.availableSeconds.isFinite ? min(duration, max(0, model.availableSeconds)) : 0

        return VStack(spacing: 20) {
            if model.isBufferFull {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(accent)
            } else {
                VStack(spacing: 8) {
                    Text("Filling buffer")
                        .font(.headline)
                    ProgressView(value: available, total: duration)
                        .tint(accent)
                        .accessibilityLabel("Replay buffer")
                }
            }

            Button {
                model.saveReplay(showsThumbnail: false)
            } label: {
                Label(model.isSaving ? "Saving…" : "Save Replay", systemImage: "arrow.down.to.line")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(accent)
            .foregroundStyle(.black)
            .disabled(!model.canSaveReplay || available <= 0)
            .accessibilityHint("Saves recent footage to Photos")
            .accessibilityIdentifier("outerSaveReplay")
        }
    }
}

private struct SavedReplayPlayer: View {
    private enum PlaybackSpeed: Float, CaseIterable {
        case normal = 1, half = 0.5, quarter = 0.25

        var title: String {
            switch self {
            case .normal: "1×"
            case .half: "½×"
            case .quarter: "¼×"
            }
        }

        var accessibilityLabel: Text {
            switch self {
            case .normal: Text("Normal speed")
            case .half: Text("Half speed")
            case .quarter: Text("Quarter speed")
            }
        }
    }

    let replay: SavedReplay
    let model: RecordingModel
    let preview: PreviewReference
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var isMuted = false
    @State private var isPlaying = false
    @State private var playbackSpeed = PlaybackSpeed.normal
    @State private var canStepBackward = false
    @State private var canStepForward = false
    @State private var playbackEnded = false
    @State private var playbackSeconds: Double = 0
    @State private var playbackTimeObserver: Any?
    @State private var scrubSeconds: Double?
    @State private var resumeAfterScrub = false
    @State private var scrubTask: Task<Void, Never>?

    private var hasPlaybackFocus: Bool {
        scenePhase == .active && preview.isSceneFrontmost
    }

    var body: some View {
        ZStack {
            Color.black
            if let player, let item = player.currentItem {
                VideoPlayer(player: player)
                    .accessibilityIdentifier("savedReplayPlayer")
                    .onReceive(player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main)) { status in
                        isPlaying = status != .paused
                        if status == .playing { playbackEnded = false }
                    }
                    .onReceive(item.publisher(for: \.status).receive(on: DispatchQueue.main)) { _ in
                        canStepBackward = item.canStepBackward
                        canStepForward = item.canStepForward
                    }
            }
        }
        .overlay {
            ZStack {
                if playbackEnded {
                    Button(action: playAgain) {
                        Label("Play again", systemImage: "arrow.counterclockwise")
                    }
                    .accessibilityIdentifier("replayPlayAgain")
                }

                Button("Close", action: closePlayback)
                    .accessibilityIdentifier("closeSavedReplay")
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .font(.headline)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(Color(white: 0.18).opacity(0.94))
            .foregroundStyle(.white)
        }
        .overlay(alignment: .bottom) {
            if player != nil {
                playbackControls
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.activeSettings.audioEnabled, let player {
                Button {
                    isMuted.toggle()
                    player.isMuted = isMuted
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.84), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isMuted ? "Unmute replay audio" : "Mute replay audio")
                .accessibilityHint(isMuted ? "Use headphones to keep playback out of the next recording" : "")
                .accessibilityIdentifier("toggleReplayAudio")
                .padding(16)
            }
        }
        .accessibilityAction(.escape, closePlayback)
        .task {
            let player = AVPlayer(url: replay.url)
            player.audiovisualBackgroundPlaybackPolicy = .pauses
            isMuted = model.activeSettings.audioEnabled
            player.isMuted = isMuted
            self.player = player
            playbackSeconds = 0
            playbackTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak player] time in
                MainActor.assumeIsolated {
                    guard let player, self.player === player, time.seconds.isFinite else { return }
                    playbackSeconds = max(0, time.seconds)
                }
            }
            if hasPlaybackFocus { player.play() }
        }
        .onChange(of: hasPlaybackFocus) { _, focused in
            if !focused {
                resumeAfterScrub = false
                player?.pause()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
            playbackEnded = true
            playbackSeconds = replay.durationSeconds
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.timeJumpedNotification)
            .receive(on: DispatchQueue.main)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === player?.currentItem,
                  item.currentTime().seconds.isFinite else { return }
            playbackSeconds = max(0, item.currentTime().seconds)
            if playbackSeconds < replay.durationSeconds { playbackEnded = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { notification in
            guard let scene = preview.view?.window?.windowScene, notification.object as? UIScene === scene else { return }
            player?.pause()
        }
        .onDisappear(perform: stopPlayback)
    }

    private var playbackControls: some View {
        VStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    transportButtons
                    speedButtons
                }
                VStack(spacing: 4) {
                    transportButtons
                    speedButtons
                }
            }
            .font(.callout.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .disabled(scrubSeconds != nil)

            if replay.durationSeconds.isFinite, replay.durationSeconds > 0 {
                playbackTimeline
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.8), in: .rect(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var transportButtons: some View {
        HStack(spacing: 2) {
            Button {
                stepFrame(by: -1)
            } label: {
                Image(systemName: "backward.frame.fill")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Previous frame")
            .accessibilityIdentifier("previousReplayFrame")
            .disabled(!canStepBackward || (playbackSeconds == 0 && !isPlaying))

            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("toggleReplayPlayback")

            Button {
                stepFrame(by: 1)
            } label: {
                Image(systemName: "forward.frame.fill")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next frame")
            .accessibilityIdentifier("nextReplayFrame")
            .disabled(!canStepForward || playbackEnded)
        }
    }

    private var speedButtons: some View {
        HStack(spacing: 2) {
            ForEach(PlaybackSpeed.allCases, id: \.self) { speed in
                let selected = speed == playbackSpeed
                Button {
                    setPlaybackSpeed(speed)
                } label: {
                    Text(speed.title)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(selected ? .white.opacity(0.23) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .accessibilityLabel(speed.accessibilityLabel)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("replaySpeed_\(speed.rawValue)")
            }
        }
    }

    private var playbackTimeline: some View {
        let total = replay.durationSeconds
        let elapsed = min(scrubSeconds ?? playbackSeconds, total)
        let elapsedTime = Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond(
            padMinuteToLength: 1, fractionalSecondsLength: isPlaying && total >= 1 ? 0 : 3, roundFractionalSeconds: .down
        )))
        let totalTime = Duration.seconds(total).formatted(.time(pattern: .minuteSecond(
            padMinuteToLength: 1, fractionalSecondsLength: total < 1 ? 2 : 0, roundFractionalSeconds: .up
        )))

        return VStack(spacing: 2) {
            ReplayTimeline(fraction: elapsed / total, position: "\(elapsedTime) of \(totalTime)") { fraction, dragging in
                scrub(to: fraction * total, dragging: dragging)
            }
            .frame(height: 44)

            HStack {
                Text(elapsedTime)
                Spacer()
                Text(totalTime)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    private func scrub(to seconds: Double, dragging: Bool) {
        guard let player, hasPlaybackFocus else { return }
        if scrubSeconds == nil {
            resumeAfterScrub = player.timeControlStatus != .paused
            player.pause()
        }
        scrubTask?.cancel()
        scrubSeconds = seconds
        let time = CMTime(seconds: seconds, preferredTimescale: 60_000)
        if dragging {
            let tolerance = CMTime(value: 1, timescale: 10)
            player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        } else {
            scrubTask = Task {
                let didSeek = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                guard !Task.isCancelled, self.player === player else { return }
                scrubSeconds = nil
                if didSeek {
                    playbackSeconds = seconds
                    playbackEnded = seconds >= replay.durationSeconds
                }
                if resumeAfterScrub, !playbackEnded, hasPlaybackFocus { player.play() }
            }
        }
    }

    private func setPlaybackSpeed(_ speed: PlaybackSpeed) {
        guard let player else { return }
        playbackSpeed = speed
        player.defaultRate = speed.rawValue
        if player.timeControlStatus != .paused, hasPlaybackFocus {
            player.rate = speed.rawValue
        }
    }

    private func togglePlayback() {
        guard let player, hasPlaybackFocus else { return }
        if playbackEnded {
            playAgain()
        } else if player.timeControlStatus == .paused {
            player.play()
        } else {
            player.pause()
        }
    }

    private func stepFrame(by count: Int) {
        guard let player, let item = player.currentItem, hasPlaybackFocus,
              count < 0 ? item.canStepBackward : item.canStepForward else { return }
        player.pause()
        item.step(byCount: count)
    }

    private func playAgain() {
        guard let player, hasPlaybackFocus else { return }
        Task {
            let didSeek = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            guard didSeek, self.player === player, hasPlaybackFocus else { return }
            playbackSeconds = 0
            playbackEnded = false
            player.play()
        }
    }

    private func stopPlayback() {
        scrubTask?.cancel()
        guard let player else { return }
        if let playbackTimeObserver {
            player.removeTimeObserver(playbackTimeObserver)
            self.playbackTimeObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        self.player = nil
    }

    private func closePlayback() {
        stopPlayback()
        onClose()
    }
}

private struct ReplayTimeline: UIViewRepresentable {
    let fraction: Double
    let position: String
    let onScrub: (Double, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScrub: onScrub) }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 34, height: 34)).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 34, height: 34))
        }
        slider.setThumbImage(thumb, for: .normal)
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = .white.withAlphaComponent(0.3)
        slider.accessibilityLabel = String(localized: "Replay timeline")
        slider.accessibilityIdentifier = "replayTimeline"
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.finished(_:)),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.onScrub = onScrub
        if !slider.isTracking { slider.value = Float(fraction) }
        slider.accessibilityValue = position
    }

    @MainActor
    final class Coordinator: NSObject {
        var onScrub: (Double, Bool) -> Void
        private var didDrag = false

        init(onScrub: @escaping (Double, Bool) -> Void) { self.onScrub = onScrub }

        @objc func changed(_ slider: UISlider) {
            didDrag = slider.isTracking
            onScrub(Double(slider.value), didDrag)
        }

        @objc func finished(_ slider: UISlider) {
            guard didDrag else { return }
            didDrag = false
            onScrub(Double(slider.value), false)
        }
    }
}

private struct RequiredPermissionsView: View {
    let permissions: [RecordingPermission]
    let accent: Color
    let openSettings: () -> Void

    private let background = Color(red: 0.035, green: 0.055, blue: 0.047)

    private var needsCamera: Bool { permissions.contains(.camera) }
    private var needsPhotos: Bool { permissions.contains(.photos) }

    private var title: LocalizedStringKey {
        if needsCamera && needsPhotos { return "Camera and Photos access needed" }
        if needsCamera { return "Camera access needed" }
        return "Photos access needed"
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("permissionRecoveryTitle")

                    Text("Enable access in iPhone Settings, then return to Court Footage.")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 16) {
                        if needsCamera {
                            permissionRow("Camera", detail: "Keeps recent play ready to save.", icon: "camera")
                        }
                        if needsPhotos {
                            permissionRow("Photos", detail: "Adds your saved replays to Photos.", icon: "photo.on.rectangle")
                        }
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, geometry.size.width >= 560 ? 24 : 68)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: openSettings) {
                Label("Open iPhone Settings", systemImage: "arrow.up.right")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("openPermissionSettings")
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(background)
        }
        .background(background.ignoresSafeArea())
    }

    private func permissionRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(accent)
                .frame(minWidth: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
@Observable
private final class PreviewReference {
    @ObservationIgnored weak var view: UIView?
    private(set) var videoAspect: CGFloat?
    private(set) var isSceneFrontmost = false

    func refreshSceneFocus() {
        guard let view, view.window != nil else {
            isSceneFrontmost = false
            return
        }
        isSceneFrontmost = view.traitCollection.activeAppearance != .inactive
    }

    func refreshVideoAspect() {
        guard let view, let video = measuredVideoRect(in: view.bounds.size) else { return }
        let aspect = video.width / video.height
        if videoAspect.map({ abs($0 - aspect) > 0.001 }) ?? true {
            videoAspect = aspect
        }
    }

    func videoRect(in size: CGSize) -> CGRect? {
        // Observe the first usable frame so SwiftUI can reveal the tap area as the preview comes up.
        guard videoAspect != nil else { return nil }
        return measuredVideoRect(in: size)
    }

    private func measuredVideoRect(in size: CGSize) -> CGRect? {
        guard let layer = view?.layer as? AVCaptureVideoPreviewLayer,
              layer.isPreviewing, !layer.bounds.isEmpty else { return nil }
        let bounds = layer.bounds
        let video = layer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            .intersection(bounds)
        guard !video.isEmpty else { return nil }
        return video.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            .applying(CGAffineTransform(scaleX: size.width / bounds.width, y: size.height / bounds.height))
    }
}

private struct CameraPreview: UIViewRepresentable {
    let capture: CaptureService
    let reference: PreviewReference
    let onGeometryReady: @MainActor () -> Void

    func makeUIView(context: Context) -> CameraSurface {
        let view = CameraSurface()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = capture.session
        view.onAttach = { attachedView in
            capture.setPreviewView(attachedView)
            reference.view = attachedView
            reference.refreshSceneFocus()
        }
        view.registerForTraitChanges([UITraitActiveAppearance.self]) { (_: CameraSurface, _: UITraitCollection) in
            reference.refreshSceneFocus()
        }
        view.onGeometryReady = onGeometryReady
        view.onPreviewGeometryChange = reference.refreshVideoAspect
        return view
    }

    func updateUIView(_ uiView: CameraSurface, context: Context) {}

    final class CameraSurface: UIView {
        var onAttach: (@MainActor (UIView) -> Void)?
        var onGeometryReady: (@MainActor () -> Void)?
        var onPreviewGeometryChange: (@MainActor () -> Void)?
        private var geometryObservation: NSKeyValueObservation?
        private var previewObservation: NSKeyValueObservation?

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // UIKit instantiates the layer class declared above.
            layer as! AVCaptureVideoPreviewLayer
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            geometryObservation = nil
            previewObservation = nil
            guard let scene = window?.windowScene else { return }
            onAttach?(self)
            geometryObservation = scene.observe(\.effectiveGeometry, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.onGeometryReady?() }
            }
            previewObservation = previewLayer.observe(\.isPreviewing, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.onPreviewGeometryChange?() }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            Task { @MainActor [weak self] in self?.onPreviewGeometryChange?() }
        }
    }
}

private struct CourtArtwork: View {
    var body: some View {
        Canvas { context, size in
            let nearY = size.height * 0.92
            let farY = size.height * 0.13

            func courtPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                let halfWidth = size.width * (0.26 + y * 0.21)
                return CGPoint(x: size.width * 0.5 + x * halfWidth, y: farY + y * (nearY - farY))
            }

            let lines = Path { path in
                path.move(to: courtPoint(-1, 0))
                path.addLine(to: courtPoint(1, 0))
                path.addLine(to: courtPoint(1, 1))
                path.addLine(to: courtPoint(-1, 1))
                path.closeSubpath()

                for depth: CGFloat in [0.30, 0.47, 0.66] {
                    path.move(to: courtPoint(-1, depth))
                    path.addLine(to: courtPoint(1, depth))
                }

                path.move(to: courtPoint(0, 0))
                path.addLine(to: courtPoint(0, 0.30))
                path.move(to: courtPoint(0, 0.66))
                path.addLine(to: courtPoint(0, 1))
            }
            context.stroke(lines, with: .color(.white.opacity(0.72)),
                           style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct FootageSettingsView: View {
    @Bindable var model: RecordingModel
    @Binding var dimsScreen: Bool
    @State private var showingResolutions = false
    @State private var showingFrameRates = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private var settings: RecordingSettings { model.settings }

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                if viewport.size.width > viewport.size.height {
                    HStack(spacing: 0) {
                        Form {
                            timingSection
                            captureSection
                        }

                        Form {
                            informationSection
                        }
                    }
                } else {
                    Form {
                        timingSection
                        captureSection
                        informationSection
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var timingSection: some View {
        Section {
            let units: Set<Duration.UnitsFormatStyle.Unit> = [.hours, .minutes, .seconds]
            let clipLength = Duration.seconds(settings.clipDuration)
            let clipLengthStops = 0...(RecordingSettings.clipDurations.count - 1)
            let accessibleClipLength = clipLength.formatted(.units(allowed: units, width: .wide).locale(locale))
            let clipLengthIndex = Binding {
                Double(model.settings.clipDurationIndex)
            } set: { index in
                model.settings.clipDurationIndex = Int(index.rounded())
            }
            VStack(alignment: .leading, spacing: 8) {
                Stepper(value: $model.settings.clipDurationIndex, in: clipLengthStops) {
                    Text(clipLength.formatted(.units(allowed: units, width: .abbreviated).locale(locale)))
                        .font(.title.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .accessibilityLabel("Adjust clip length")
                .accessibilityValue(accessibleClipLength)
                .accessibilityIdentifier("clipLengthStepper")

                Slider(value: clipLengthIndex, in: 0...Double(clipLengthStops.upperBound), step: 1)
                    .accessibilityLabel("Clip length")
                    .accessibilityValue(accessibleClipLength)
                    .accessibilityIdentifier("clipLength")
            }

            let skipDuration = Duration.seconds(settings.ignoredSeconds)
                .formatted(.units(allowed: [.seconds], width: .wide).locale(locale))
                .capitalized(with: locale)
            Stepper(value: $model.settings.ignoredSeconds, in: RecordingSettings.allowedIgnoredSeconds) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skip just before tapping")
                    Text(skipDuration)
                        .font(.subheadline.bold().monospacedDigit())
                }
            }
            .accessibilityLabel("Skip just before tapping")
            .accessibilityValue(skipDuration)
            .accessibilityIdentifier("ignoredFootage")
        }
    }

    private var captureSection: some View {
        Section {
            resolutionPicker

            frameRatePicker

            Toggle(isOn: $dimsScreen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dim screen")
                    Text("Dimming saves battery")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Dim screen")
            .accessibilityHint("Dimming saves battery")
            .accessibilityIdentifier("dimPreviewWhenReady")

            Toggle("Audio", isOn: model.canEnableAudio ? $model.settings.audioEnabled : .constant(false))
                .disabled(!model.canEnableAudio)
                .accessibilityIdentifier("recordMicrophone")
        } footer: {
            if let controls = model.cameraControls, let rate = controls.frameRate,
               settings.quality == model.activeSettings.quality,
               settings.frameRate == model.activeSettings.frameRate,
               controls.frameRateLimitedByPressure || settings.frameRate == .maximum || !settings.frameRate.matches(rate) {
                let target = rate.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
                if controls.frameRateLimitedByPressure {
                    Text("iOS is limiting the recording rate to \(target) fps.")
                } else if let requested = settings.frameRate.limit {
                    Text("Requested \(requested) fps. The camera started at \(target) fps.")
                } else {
                    Text("Set to record at \(target) fps.")
                }
            }
            if !model.canEnableAudio {
                Text("Microphone not available. Enable in iOS Settings / Privacy / Microphone")
            }
        }
    }

    private var supportedFrameRateOptions: [VideoFrameRate] {
        let ranges = model.cameraControls?.frameRateRanges[settings.quality] ?? []
        return VideoFrameRate.allCases.filter { $0.isSupported(in: ranges) }
    }

    private var frameRateOptions: [VideoFrameRate] {
        let options = supportedFrameRateOptions
        guard let controls = model.cameraControls, controls.frameRateLimitedByPressure,
              let activeRate = controls.frameRate else { return options }
        let limit = min(24, activeRate)
        return options.filter { rate in
            rate.limit.map { Double($0) <= limit || rate.matches(limit) } ?? true
        }
    }

    private var frameRateSelection: Binding<VideoFrameRate> {
        Binding {
            frameRateOptions.contains(settings.frameRate) ? settings.frameRate : .maximum
        } set: { model.settings.frameRate = $0 }
    }

    private var informationSection: some View {
        Section {
            NavigationLink("Privacy") {
                PrivacyView()
            }
            .accessibilityIdentifier("privacySettings")

            NavigationLink("About Court Footage") {
                AboutCourtFootageView()
            }
        }
    }

    private func estimatedClipSize(for quality: VideoQuality, at rate: VideoFrameRate) -> String {
        let controls = model.cameraControls
        let isPressureLimited = controls?.frameRateLimitedByPressure == true
        let frameRate: Double
        if quality == model.activeSettings.quality, let activeRate = controls?.frameRate,
           rate == model.activeSettings.frameRate || (isPressureLimited && rate == .maximum) {
            frameRate = activeRate
        } else {
            let ranges = controls?.frameRateRanges[quality] ?? []
            let target: VideoFrameRate = isPressureLimited ? .fps24 : rate
            frameRate = target.supportedRate(in: ranges) ?? target.limit.map(Double.init) ?? 30
        }

        let bytes = quality.estimatedBytes(durationSeconds: settings.clipDuration,
                                           includeAudio: model.audioEnabledInSettings, frameRate: frameRate)
        return bytes.formatted(.byteCount(style: .file, allowedUnits: [.mb, .gb]).locale(locale))
    }

    private var resolutionPicker: some View {
        clipSizePicker("Resolution", options: VideoQuality.allCases, selection: $model.settings.quality,
                       isPresented: $showingResolutions, identifier: "videoResolution") { quality in
            Text(quality.title)
        } estimatedSize: { quality in
            estimatedClipSize(for: quality, at: settings.frameRate)
        }
    }

    private var frameRatePicker: some View {
        clipSizePicker("Frame rate", options: frameRateOptions, selection: frameRateSelection,
                       isPresented: $showingFrameRates, identifier: "videoFrameRate") { rate in
            if let limit = rate.limit {
                return Text("\(limit) fps")
            }
            return Text("Maximum")
        } estimatedSize: { rate in
            estimatedClipSize(for: settings.quality, at: rate)
        }
        .onChange(of: supportedFrameRateOptions, initial: true) { _, options in
            if !options.contains(settings.frameRate) { model.settings.frameRate = .maximum }
        }
    }

    private func clipSizePicker<Option: Hashable>(
        _ label: LocalizedStringKey, options: [Option], selection: Binding<Option>,
        isPresented: Binding<Bool>, identifier: String, title: @escaping (Option) -> Text,
        estimatedSize: @escaping (Option) -> String
    ) -> some View {
        Button {
            isPresented.wrappedValue = true
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                title(selection.wrappedValue)
                    .foregroundStyle(.tint)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(title(selection.wrappedValue))
        .accessibilityIdentifier(identifier)
        .popover(isPresented: isPresented) {
            VStack(spacing: 0) {
                ForEach(options, id: \.self) { option in
                    let isSelected = selection.wrappedValue == option
                    let size = estimatedSize(option)

                    Button {
                        selection.wrappedValue = option
                        isPresented.wrappedValue = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tint)
                                .opacity(isSelected ? 1 : 0)
                                .accessibilityHidden(true)
                            title(option)
                                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            Spacer(minLength: 12)
                            Text("~\(size) / clip")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title(option))
                    .accessibilityValue("Approximately \(size) per clip")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(idealWidth: 330, maxWidth: 360)
            .presentationSizing(.fitted)
            .presentationCompactAdaptation(.popover)
        }
    }
}

private struct AboutCourtFootageView: View {
    var body: some View {
        Form {
            Section {
                Text("Court Footage is a hobby project by Joachim Neumann. It’s free and always will be.")
            }

            Section {
                NavigationLink("MIT License") {
                    MITLicenseView()
                }

                if let repository = URL(string: "https://github.com/joachimneumann/court-footage") {
                    Link("Source code on GitHub", destination: repository)
                        .accessibilityHint("Opens in your browser")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                Text("Version \(version) (build \(build))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("About Court Footage")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MITLicenseView: View {
    var body: some View {
        ScrollView {
            Group {
                if let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
                   let license = try? String(contentsOf: url, encoding: .utf8) {
                    Text(verbatim: license)
                        .textSelection(.enabled)
                } else {
                    Text("The bundled license could not be opened.")
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("MIT License")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("The Court Footage app does not connect to the internet, upload any information, or track you.")
                    .bold()
                Text("Court Footage opens the camera when you launch the app, once you grant camera access. It records microphone audio when Audio is on. Recent footage is kept in a temporary buffer on your iPhone.")
                Text("When you first open the app, Court Footage asks for permission to add videos to Photos. Photos handles saved videos according to your library and iCloud settings. Unsaved footage is discarded when recording ends.")

                if let policy = Bundle.main.object(forInfoDictionaryKey: "ReplayPrivacyPolicyURL") as? String,
                   let url = URL(string: policy), url.scheme == "https" {
                    Link("Read the full privacy policy", destination: url)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
