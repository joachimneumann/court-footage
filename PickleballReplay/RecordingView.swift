import AVFoundation
import AVKit
import Observation
import SwiftUI
import UIKit

struct RecordingView: View {
    let model: RecordingModel

    @AppStorage("hasShownTapToRecordHint") private var hasShownTapToRecordHint = false
    @State private var preview = PreviewReference()
    @State private var showingSettings = false
    @State private var replayToPlay: SavedReplay?
    @State private var showsSaveFeedback = false
    @State private var showsTapToRecordHint = false
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
    private let bufferIndicatorHeight: CGFloat = 22

    private var isExpandedDisplay: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    var body: some View {
        ZStack {
            CameraPreview(capture: model.capture, reference: preview, onGeometryReady: startOnActivePreview)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            if let replay = replayToPlay {
                SavedReplayPlayer(replay: replay, model: model) {
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
            } else if let replay = model.recentReplay, model.phase != .idle {
                let dismissReplay = { model.dismissRecentReplay(id: replay.id) }
                replayCover(frame: replay.thumbnail)
                    .overlay(alignment: .topTrailing) {
                        replayCloseButton("closeReplayThumbnail", action: dismissReplay)
                            .padding(16)
                    }
                    .accessibilityAction(.escape, dismissReplay)
            } else {
                cameraScreen
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
            startOnActivePreview()
        }
        .sheet(isPresented: $showingSettings, onDismiss: model.applyRecordingSettingsIfNeeded) {
            FootageSettingsView(model: model)
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
            try? await Task.sleep(for: .milliseconds(400))
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
    }

    private func replayCover(frame: CGImage?) -> some View {
        GeometryReader { screen in
            let insets = screen.safeAreaInsets
            let viewport = previewSize(in: screen)
            let region = frame.flatMap { saveRegion(in: viewport, fallbackFrame: $0) }

            ZStack {
                Color.black.ignoresSafeArea()

                if let frame, let region {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: region.width, height: region.height)
                        .clipShape(saveRegionShape)
                        .overlay { replayConfirmation.padding(12) }
                        .position(x: region.midX - insets.leading, y: region.midY - insets.top)
                } else {
                    replayConfirmation
                }

                if model.phase == .recording {
                    let inset = bufferIndicatorHeight / 2 + 8
                    let bottom = screen.size.height - inset
                    let belowThumbnail = region.map { $0.maxY - insets.top + inset } ?? bottom
                    let centerX = region.map { $0.midX - insets.leading } ?? screen.size.width / 2
                    bufferIndicator
                        .position(x: centerX, y: min(belowThumbnail, bottom))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var replayConfirmation: some View {
        VStack(spacing: 8) {
            Text("Video saved.")
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .accessibilityIdentifier("replaySavedConfirmation")
            playReplayButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.78), in: .rect(cornerRadius: 16))
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
        .overlayPreferenceValue(CameraAccessoriesBounds.self) { accessoriesBounds in
            if isRecording && (!canUseCameraControls || camera != nil) {
                GeometryReader { viewport in
                    let insets = viewport.safeAreaInsets
                    let size = previewSize(in: viewport)
                    let video = liveVideoRect(in: size) ?? CGRect(origin: .zero, size: size)
                    let targetY = video.minY + video.height * 0.85 - insets.top
                    let toolbarTop = accessoriesBounds.map { viewport[$0].minY } ?? viewport.size.height
                    let lowestY = toolbarTop - bufferIndicatorHeight / 2 - 6
                    bufferIndicator
                        .position(x: video.midX - insets.leading, y: min(targetY, lowestY))
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                feedbackToast
                    .allowsHitTesting(false)

                if !isRecording && model.blockedCapturePermission == .microphone {
                    Button("Open iPhone Settings", action: model.openPermissionSettings)
                        .buttonStyle(.borderedProminent)
                        .tint(courtGreen)
                        .foregroundStyle(.black)
                        .accessibilityIdentifier("openPermissionSettings")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
        }
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
                            .overlay { saveRegionGlow }
                            .contentShape(saveRegionShape)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Save replay")
                            .accessibilityHint(saveHint)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { saveFromPreview() }
                            .accessibilityZoomAction { action in
                                guard let zoom = model.cameraControls?.zoom else { return }
                                switch action.direction {
                                case .zoomIn: model.setZoom(zoom.factor * 1.2)
                                case .zoomOut: model.setZoom(zoom.factor / 1.2)
                                @unknown default: break
                                }
                            }
                            .accessibilitySortPriority(2)
                            .accessibilityIdentifier("saveReplay")
                            .overlay {
                                if showsTapToRecordHint {
                                    tapToRecordHint
                                }
                            }
                            .onAppear(perform: showTapToRecordHintOnce)
                            .onDisappear { showsTapToRecordHint = false }
                            .position(x: region.midX, y: region.midY)
                    }
                }
                .contentShape(Rectangle())
                .gesture(pinch.exclusively(before: tap))
        }
        .ignoresSafeArea()
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

    private var saveRegionGlow: some View {
        Canvas { context, size in
            let area = Path(CGRect(origin: .zero, size: size))
            let radius = min(54, min(size.width, size.height) * 0.22)
            let glow = Gradient(colors: [.white.opacity(0.7), .white.opacity(0)])
            for corner in [CGPoint.zero, CGPoint(x: size.width, y: 0),
                           CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)] {
                context.fill(area, with: .radialGradient(glow, center: corner, startRadius: 0, endRadius: radius))
            }
        }
        .clipShape(saveRegionShape)
        .opacity(saveRegionFlash == nil ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var tapToRecordHint: some View {
        ZStack {
            saveRegionShape.strokeBorder(courtGreen, lineWidth: 2)
                .accessibilityHidden(true)

            Text("Tap here to record")
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.85), in: .rect(cornerRadius: 12))
                .padding(12)
                .accessibilityIdentifier("tapToRecordHint")
        }
        .allowsHitTesting(false)
    }

    private func showTapToRecordHintOnce() {
        guard !hasShownTapToRecordHint else { return }
        hasShownTapToRecordHint = true
        showsTapToRecordHint = true
        AccessibilityNotification.Announcement("Double-tap Save replay to save recent footage.").post()
    }

    private func saveFromPreview() {
        showsTapToRecordHint = false
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
                    .anchorPreference(key: CameraAccessoriesBounds.self, value: .bounds) { $0 }
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
            showsTapToRecordHint = false
            showingSettings = true
        } label: {
            cameraControlIcon("gearshape")
        }
        .buttonStyle(.plain)
        .disabled(model.isSaving)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("recordingSettings")
    }

    private var playReplayButton: some View {
        Button {
            replayToPlay = model.openRecentReplay()
        } label: {
            Text("Play…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(courtGreen)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays the replay just added to Photos")
        .accessibilityIdentifier("playSavedReplay")
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

    private var bufferIndicator: some View {
        let duration = model.activeSettings.clipDuration
        let available = model.availableSeconds.isFinite ? min(Double(duration), max(0, model.availableSeconds)) : 0
        let wholeSeconds = Int(available)
        let isFull = model.isBufferFull

        return GeometryReader { track in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.28))
                Capsule().fill(courtGreen)
                    .frame(width: track.size.width * available / Double(duration))
            }
        }
        .frame(height: 4)
        .animation(reduceMotion ? nil : .linear(duration: 0.16), value: available)
        .padding(.horizontal, 8)
        .frame(height: bufferIndicatorHeight)
        .frame(maxWidth: 176)
        .background(.white.opacity(0.28), in: .rect(cornerRadius: 8))
        .opacity(isFull ? 0 : 1)
        .animation(reduceMotion || !isFull ? nil : .easeOut(duration: 0.25), value: isFull)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Filling buffer")
        .accessibilityValue("\(wholeSeconds) of \(duration) seconds")
        .accessibilityIdentifier("replayBuffer")
        .accessibilityHidden(isFull)
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
        if options.ignoredSeconds == 0 {
            return Text("Saves up to the last \(options.clipDuration) seconds")
        }
        let skipped = Duration.seconds(options.ignoredSeconds).formatted(.units(allowed: [.seconds], width: .wide))
        return Text("Saves up to \(options.clipDuration) seconds, skipping the last \(skipped)")
    }
}

private struct CameraAccessoriesBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

private struct SavedReplayPlayer: View {
    let replay: SavedReplay
    let model: RecordingModel
    let onClose: () -> Void

    @State private var player: AVPlayer?
    @State private var isMuted = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea()
                .accessibilityIdentifier("savedReplayPlayer")
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                if model.activeSettings.audioEnabled, let player {
                    Button {
                        isMuted.toggle()
                        player.isMuted = isMuted
                    } label: {
                        replayControlIcon(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .accessibilityLabel(isMuted ? "Unmute replay audio" : "Mute replay audio")
                    .accessibilityHint(isMuted ? "Use headphones to keep playback out of the next recording" : "")
                    .accessibilityIdentifier("toggleReplayAudio")
                }
                replayCloseButton("closeSavedReplay", action: closePlayback)
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        .accessibilityAction(.escape, closePlayback)
        .task {
            let player = AVPlayer(url: replay.url)
            player.audiovisualBackgroundPlaybackPolicy = .pauses
            isMuted = model.activeSettings.audioEnabled
            player.isMuted = isMuted
            self.player = player
            player.play()
        }
        .onDisappear(perform: stopPlayback)
    }

    private func stopPlayback() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func closePlayback() {
        stopPlayback()
        onClose()
    }
}

private func replayCloseButton(_ identifier: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        replayControlIcon("xmark")
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Close replay")
    .accessibilityIdentifier(identifier)
}

private func replayControlIcon(_ symbol: String) -> some View {
    Image(systemName: symbol)
        .font(.headline)
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .background(.black.opacity(0.84), in: Circle())
        .contentShape(Circle())
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
    @State private var showingResolutions = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private var settings: RecordingSettings { model.settings }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    let clipLength = Duration.seconds(settings.clipDuration)
                        .formatted(.units(allowed: [.seconds], width: .wide))
                    Stepper(value: $model.settings.clipDuration, in: RecordingSettings.allowedDurations,
                            step: RecordingSettings.clipDurationStep) {
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

                    Toggle("Audio", isOn: $model.settings.audioEnabled)
                        .accessibilityIdentifier("recordMicrophone")
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
                    let bytes = quality.estimatedBytes(durationSeconds: settings.clipDuration, includeAudio: settings.audioEnabled)
                    let estimatedSize = (Double(bytes) / 1_000_000)
                        .formatted(.number.precision(.fractionLength(1)).locale(locale))

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
                            Text("~\(estimatedSize) MB / clip")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(quality.title)
                    .accessibilityValue("Approximately \(estimatedSize) megabytes per clip")
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
