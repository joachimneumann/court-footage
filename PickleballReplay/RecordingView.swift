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
    @State private var dimmingWasInterrupted = false
    @State private var showingSettings = false
    @State private var replayToPlay: SavedReplay?
    @State private var showsSaveFeedback = false
    @State private var saveRegionFlash: UUID?
    @State private var zoomAtPinchStart: Double?
    @State private var lastCameraControls: CameraControls?
    @State private var zoomPresetSlots: Int?
    @GestureState private var isPinching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private let courtGreen = Color(red: 0.78, green: 0.97, blue: 0.41)
    private let saveRegionShape = RoundedRectangle(cornerRadius: 16)
    private let zoomButtonWidth: CGFloat = 44
    private let zoomCapsulePadding: CGFloat = 3
    private let cameraColumnWidth: CGFloat = 50
    private let cameraColumnPadding: CGFloat = 6

    private var isExpandedDisplay: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    private var shouldDimScreen: Bool {
        dimsScreen && !dimmingWasInterrupted && model.isBufferFull && model.phase == .recording
            && scenePhase == .active && !showingSettings && replayToPlay == nil && model.recentReplay == nil
    }

    var body: some View {
        ZStack {
            CameraPreview(capture: model.capture, reference: preview, onGeometryReady: startOnActivePreview)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            if let replay = replayToPlay {
                SavedReplayPlayer(replay: replay, model: model, preview: preview) {
                    replayToPlay = nil
                    model.finishReplayPlayback()
                }
            } else if !model.blockedRequiredPermissions.isEmpty {
                RequiredPermissionsView(
                    permissions: model.blockedRequiredPermissions,
                    accent: courtGreen,
                    openSettings: model.openPermissionSettings
                )
                .overlay(alignment: .topTrailing) {
                    settingsGear
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
            } else if let replay = model.recentReplay, model.phase != .idle, saveRegionFlash == nil {
                replayCover(replay)
                    .accessibilityAction(.escape) { model.dismissRecentReplay(id: replay.id) }
            } else {
                cameraWithAccessory
            }
        }
        .background { Color.black.ignoresSafeArea() }
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
            startOnActivePreview()
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
        .onChange(of: shouldDimScreen, initial: true) { _, _ in
            updateScreenBrightness()
        }
        .onChange(of: model.availableSeconds == 0) { _, isEmpty in
            if isEmpty { dimmingWasInterrupted = false }
        }
        .onChange(of: dimsScreen) { _, _ in
            dimmingWasInterrupted = false
        }
        .onDisappear { screenDimmer.restore() }
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
        guard let orientation = preview.activeInterfaceOrientation else { return }
        model.startWhenActive(orientation: orientation)
        updateScreenBrightness()
    }

    private func updateScreenBrightness() {
        if shouldDimScreen, let screen = preview.view?.window?.windowScene?.screen {
            screenDimmer.dim(screen, animated: !reduceMotion)
        } else {
            screenDimmer.restore()
        }
    }

    private func wakeScreen() {
        if dimsScreen && model.isBufferFull { dimmingWasInterrupted = true }
        screenDimmer.restore()
    }

    private func replayCover(_ replay: SavedReplay) -> some View {
        GeometryReader { screen in
            let insets = screen.safeAreaInsets
            let viewport = previewSize(in: screen)
            let frame = replay.thumbnail
            let region = frame.flatMap { saveRegion(in: viewport, fallbackFrame: $0) }
            let cardWidth = min((region?.width ?? screen.size.width) * 0.88, 350)
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
                Color.black.ignoresSafeArea()

                if let frame, let region {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: region.width, height: region.height)
                        .clipShape(saveRegionShape)
                        .overlay { confirmation }
                        .position(x: region.midX - insets.leading, y: region.midY - insets.top)
                } else {
                    confirmation
                }
            }
        }
    }

    private func replayConfirmation(for replay: SavedReplay, spacing: CGFloat) -> some View {
        let fractionDigits = replay.durationSeconds < 1 ? 2 : 0
        let duration = replay.durationSeconds.formatted(.number.precision(.fractionLength(0...fractionDigits)))
        let seconds = model.replaySecondsRemaining

        return VStack(spacing: spacing) {
            Text("\(duration) second video saved")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .accessibilityIdentifier("replaySavedConfirmation")

            Button {
                replayToPlay = model.openRecentReplay()
            } label: {
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
        .padding(.vertical, 20)
        .background(.black.opacity(0.88), in: .rect(cornerRadius: 22))
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
    private var cameraWithAccessory: some View {
        if #available(iOS 27.1, *) {
            cameraScreen.sceneAccessory {
                if model.phase == .recording && !showingSettings {
                    CameraCaptureAccessory {
                        ReplayCaptureAccessoryView(model: model, accent: courtGreen, onTouch: wakeScreen)
                    }
                }
            }
        } else {
            cameraScreen
        }
    }

    private var cameraScreen: some View {
        let isRecording = model.phase == .recording
        let canUseCameraControls = isRecording && scenePhase == .active
        let camera = canUseCameraControls ? model.cameraControls : nil
        let showCameraControls = scenePhase == .active && (isRecording || model.phase == .starting)

        return ZStack {
            if model.demoMode && isRecording {
                GeometryReader { viewport in
                    let video = demoVideoRect(in: viewport.size)
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

            LinearGradient(stops: [.init(color: .black.opacity(0.70), location: 0),
                                   .init(color: .clear, location: 0.26),
                                   .init(color: .clear, location: 0.60),
                                   .init(color: .black.opacity(0.77), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            if camera != nil {
                previewInteraction
            }

            if showCameraControls, let displayedCamera = camera ?? lastCameraControls {
                cameraToolbar(displayedCamera)
                    .disabled(camera == nil)
            } else if model.phase == .idle, model.status != nil {
                settingsGear
                    .frame(height: 50)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }

            if model.phase == .starting || (canUseCameraControls && camera == nil) {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel("Starting camera")
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            feedbackToast
                .allowsHitTesting(false)
                .padding(.horizontal, 24)
                .padding(.top, 28)
        }
        .gesture(RecordingTouchObserver(onTouch: wakeScreen))
    }

    private var previewInteraction: some View {
        let pinch = MagnifyGesture()
            .updating($isPinching) { _, pinching, _ in pinching = true }
            .onChanged { value in
                guard let zoom = model.cameraControls?.zoom else { return }
                let initial = zoomAtPinchStart ?? zoom.factor
                zoomAtPinchStart = initial
                model.setZoom(initial * Double(value.magnification))
            }

        return GeometryReader { viewport in
            let tap = SpatialTapGesture().onEnded { value in
                if let region = saveRegion(in: viewport.size),
                   saveRegionShape.path(in: region).contains(value.location) {
                    saveFromPreview()
                }
            }

            Color.clear
                .accessibilityHidden(true)
                .overlay {
                    if let region = saveRegion(in: viewport.size) {
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
                                wakeScreen()
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
        }
        .ignoresSafeArea()
        .onDisappear { saveRegionFlash = nil }
    }

    private func liveVideoRect(in size: CGSize) -> CGRect? {
        model.demoMode ? demoVideoRect(in: size) : preview.videoRect(in: size)
    }

    private func demoVideoRect(in size: CGSize) -> CGRect {
        let viewport = CGRect(origin: .zero, size: size)
        guard isExpandedDisplay else { return viewport }
        let aspect = size.width > size.height ? CGSize(width: 16, height: 9) : CGSize(width: 9, height: 16)
        return AVMakeRect(aspectRatio: aspect, insideRect: viewport)
    }

    private func previewSize(in viewport: GeometryProxy) -> CGSize {
        let insets = viewport.safeAreaInsets
        return CGSize(width: viewport.size.width + insets.leading + insets.trailing,
                      height: viewport.size.height + insets.top + insets.bottom)
    }

    private func saveRegion(in size: CGSize, fallbackFrame: CGImage? = nil) -> CGRect? {
        let video = liveVideoRect(in: size) ?? fallbackFrame.map {
            AVMakeRect(aspectRatio: CGSize(width: $0.width, height: $0.height),
                       insideRect: CGRect(origin: .zero, size: size))
        }
        guard let video, !video.isEmpty else { return nil }
        return video.insetBy(dx: video.width * 0.1, dy: video.height * 0.1)
    }

    private var saveRegionFeedback: some View {
        saveRegionShape.fill(.white.opacity(0.20))
            .overlay { saveRegionShape.strokeBorder(courtGreen, lineWidth: 2) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func saveFromPreview() {
        wakeScreen()
        guard model.canSaveReplay else { return }
        saveRegionFlash = UUID()
        model.saveReplay()
    }

    private func cameraToolbar(_ camera: CameraControls) -> some View {
        GeometryReader { viewport in
            if let rightSpaceCenter = cameraColumnCenter(in: viewport) {
                cameraAccessories(camera, vertical: true)
                    .padding(.vertical, 12)
                    .position(x: rightSpaceCenter, y: viewport.size.height / 2)
            } else {
                let insets = viewport.safeAreaInsets
                // The Duo's outer display can reserve more space on one side for system UI.
                let sideMargin = max(16, insets.leading, insets.trailing)
                cameraAccessories(camera, vertical: false)
                    .padding(.leading, sideMargin - insets.leading)
                    .padding(.trailing, sideMargin - insets.trailing)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private func cameraColumnCenter(in viewport: GeometryProxy) -> CGFloat? {
        guard isExpandedDisplay, viewport.size.height >= 200 else { return nil }
        let size = previewSize(in: viewport)
        let video = model.demoMode ? demoVideoRect(in: size) : preview.videoRectForToolbar(in: size)
        guard let video else { return nil }

        let rightToLeft = layoutDirection == .rightToLeft
        let leftInset = rightToLeft ? viewport.safeAreaInsets.trailing : viewport.safeAreaInsets.leading
        let start = max(0, video.maxX - leftInset) + cameraColumnPadding
        let end = viewport.size.width - cameraColumnPadding
        guard end - start >= cameraColumnWidth else { return nil }

        // Anchor the column at the safe edge so its buttons stay put during camera flips.
        let center = end - cameraColumnWidth / 2
        return rightToLeft ? viewport.size.width - center : center
    }

    private func cameraAccessories(_ camera: CameraControls, vertical: Bool) -> some View {
        let zoom = camera.zoom
        let zoomLength = CGFloat(zoomPresetSlots ?? zoom.presets.count) * zoomButtonWidth + 2 * zoomCapsulePadding
        let atPreset = zoom.presets.contains { abs($0 - zoom.factor) < 0.05 }
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))

        return VStack(spacing: 6) {
            if vertical || !atPreset {
                Text("\(zoomTitle(zoom.factor))×")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .padding(.horizontal, vertical ? 4 : 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.84), in: Capsule())
                    .frame(maxWidth: .infinity)
                    .opacity(atPreset ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Current zoom \(zoomTitle(zoom.factor)) times")
                    .accessibilityIdentifier("currentZoom")
                    .accessibilityHidden(atPreset)
            }

            layout {
                if vertical {
                    zoomPicker(zoom, vertical: true)
                        .frame(minHeight: 0, maxHeight: zoomLength, alignment: .bottom)
                        .frame(width: cameraColumnWidth)
                } else {
                    zoomPicker(zoom, vertical: false)
                        .frame(minWidth: 0, maxWidth: zoomLength, alignment: .trailing)
                        .frame(height: cameraColumnWidth)
                }
                if camera.canFlip { cameraFlipButton(camera) }
                settingsGear
            }
        }
        .frame(maxWidth: vertical ? cameraColumnWidth : 360)
        .foregroundStyle(.white)
    }

    private func zoomPicker(_ zoom: CameraZoomState, vertical: Bool) -> some View {
        let axis: Axis.Set = vertical ? .vertical : .horizontal

        return ViewThatFits(in: axis) {
            zoomPresets(zoom, vertical: vertical)
                .fixedSize(horizontal: !vertical, vertical: vertical)

            ScrollView(axis) {
                zoomPresets(zoom, vertical: vertical)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func zoomPresets(_ zoom: CameraZoomState, vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))

        return layout {
            ForEach(zoom.presets, id: \.self) { preset in
                let selected = abs(zoom.factor - preset) < 0.05
                Button {
                    wakeScreen()
                    model.setZoom(preset)
                } label: {
                    Text("\(zoomTitle(preset))×")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .foregroundStyle(selected ? courtGreen : .white)
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
            cameraControlIcon("arrow.triangle.2.circlepath.camera")
        }
        .buttonStyle(.plain)
        .disabled(model.isSaving)
        .accessibilityLabel(camera.facingFront ? "Switch to rear camera" : "Switch to front camera")
        .accessibilityHint("Starts a fresh replay buffer")
        .accessibilityIdentifier("flipCamera")
    }

    private var settingsGear: some View {
        Button {
            saveRegionFlash = nil
            showingSettings = true
        } label: {
            cameraControlIcon("gearshape")
        }
        .buttonStyle(.plain)
        .disabled(model.isSaving)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("recordingSettings")
    }

    private func cameraControlIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
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
    let onTouch: @MainActor () -> Void

    func makeUIGestureRecognizer(context: Context) -> TouchRecognizer {
        let recognizer = TouchRecognizer(target: nil, action: nil)
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.onTouch = onTouch
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: TouchRecognizer, context: Context) {
        recognizer.onTouch = onTouch
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
    let onTouch: @MainActor () -> Void
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
        .background { Color.black.ignoresSafeArea() }
        .contentShape(Rectangle())
        .gesture(RecordingTouchObserver(onTouch: onTouch))
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
                onTouch()
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
    let replay: SavedReplay
    let model: RecordingModel
    let preview: PreviewReference
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var isMuted = false
    @State private var playbackEnded = false
    @State private var playbackSeconds: Double = 0
    @State private var playbackTimeObserver: Any?

    private var hasPlaybackFocus: Bool {
        scenePhase == .active && preview.isSceneFrontmost
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("savedReplayPlayer")
                    .onReceive(player.publisher(for: \.timeControlStatus, options: [.new]).receive(on: DispatchQueue.main)) { status in
                        if status == .playing { playbackEnded = false }
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
            if player != nil, !playbackEnded, replay.durationSeconds.isFinite, replay.durationSeconds > 0 {
                playbackProgress
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
            if !focused { player?.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
            playbackEnded = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { notification in
            guard let scene = preview.view?.window?.windowScene, notification.object as? UIScene === scene else { return }
            player?.pause()
        }
        .onDisappear(perform: stopPlayback)
    }

    private var playbackProgress: some View {
        let total = replay.durationSeconds
        let elapsed = min(playbackSeconds, total)
        let precision = total < 1 ? 2 : 0
        let elapsedTime = Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond(
            padMinuteToLength: 1, fractionalSecondsLength: precision, roundFractionalSeconds: .down
        )))
        let totalTime = Duration.seconds(total).formatted(.time(pattern: .minuteSecond(
            padMinuteToLength: 1, fractionalSecondsLength: precision, roundFractionalSeconds: .up
        )))

        return VStack(spacing: 6) {
            ProgressView(value: elapsed, total: total)
                .progressViewStyle(.linear)
                .tint(.white)

            HStack {
                Text(elapsedTime)
                Spacer()
                Text(totalTime)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.8), in: .rect(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Replay progress")
        .accessibilityValue("\(elapsedTime) of \(totalTime)")
        .accessibilityIdentifier("replayPlaybackProgress")
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
    private var lastVideoAspect: CGFloat?
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
        if lastVideoAspect.map({ abs($0 - aspect) > 0.001 }) ?? true {
            lastVideoAspect = aspect
        }
    }

    func videoRectForToolbar(in size: CGSize) -> CGRect? {
        // Preserve the last aspect while the preview reconnects to the other camera.
        let previousAspect = lastVideoAspect
        return videoRect(in: size) ?? previousAspect.map {
            AVMakeRect(aspectRatio: CGSize(width: $0, height: 1), insideRect: CGRect(origin: .zero, size: size))
        }
    }

    func videoRect(in size: CGSize) -> CGRect? {
        // Observe the first usable frame so SwiftUI can reveal the tap area as the preview comes up.
        guard lastVideoAspect != nil else { return nil }
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

    var activeInterfaceOrientation: UIInterfaceOrientation? {
        guard let scene = view?.window?.windowScene, scene.activationState == .foregroundActive else { return nil }
        let orientation = scene.effectiveGeometry.interfaceOrientation
        return orientation == .unknown ? nil : orientation
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private var settings: RecordingSettings { model.settings }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    let units: Set<Duration.UnitsFormatStyle.Unit> = settings.clipDuration <= 60
                        ? [.seconds] : [.hours, .minutes, .seconds]
                    let clipLength = Duration.seconds(settings.clipDuration)
                        .formatted(.units(allowed: units, width: .wide).locale(locale))
                    Stepper(value: $model.settings.clipDurationIndex, in: 0...(RecordingSettings.clipDurations.count - 1)) {
                        Text(clipLength)
                            .font(.title.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Clip length")
                    .accessibilityValue(clipLength)
                    .accessibilityIdentifier("clipLength")

                    let skipDuration = Duration.seconds(settings.ignoredSeconds)
                        .formatted(.units(allowed: [.seconds], width: .wide).locale(locale))
                        .capitalized(with: locale)
                    Stepper(value: $model.settings.ignoredSeconds, in: RecordingSettings.allowedIgnoredSeconds, step: 1) {
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

                Section {
                    resolutionPicker

                    Toggle("Audio", isOn: model.canEnableAudio ? $model.settings.audioEnabled : .constant(false))
                        .disabled(!model.canEnableAudio)
                        .accessibilityIdentifier("recordMicrophone")
                } footer: {
                    if !model.canEnableAudio {
                        Text("Microphone not available. Enable in iOS Settings / Privacy / Microphone")
                    }
                }

                Section {
                    Toggle("Dim screen", isOn: $dimsScreen)
                        .accessibilityIdentifier("dimPreviewWhenReady")
                } footer: {
                    Text("Dimming saves battery")
                }

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
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var resolutionPicker: some View {
        Button {
            showingResolutions = true
        } label: {
            HStack(spacing: 6) {
                Text("Resolution")
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(settings.quality.title)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resolution")
        .accessibilityValue(settings.quality.title)
        .accessibilityIdentifier("videoResolution")
        .popover(isPresented: $showingResolutions) {
            VStack(spacing: 0) {
                ForEach(VideoQuality.allCases) { quality in
                    let isSelected = settings.quality == quality
                    let bytes = quality.estimatedBytes(durationSeconds: settings.clipDuration, includeAudio: model.audioEnabledInSettings)
                    let estimatedSize = bytes.formatted(.byteCount(style: .file, allowedUnits: [.mb, .gb]).locale(locale))

                    Button {
                        model.settings.quality = quality
                        showingResolutions = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.semibold))
                                .opacity(isSelected ? 1 : 0)
                                .accessibilityHidden(true)
                            Text(quality.title)
                            Spacer(minLength: 12)
                            Text("~\(estimatedSize) / clip")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(quality.title)
                    .accessibilityValue("Approximately \(estimatedSize) per clip")
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
