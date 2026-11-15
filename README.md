# Court Footage

[Website](https://courtfootage.com) · [Privacy policy](https://courtfootage.com/privacy)

Court Footage is an iPhone app for saving instant replays from pickleball, tennis, padel, and other court sports to Photos. Open the app to start recording with a live camera view. Tap within the center 80% of the video’s width and height to save a clip. The corners of the tap area briefly brighten. The live camera stays visible during the save. After the save, the clip’s thumbnail and **Open…** button stay on screen while the next buffer fills. Tap **Open…** to play the clip in Court Footage while the camera keeps recording. Playback starts muted when court audio is enabled. Once the next buffer is full, the live camera returns as soon as you close any open replay. The video is also in Photos.

Tap a zoom preset or pinch the preview to change framing. The zoom options come from the selected camera and video quality. Switching front and rear cameras starts a fresh buffer. Tap the gear beside the camera controls to open Settings and Privacy.

In **Settings**, choose a clip length from 5 to 60 seconds in five-second steps, how many seconds before each tap to skip (0 to 10 in one-second steps), whether to record audio, and 720p, 1080p, or 4K. The file-size estimate updates with the clip length, quality, and audio setting. The defaults are 30 seconds, a 2-second skip, audio on, and 1080p. With those defaults, tapping 12 seconds into a session saves about 10 seconds, and the buffer is full after about 32 seconds. Actual size varies with the footage. If you change recording settings, a fresh buffer begins when you close Settings.

Mount the phone in portrait or landscape before opening the app. Each session keeps its starting orientation. Leaving the app ends the session and clears unsaved footage. Recording resumes with a fresh buffer when you return to the camera.

## Run on your iPhone

1. Open `CourtReplay.xcodeproj` in Xcode 27.2 or later.
2. In the **CourtReplay** target under **Signing & Capabilities**, select your Apple Developer team and set a unique bundle identifier. The checked-in identifier is for local development.
3. Connect an iPhone running iOS 27 or later, select it as the run destination, and run the **CourtReplay** scheme.
4. When the app opens, read the permission explanation and tap **Continue** to see the iPhone prompts. Camera and permission to add clips to Photos are needed to use the camera screen. If either is off, **Open iPhone Settings** takes you to Court Footage’s system settings. Once the camera is running, try saving at about 12 seconds and again after the progress bar fades out. Play one of the saved clips in Court Footage and confirm the next buffer keeps filling. Open Photos and check the clip lengths, the two seconds skipped before each tap, and court audio. Try a session with audio off and confirm the other quality settings produce the selected resolution.

The Simulator can preview the screen and tap interactions. Launch a Debug build with the `--demo` argument to see a simulated buffer. Use a physical iPhone to test camera capture, audio, and saving real clips.

## Prepare for the App Store

- Run a full on-court session to check sound sync, heat, battery, and repeated saves. Test capture on an iPhone 11 or second-generation SE and check both displays and folding on an iPhone Duo.
- Use the [published privacy policy](https://courtfootage.com/privacy) for the in-app Privacy link and App Store Connect. The policy text is in [Release/PrivacyPolicy.md](Release/PrivacyPolicy.md). You can put local signing and URL settings in `Configuration/Local.xcconfig`, which Git ignores. In `.xcconfig` files use `https:$(SLASH)$(SLASH)courtfootage.com/privacy` with `SLASH = /` so Xcode reads the entire URL.
- Create the iOS app record as **Court Footage** under your individual developer account using the same bundle ID. Archive the Xcode project, upload the build to TestFlight, and use footage from the on-device test for the listing screenshots. Complete the App Store Connect privacy and age rating questionnaires, add the support URL and review notes, and submit the verified build.

## License

Court Footage is open source under the [MIT License](LICENSE). The Barlow Condensed font used on the website is distributed under its own [SIL Open Font License](Website/assets/barlow-condensed-license.txt).
