# Cursor Recorder Plan

## Summary

Build a thin native macOS SwiftUI app named `Cursor Recorder` for recording phone gameplay over USB and exporting a one-click MP4 with a custom Mac-controlled cursor overlay.

The app should support:

- iPhone USB capture through public AVFoundation external capture device APIs where macOS exposes the tethered phone.
- Android USB capture through detected Homebrew-installed `scrcpy` and `adb`.
- A selected custom cursor image manually controlled by the Mac mouse or trackpad over the phone preview.
- MP4 output saved to a user-selected folder.

OpenScreen is useful as a reference for cursor rendering, cursor packs, and capture/export architecture, but this app should be a native SwiftUI implementation rather than an Electron fork.

## Product Scope

### In Scope

- Native macOS app for macOS 14+.
- USB-connected phone gameplay capture.
- iPhone and Android support in the first version.
- Live preview of the connected phone source.
- Manual cursor overlay controlled from the Mac preview area.
- Cursor image selection from transparent PNG assets.
- Start, stop, cancel, and save recording controls.
- Clear setup and error states for permissions, device trust, missing tools, and disconnection.
- Final MP4 output with phone video, available phone audio, and composited cursor overlay.

### Out of Scope for V1

- Wireless mirroring.
- HDMI capture cards.
- Live streaming or virtual camera output.
- Editable project files.
- Real phone touch telemetry.
- Full video editor timeline.
- Bundled Android tooling.

## Architecture

### App Shell

Use SwiftUI for the main app:

- Device picker.
- Connection and setup status.
- Live phone preview.
- Cursor overlay preview.
- Record, stop, cancel, and reveal output controls.
- Cursor image picker and cursor scale controls.
- Output folder selector.

Use a compact single-window interface. The first screen should be the actual recorder, not a landing page.

### Core Types

Define these model-level interfaces:

```swift
enum PhonePlatform {
    case iphone
    case android
}

enum PhoneConnection {
    case usb
}

struct PhoneCaptureDevice {
    let id: String
    let platform: PhonePlatform
    let name: String
    let connection: PhoneConnection
    let width: Int?
    let height: Int?
    let supportsAudio: Bool
    let readiness: DeviceReadiness
}

enum DeviceReadiness {
    case ready
    case waitingForTrust
    case missingAndroidTools
    case missingUSBDebugging
    case unsupported
    case disconnected
}

struct CursorOverlayConfig {
    let imageURL: URL
    let hotspot: CGPoint
    let scale: CGFloat
    let opacity: CGFloat
    let shadowEnabled: Bool
    let smoothing: CGFloat
}

struct CursorTelemetrySample {
    let time: TimeInterval
    let normalizedPoint: CGPoint
    let visible: Bool
    let interaction: CursorInteraction
}

enum CursorInteraction {
    case move
    case click
    case mouseUp
}

struct RecordingSession {
    let id: UUID
    let device: PhoneCaptureDevice
    let startedAt: Date
    let outputURL: URL
    let cursor: CursorOverlayConfig
}
```

### Capture Adapter Protocol

Create a common adapter boundary:

```swift
protocol PhoneCaptureAdapter {
    func scanDevices() async throws -> [PhoneCaptureDevice]
    func startPreview(device: PhoneCaptureDevice) async throws
    func startRecording(session: RecordingSession) async throws
    func stopRecording() async throws -> URL
    func cancelRecording() async
}
```

Use separate implementations:

- `IPhoneUSBCaptureAdapter`
- `AndroidScrcpyCaptureAdapter`

## iPhone USB Capture

Use AVFoundation device discovery for external or muxed capture devices exposed by macOS.

Implementation behavior:

- Scan AVFoundation capture devices and filter likely tethered iPhone sources.
- Show a waiting/trust state if no usable source is visible but an iPhone connection is suspected.
- Request camera and microphone permissions as needed.
- Use `AVCaptureSession` for preview.
- Use `AVAssetWriter` for recording when the source provides frames/audio directly.
- Composite the custom cursor into the output frames before writing the final MP4.
- If a device or macOS version does not expose the iPhone as a capture source, show an explicit unsupported state instead of failing silently.

Expected edge cases:

- iPhone not trusted by the Mac.
- iPhone locked.
- Device unplugged during recording.
- Capture source exposes video but no audio.
- Orientation changes between portrait and landscape.

## Android USB Capture

Use Homebrew-installed tooling:

- `scrcpy`
- `adb`

The app should not bundle these tools in V1.

Implementation behavior:

- Detect `scrcpy` and `adb` from common paths such as `/opt/homebrew/bin` and `/usr/local/bin`.
- If missing, show a setup message with `brew install scrcpy android-platform-tools`.
- Use `adb devices` to list connected Android phones.
- Show setup state for unauthorized devices or missing USB debugging.
- Start recording through scrcpy using a temporary source MP4.
- Use a no-display or minimal-window scrcpy recording path for the source video.
- Post-process the recorded MP4 with cursor telemetry to produce the final MP4.
- Clean up temporary files on cancel or successful post-processing.

Expected edge cases:

- No Android device connected.
- Multiple Android devices connected.
- Device unauthorized.
- USB debugging disabled.
- `scrcpy` process exits early.
- Source MP4 missing or invalid after recording.

## Cursor Overlay

The cursor is a manual overlay controlled by the Mac mouse or trackpad inside the phone preview.

Implementation behavior:

- Track mouse movement within the preview bounds.
- Normalize pointer location to phone-video coordinates.
- Record cursor telemetry samples with timestamps relative to recording start.
- Record click and mouse-up samples.
- Render a transparent PNG cursor with configured hotspot, scale, opacity, and shadow.
- Clamp or hide cursor when the pointer leaves the preview area.
- Preserve correct mapping for portrait and landscape video.

Cursor rendering can be implemented with Core Animation/Core Image during preview and AVFoundation/Core Graphics compositing during export.

## Output Pipeline

### iPhone

Preferred flow:

1. Capture phone video frames.
2. Composite cursor overlay into each frame during recording.
3. Write final MP4 directly with `AVAssetWriter`.
4. Include audio if the capture device exposes it.

Fallback flow:

1. Record clean source MP4.
2. Store cursor telemetry.
3. Post-process source MP4 into final cursor-composited MP4.

### Android

Use post-processing:

1. Run scrcpy recording to a temporary source MP4.
2. Store cursor telemetry while recording.
3. Read the source MP4 with `AVAssetReader`.
4. Composite cursor overlay frame by frame.
5. Write final MP4 with `AVAssetWriter`.
6. Remove temporary source MP4 after success.

## User-Facing States

The app should expose these states clearly:

- No phone connected.
- Phone connected and ready.
- iPhone connected but not trusted.
- iPhone source unsupported on this Mac/macOS/device combination.
- Android tools missing.
- Android device unauthorized.
- Android USB debugging missing.
- Recording.
- Stopping.
- Post-processing.
- Recording saved.
- Recording failed.

## Test Plan

### iPhone

- Trusted iPhone appears in device picker.
- 30-second recording completes.
- Portrait and landscape recordings map cursor correctly.
- Device unplug during recording produces a clear error.
- Output MP4 contains cursor overlay.
- Audio is included when exposed by the capture source.

### Android

- Missing `scrcpy` or `adb` shows the Homebrew setup message.
- Unauthorized device shows the USB debugging/trust message.
- Multiple devices can be selected deterministically.
- 30-second scrcpy recording completes.
- Final post-processed MP4 includes cursor overlay.
- Temporary source files are removed after success or cancel.

### Cursor

- Hotspot alignment is visually correct.
- Cursor scale and opacity are reflected in output.
- Click samples produce expected visual behavior if click styling is enabled.
- Cursor stays mapped correctly after preview resize.
- Cursor is hidden or clamped when leaving preview bounds.

### Output

- MP4 duration matches recording duration within a small tolerance.
- Output dimensions match source video dimensions.
- Repeated recordings work without restarting the app.
- Cancel leaves no stale final output.
- Failed post-processing preserves useful error context.

## Build and Packaging

- Build as a native macOS app through Xcode.
- Add Info.plist usage descriptions for camera, microphone, and relevant capture permissions.
- Do not bundle Android tools for V1.
- App should detect Homebrew paths for Android tooling and show setup instructions when unavailable.
- Keep notarization/signing as a later packaging milestone unless distribution is required immediately.

## Defaults and Assumptions

- App name: `Cursor Recorder`.
- Project folder: `game-phone-recorder`.
- macOS target: 14+.
- Phone connection: USB only.
- Android tooling: user-installed through Homebrew.
- Cursor mode: manual Mac-controlled overlay.
- Output format: MP4.
- First useful version: one-click recording and save, not an editor.

## References

- OpenScreen: https://github.com/siddharthvaddem/openscreen
- Apple AVFoundation `AVCaptureDevice`: https://developer.apple.com/documentation/avfoundation/avcapturedevice
- Apple ScreenCaptureKit: https://developer.apple.com/documentation/screencapturekit
- scrcpy: https://github.com/Genymobile/scrcpy
