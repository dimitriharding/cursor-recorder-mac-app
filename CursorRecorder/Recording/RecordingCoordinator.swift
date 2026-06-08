import Foundation
import AppKit
import AVFoundation
import QuartzCore
import Combine

/// Central orchestrator. Owns the adapters, cursor state, and the user-facing state machine.
@MainActor
final class RecordingCoordinator: ObservableObject {

    // MARK: - Published UI state

    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var devices: [PhoneCaptureDevice] = []
    @Published var selectedDeviceID: String?
    @Published private(set) var isScanning = false
    @Published private(set) var lastOutputURL: URL?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0
    @Published private(set) var exportMessage: String?

    @Published var cursorConfig: CursorOverlayConfig = .default {
        didSet { renderer.update(config: cursorConfig); persistSettings() }
    }
    @Published var outputFolder: URL = RecordingCoordinator.defaultOutputFolder() {
        didSet { persistSettings() }
    }
    /// Optional base name for the next recording (no extension). Blank → timestamped name.
    @Published var outputFileName: String = ""
    /// Output resolution / quality preset.
    @Published var recordingQuality: RecordingQuality = .p1080 { didSet { persistSettings() } }
    /// Run as a menu-bar utility with no Dock icon (the menu bar item stays regardless).
    @Published var menuBarOnly: Bool = false {
        didSet { persistSettings(); applyActivationPolicy() }
    }

    /// Capture frame rate for the ScreenCaptureKit (Mirroring / Simulator) path.
    @Published var captureFPS: Int = 60 {
        didSet { persistSettings(); restartMirroringIfActive() }
    }
    /// Capture system audio for the Mirroring / Simulator path.
    @Published var captureAudio: Bool = true {
        didSet { persistSettings(); restartMirroringIfActive() }
    }
    /// Crop applied to window/Mirroring/Simulator sources to trim chrome → "just the screen".
    @Published var crop: CropInsets = .zero {
        didSet { persistSettings(); restartMirroringIfActive() }
    }

    /// Cursors discovered in the user cursor folder (the OpenScreen-style "cursor pack").
    @Published private(set) var userCursors: [BundledCursor] = []

    // MARK: - Shared capture objects

    let liveCursor = LiveCursor()
    private let telemetry = CursorTelemetryRecorder()
    private let renderer: CursorRenderer
    private let globalCursorTracker = GlobalCursorTracker()

    private lazy var iPhoneAdapter = IPhoneUSBCaptureAdapter(
        renderer: renderer, liveCursor: liveCursor, telemetry: telemetry
    )
    private lazy var mirroringAdapter = MirroringCaptureAdapter(
        renderer: renderer, liveCursor: liveCursor, telemetry: telemetry
    )
    private lazy var androidAdapter = AndroidScrcpyCaptureAdapter(
        renderer: renderer, telemetry: telemetry
    )

    private var session: RecordingSession?
    private var elapsedTimer: Timer?
    private var recordingStart: Date?

    init() {
        renderer = CursorRenderer(config: .default)
        loadSettings()
        renderer.update(config: cursorConfig)
        refreshCursorList()

        // Surface capture runtime errors / mid-recording disconnects as a clear failure.
        let onError: (String) -> Void = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                if self.state.isBusy || self.state == .ready {
                    self.stopElapsedTimer()
                    self.state = .failed(message)
                }
            }
        }
        iPhoneAdapter.onRuntimeError = onError
        mirroringAdapter.onRuntimeError = onError

        // Auto-refresh the device list when a phone is plugged in or removed.
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.state.isBusy, !self.isScanning else { return }
                    self.scan()
                }
            }
        }

        // In menu-bar-only mode, re-hide the Dock icon once the window is closed.
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.menuBarOnly else { return }
                let stillVisible = NSApp.windows.contains { $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized }
                if !stillVisible { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    var selectedDevice: PhoneCaptureDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    private var activeAdapter: PhoneCaptureAdapter? {
        switch selectedDevice?.backend {
        case .iphoneUSB: return iPhoneAdapter
        case .mirroring: return mirroringAdapter
        case .android: return androidAdapter
        case nil: return nil
        }
    }

    var previewLayer: CALayer? { activeAdapter?.previewLayer }

    // MARK: - Scanning

    func scan() {
        guard !isScanning, !state.isBusy else { return }
        isScanning = true
        Task {
            var found: [PhoneCaptureDevice] = []
            do { found += try await iPhoneAdapter.scanDevices() }
            catch { reportScanError(error) }
            do { found += try await mirroringAdapter.scanDevices() }
            catch { reportScanError(error) }
            do { found += try await androidAdapter.scanDevices() }
            catch { reportScanError(error) }

            self.devices = found
            self.reconcileSelection()
            self.isScanning = false
            await self.startPreviewIfReady()
        }
    }

    /// Full reconnect: tear down the live preview, re-enable the CoreMediaIO screen-capture
    /// source, clear the device list, and rescan from scratch. Use when a connected phone
    /// isn't showing up or the preview is stuck.
    func reset() {
        guard !state.isBusy else { return }   // never reset mid-recording
        isScanning = true
        Task {
            globalCursorTracker.stop()
            await iPhoneAdapter.stopPreview()
            await mirroringAdapter.stopPreview()
            await androidAdapter.stopPreview()
            self.devices = []
            self.selectedDeviceID = nil
            self.state = .idle
            CoreMediaIOEnabler.enableScreenCaptureDevices()
            // Brief settle so the screen-capture device re-enumerates cleanly.
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.isScanning = false
            self.scan()
        }
    }

    private func reconcileSelection() {
        if let id = selectedDeviceID, devices.contains(where: { $0.id == id }) { return }
        // Prefer the first ready device, otherwise the first entry.
        selectedDeviceID = devices.first(where: { $0.isReady })?.id ?? devices.first?.id
        updateStateFromSelection()
    }

    func selectDevice(_ id: String) {
        selectedDeviceID = id
        updateStateFromSelection()
        Task { await startPreviewIfReady() }
    }

    private func updateStateFromSelection() {
        guard let device = selectedDevice else { state = .idle; return }
        switch device.readiness {
        case .ready: state = .ready
        case .waitingForTrust:
            state = device.platform == .iphone ? .waitingForTrust : .androidUnauthorized
        case .missingAndroidTools: state = .androidToolsMissing
        case .missingUSBDebugging: state = .androidDebuggingMissing
        case .unsupported: state = .unsupported
        case .disconnected: state = .idle
        }
    }

    private func startPreviewIfReady() async {
        globalCursorTracker.stop()
        guard let device = selectedDevice, device.isReady, let adapter = activeAdapter else { return }
        if device.backend == .mirroring {
            mirroringAdapter.fps = captureFPS
            mirroringAdapter.capturesAudio = captureAudio
            mirroringAdapter.crop = crop
        }
        do {
            try await adapter.startPreview(device: device)
            if case .ready = state {} else { state = .ready }

            // For window/Mirroring/Simulator sources, the user interacts in the real window,
            // so track the pointer over that window (within the crop) and render the cursor.
            if device.backend == .mirroring, let wid = mirroringAdapter.capturedWindowID {
                globalCursorTracker.onSample = { [weak self] point, visible, interaction in
                    self?.updateCursor(normalizedPoint: point, visible: visible, interaction: interaction)
                }
                globalCursorTracker.start(windowID: wid, crop: crop)
            }
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Whether the live cursor is driven by the global tracker (Mirroring) rather than the
    /// in-app preview's local mouse tracking.
    var usesGlobalCursor: Bool { selectedDevice?.backend == .mirroring }

    /// Preview aspect ratio accounting for the crop applied to window sources.
    var effectiveAspectRatio: CGFloat {
        guard let d = selectedDevice else { return 9.0 / 19.5 }
        if d.backend == .mirroring, let w = d.width, let h = d.height, w > 0, h > 0 {
            let cw = CGFloat(w) * crop.widthFraction
            let ch = CGFloat(h) * crop.heightFraction
            return ch > 0 ? cw / ch : d.aspectRatio
        }
        return d.aspectRatio
    }

    /// Restart the Mirroring/Simulator stream when capture options change mid-preview.
    private func restartMirroringIfActive() {
        guard !state.isBusy, selectedDevice?.backend == .mirroring else { return }
        Task { await startPreviewIfReady() }
    }

    // MARK: - Recording controls

    var isRecordingActive: Bool { if case .recording = state { return true }; return false }
    var canStartRecording: Bool { if case .ready = state { return true }; return false }

    /// Short status string for the menu-bar menu header.
    var menuBarStatus: String {
        switch state {
        case .idle: return "No phone connected"
        case .ready: return "Ready" + (selectedDevice.map { " — \($0.name)" } ?? "")
        case .recording: return "Recording…"
        case .stopping: return "Stopping…"
        case .postProcessing: return "Processing…"
        case .saved: return "Saved"
        case .failed: return "Failed"
        case .waitingForTrust: return "iPhone not shared"
        case .unsupported: return "Source unsupported"
        case .androidToolsMissing: return "Android tools missing"
        case .androidUnauthorized: return "Android unauthorized"
        case .androidDebuggingMissing: return "USB debugging off"
        }
    }

    func toggleRecording() {
        switch state {
        case .ready: startRecording()
        case .recording: stopRecording()
        default: break
        }
    }

    func startRecording() {
        guard let device = selectedDevice, device.isReady, let adapter = activeAdapter else { return }
        renderer.update(config: cursorConfig)

        let output = makeOutputURL()
        let newSession = RecordingSession(
            id: UUID(), device: device, startedAt: Date(), outputURL: output,
            quality: recordingQuality, cursor: cursorConfig
        )
        session = newSession

        Task {
            do {
                try await adapter.startRecording(session: newSession)
                self.state = .recording
                self.beginElapsedTimer()
            } catch {
                self.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func stopRecording() {
        guard case .recording = state, let adapter = activeAdapter else { return }
        stopElapsedTimer()
        state = .stopping

        Task {
            do {
                let url: URL
                if let android = adapter as? AndroidScrcpyCaptureAdapter {
                    self.state = .postProcessing(0)
                    url = try await android.stopRecording(progress: { p in
                        Task { @MainActor in self.state = .postProcessing(p) }
                    })
                } else {
                    url = try await adapter.stopRecording()
                }
                self.lastOutputURL = url
                self.state = .saved(url)
            } catch {
                self.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func cancelRecording() {
        stopElapsedTimer()
        guard let adapter = activeAdapter else { return }
        let wasBusy = state.isBusy
        Task {
            await adapter.cancelRecording()
            if wasBusy { await self.startPreviewIfReady() }
            self.state = self.selectedDevice?.isReady == true ? .ready : .idle
        }
    }

    /// Dismisses a terminal (saved/failed) state back to ready/idle for another take.
    func acknowledgeResult() {
        updateStateFromSelection()
    }

    // MARK: - Live cursor input (from the preview view)

    func updateCursor(normalizedPoint: CGPoint, visible: Bool, interaction: CursorInteraction) {
        liveCursor.update(point: normalizedPoint, visible: visible)
        if case .recording = state {
            telemetry.record(
                normalizedPoint: normalizedPoint,
                visible: visible,
                interaction: interaction,
                absoluteTime: CACurrentMediaTime()
            )
        }
    }

    // MARK: - File pickers

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = outputFolder
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
        }
    }

    func chooseCursorImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url {
            cursorConfig.imageURL = url
        }
    }

    func useDefaultCursor() {
        cursorConfig.imageURL = nil
        cursorConfig.hotspot = CGPoint(x: 0.05, y: 0.03)
    }

    func selectBundledCursor(_ cursor: BundledCursor) {
        cursorConfig.imageURL = cursor.url
        cursorConfig.hotspot = cursor.hotspot
    }

    /// All cursors available in the picker: built-in pack + the user cursor folder.
    var allCursors: [BundledCursor] { BundledCursors.all + userCursors }

    /// The folder where users can drop their own transparent-PNG cursors.
    var userCursorsFolderURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Cursor Recorder/Cursors", isDirectory: true)
    }

    /// Rescan the user cursor folder so dropped-in PNGs appear in the picker.
    func refreshCursorList() {
        let fm = FileManager.default
        let dir = userCursorsFolderURL
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { userCursors = []; return }

        userCursors = items
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                BundledCursor(
                    id: "user:" + url.lastPathComponent,
                    displayName: url.deletingPathExtension().lastPathComponent,
                    resource: url.path,
                    // Default custom cursors to a centered hotspot; fine-tune with the sliders.
                    hotspot: CGPoint(x: 0.5, y: 0.5)
                )
            }
    }

    /// Create the user cursor folder (if needed) and reveal it in Finder.
    func revealCursorsFolder() {
        let dir = userCursorsFolderURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
        refreshCursorList()
    }

    func revealOutput() {
        guard let url = lastOutputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Re-export the last recording at a different quality. The recorded MP4 already has the
    /// cursor baked in, so this just transcodes/scales it (no cursor is re-added) and reveals
    /// the new file. The original is kept.
    func exportCopy(quality: RecordingQuality) {
        guard let source = lastOutputURL, !isExporting else { return }
        isExporting = true
        exportProgress = 0
        exportMessage = nil

        // <name> - <tag>.mp4 in the same folder, uniquified.
        let baseName = source.deletingPathExtension().lastPathComponent + " - " + quality.fileTag
        let folder = source.deletingLastPathComponent()
        let fm = FileManager.default
        var dest = folder.appendingPathComponent(baseName).appendingPathExtension("mp4")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(baseName) \(n)").appendingPathExtension("mp4")
            n += 1
        }

        let outURL = dest
        Task {
            do {
                // Empty telemetry → no cursor re-composited (it's already in the source).
                let result = try await VideoCompositor.export(
                    source: source,
                    output: outURL,
                    renderer: CursorRenderer(config: .default),
                    telemetry: CursorTelemetryRecorder(),
                    quality: quality
                ) { p in
                    Task { @MainActor in self.exportProgress = p }
                }
                self.isExporting = false
                self.exportMessage = "Exported \(result.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([result])
            } catch {
                self.isExporting = false
                self.exportMessage = "Export failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    /// Show / focus the main window (recreating it if it was closed), flipping back to a
    /// normal Dock app while it's visible even in menu-bar-only mode.
    func bringToFront(openWindow: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        openWindow()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    /// Apply the Dock-icon visibility from `menuBarOnly`.
    func applyActivationPolicy() {
        if menuBarOnly {
            // Only hide the Dock icon once no main window is on screen.
            let hasMain = NSApp.windows.contains { $0.canBecomeMain && $0.isVisible }
            NSApp.setActivationPolicy(hasMain ? .regular : .accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Present the macOS share sheet for the last recording (AirDrop, Messages, Save to…, etc.).
    func shareLastRecording() {
        guard let url = lastOutputURL,
              let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }

    // MARK: - Setup / permission status (for the checklist)

    var cameraStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    var scrcpyInstalled: Bool { ToolLocator.scrcpyPath != nil }
    var adbInstalled: Bool { ToolLocator.adbPath != nil }
    var androidToolsInstalled: Bool { ToolLocator.androidToolsAvailable }
    var readyDevices: [PhoneCaptureDevice] { devices.filter { $0.isReady } }

    /// True until the basics (a permission grant and a ready device) are in place.
    var needsSetup: Bool {
        cameraStatus != .authorized || readyDevices.isEmpty
    }

    enum PrivacyPane { case camera, microphone, screenRecording }

    func openPrivacyPane(_ pane: PrivacyPane) {
        let suffix: String
        switch pane {
        case .camera: suffix = "Privacy_Camera"
        case .microphone: suffix = "Privacy_Microphone"
        case .screenRecording: suffix = "Privacy_ScreenCapture"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(suffix)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Screen Recording permission is missing while a capturable window source (iPhone
    /// Mirroring or the Simulator) is available — show the grant hint.
    var mirroringNeedsPermission: Bool {
        !MirroringCaptureAdapter.hasScreenRecordingPermission
            && (MirroringCaptureAdapter.iPhoneMirroringRunning || simulatorRunning)
    }

    private var simulatorRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.iphonesimulator" }
    }

    /// Explicitly request Screen Recording permission (shows the system prompt only when
    /// undetermined), then rescan. Triggered by a user button — never automatically.
    func requestScreenRecordingPermission() {
        MirroringCaptureAdapter.requestScreenRecordingPermission()
        scan()
    }

    /// Request camera + microphone access, then rescan so the checklist updates.
    func requestPermissionsAndRescan() {
        Task {
            _ = await Self.requestAccess(.video)
            _ = await Self.requestAccess(.audio)
            self.objectWillChange.send()
            self.scan()
        }
    }

    private static func requestAccess(_ media: AVMediaType) async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: media) == .authorized { return true }
        return await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: media) { cont.resume(returning: $0) }
        }
    }

    // MARK: - Helpers

    private func beginElapsedTimer() {
        recordingStart = Date()
        elapsed = 0
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStart else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func reportScanError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        // Permission errors are worth surfacing immediately.
        if case RecorderState.failed = state { return }
        if !devices.contains(where: { $0.isReady }) {
            state = .failed(message)
        }
    }

    // MARK: - Persistence

    private func persistSettings() {
        let d = UserDefaults.standard
        d.set(outputFolder.path, forKey: "outputFolder")
        d.set(cursorConfig.imageURL?.path, forKey: "cursorImagePath")
        d.set(Double(cursorConfig.scale), forKey: "cursorScale")
        d.set(Double(cursorConfig.opacity), forKey: "cursorOpacity")
        d.set(Double(cursorConfig.smoothing), forKey: "cursorSmoothing")
        d.set(cursorConfig.shadowEnabled, forKey: "cursorShadow")
        d.set(Double(cursorConfig.hotspot.x), forKey: "cursorHotspotX")
        d.set(Double(cursorConfig.hotspot.y), forKey: "cursorHotspotY")
        d.set(captureFPS, forKey: "captureFPS")
        d.set(captureAudio, forKey: "captureAudio")
        d.set(Double(crop.top), forKey: "cropTop")
        d.set(Double(crop.bottom), forKey: "cropBottom")
        d.set(Double(crop.left), forKey: "cropLeft")
        d.set(Double(crop.right), forKey: "cropRight")
        d.set(recordingQuality.rawValue, forKey: "recordingQuality")
        d.set(menuBarOnly, forKey: "menuBarOnly")
    }

    private func loadSettings() {
        let d = UserDefaults.standard
        if let path = d.string(forKey: "outputFolder") {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            // Migrate the old default (~/Movies root) to the new ~/Movies/cursor-recorder.
            let oldDefault = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            if let oldDefault, url.standardizedFileURL == oldDefault.standardizedFileURL {
                outputFolder = Self.defaultOutputFolder()
            } else if FileManager.default.fileExists(atPath: url.path) {
                outputFolder = url
            }
        }
        var config = CursorOverlayConfig.default
        if let path = d.string(forKey: "cursorImagePath"), FileManager.default.fileExists(atPath: path) {
            config.imageURL = URL(fileURLWithPath: path)
        }
        if d.object(forKey: "cursorScale") != nil { config.scale = CGFloat(d.double(forKey: "cursorScale")) }
        if d.object(forKey: "cursorOpacity") != nil { config.opacity = CGFloat(d.double(forKey: "cursorOpacity")) }
        if d.object(forKey: "cursorSmoothing") != nil { config.smoothing = CGFloat(d.double(forKey: "cursorSmoothing")) }
        if d.object(forKey: "cursorShadow") != nil { config.shadowEnabled = d.bool(forKey: "cursorShadow") }
        if d.object(forKey: "cursorHotspotX") != nil {
            config.hotspot = CGPoint(x: d.double(forKey: "cursorHotspotX"), y: d.double(forKey: "cursorHotspotY"))
        }
        cursorConfig = config

        if d.object(forKey: "captureFPS") != nil {
            let v = d.integer(forKey: "captureFPS")
            if v > 0 { captureFPS = v }
        }
        if d.object(forKey: "captureAudio") != nil { captureAudio = d.bool(forKey: "captureAudio") }
        if let q = d.string(forKey: "recordingQuality"), let parsed = RecordingQuality(rawValue: q) {
            recordingQuality = parsed
        }
        if d.object(forKey: "menuBarOnly") != nil { menuBarOnly = d.bool(forKey: "menuBarOnly") }
        if d.object(forKey: "cropTop") != nil {
            crop = CropInsets(
                top: CGFloat(d.double(forKey: "cropTop")),
                bottom: CGFloat(d.double(forKey: "cropBottom")),
                left: CGFloat(d.double(forKey: "cropLeft")),
                right: CGFloat(d.double(forKey: "cropRight"))
            )
        }
    }

    /// Builds the output URL from the user-provided name (or a timestamp), sanitized, and
    /// uniquified so an existing file is never overwritten.
    private func makeOutputURL() -> URL {
        let raw = outputFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = raw.isEmpty ? Self.timestampName() : Self.sanitize(raw)
        if base.isEmpty { base = Self.timestampName() }

        let fm = FileManager.default
        try? fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        var candidate = outputFolder.appendingPathComponent(base).appendingPathExtension("mp4")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = outputFolder.appendingPathComponent("\(base) \(n)").appendingPathExtension("mp4")
            n += 1
        }
        return candidate
    }

    /// Strips a trailing ".mp4" and characters illegal in file names.
    private static func sanitize(_ name: String) -> String {
        var s = name
        if s.lowercased().hasSuffix(".mp4") { s = String(s.dropLast(4)) }
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return s.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func timestampName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Recording_\(formatter.string(from: Date()))"
    }

    private static func defaultOutputFolder() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let folder = movies.appendingPathComponent("cursor-recorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
