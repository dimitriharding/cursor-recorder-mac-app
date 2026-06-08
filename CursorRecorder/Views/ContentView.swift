import SwiftUI
import AVKit

struct ContentView: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @State private var showSetup = false
    @AppStorage("hasSeenSetup") private var hasSeenSetup = false

    var body: some View {
        HSplitView {
            // Preview area — shows the live preview, or the just-recorded clip for review.
            VStack(spacing: 0) {
                StatusBar(coordinator: coordinator, showSetup: $showSetup)
                if case .saved(let url) = coordinator.state {
                    ReviewPlayerView(url: url, coordinator: coordinator)
                        .id(url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                } else {
                    PhonePreviewView(coordinator: coordinator)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                }
            }
            .frame(minWidth: 460)

            // Controls sidebar.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DeviceSection(coordinator: coordinator)
                    Divider()
                    RecordSection(coordinator: coordinator)
                    Divider()
                    CursorSection(coordinator: coordinator)
                    Divider()
                    CaptureSection(coordinator: coordinator)
                    Divider()
                    OutputSection(coordinator: coordinator)
                    Spacer(minLength: 0)
                }
                .padding(18)
            }
            .frame(minWidth: 320, idealWidth: 340, maxWidth: 420)
        }
        .sheet(isPresented: $showSetup) {
            SetupChecklistView(coordinator: coordinator)
        }
        .onAppear {
            if !hasSeenSetup {
                hasSeenSetup = true
                // Give the initial scan a moment, then show the checklist if needed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if coordinator.needsSetup { showSetup = true }
                }
            }
        }
    }
}

// MARK: - Review player

/// In-app playback of the just-finished recording, so the user can review without opening
/// Finder. Includes quick actions to reveal, share, or start a new take.
private struct ReviewPlayerView: View {
    let url: URL
    @ObservedObject var coordinator: RecordingCoordinator
    @State private var player: AVPlayer

    init(url: URL, coordinator: RecordingCoordinator) {
        self.url = url
        self.coordinator = coordinator
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()

                if coordinator.isExporting {
                    ProgressView(value: coordinator.exportProgress).frame(width: 90)
                    Text("Exporting…").font(.caption2).foregroundStyle(.secondary)
                } else {
                    if let msg = coordinator.exportMessage {
                        Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Menu {
                        ForEach(RecordingQuality.allCases) { q in
                            Button("\(q.label)") { coordinator.exportCopy(quality: q) }
                        }
                    } label: {
                        Label("Export as", systemImage: "square.and.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Button { coordinator.revealOutput() } label: { Label("Reveal", systemImage: "folder") }
                    Button { coordinator.shareLastRecording() } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { player.pause(); coordinator.acknowledgeResult() } label: {
                        Label("New", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(10)
            .background(.bar)
        }
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @Binding var showSetup: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(title).font(.system(size: 13, weight: .medium))
            if case .recording = coordinator.state {
                Text(timeString(coordinator.elapsed))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.red)
            }
            if case .postProcessing(let p) = coordinator.state {
                ProgressView(value: p).frame(width: 120)
            }
            Spacer()
            if detail != nil {
                Text(detail!).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Button {
                showSetup = true
            } label: {
                Label("Setup", systemImage: "checklist")
            }
            .buttonStyle(.borderless)
            .help("Setup checklist")
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(.bar)
    }

    private var color: Color {
        switch coordinator.state {
        case .ready: return .green
        case .recording: return .red
        case .stopping, .postProcessing: return .orange
        case .saved: return .blue
        case .failed: return .red
        case .idle: return .gray
        default: return .yellow
        }
    }

    private var title: String {
        switch coordinator.state {
        case .idle: return "No phone connected"
        case .ready: return "Ready"
        case .waitingForTrust: return "iPhone not trusted"
        case .unsupported: return "Source unsupported"
        case .androidToolsMissing: return "Android tools missing"
        case .androidUnauthorized: return "Android device unauthorized"
        case .androidDebuggingMissing: return "USB debugging disabled"
        case .recording: return "Recording"
        case .stopping: return "Stopping…"
        case .postProcessing: return "Compositing cursor…"
        case .saved: return "Saved"
        case .failed: return "Failed"
        }
    }

    private var detail: String? {
        switch coordinator.state {
        case .saved(let url): return url.lastPathComponent
        case .failed(let msg): return msg
        default: return coordinator.selectedDevice?.name
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - Device section

private struct DeviceSection: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Device", systemImage: "iphone")

            if coordinator.devices.isEmpty {
                Text("No phone detected. Connect an iPhone (trusted) or an Android device with USB debugging on, then rescan.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { coordinator.selectedDeviceID ?? "" },
                    set: { coordinator.selectDevice($0) }
                )) {
                    ForEach(coordinator.devices) { device in
                        Text(label(for: device)).tag(device.id)
                    }
                }
                .labelsHidden()
                .disabled(coordinator.state.isBusy)
            }

            HStack {
                Button {
                    coordinator.scan()
                } label: {
                    Label(coordinator.isScanning ? "Scanning…" : "Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(coordinator.isScanning || coordinator.state.isBusy)

                Button {
                    coordinator.reset()
                } label: {
                    Label("Reset / Reconnect", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(coordinator.isScanning || coordinator.state.isBusy)
                .help("Tear down the connection, re-enable the iPhone screen source, and reconnect.")
            }

            Button {
                coordinator.scan()
            } label: {
                Label("Reload Windows & Simulators", systemImage: "macwindow.on.rectangle")
            }
            .disabled(coordinator.isScanning || coordinator.state.isBusy)
            .help("Re-scan open windows and running iOS Simulators (use after opening iPhone Mirroring or a Simulator).")

            if coordinator.mirroringNeedsPermission {
                hintBox {
                    Text("Screen Recording permission needed").font(.caption).bold()
                    Text("To capture iPhone Mirroring or the iOS Simulator, grant Screen Recording. After granting, quit and reopen the app.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Grant…") { coordinator.requestScreenRecordingPermission() }
                        Button("Open Settings") { coordinator.openPrivacyPane(.screenRecording) }
                    }
                    .font(.caption)
                }
            }

            SetupHint(coordinator: coordinator)
        }
    }

    private func hintBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
    }

    private func label(for device: PhoneCaptureDevice) -> String {
        switch device.backend {
        case .mirroring: return device.name           // already descriptive
        case .android: return "Android: \(device.name)"
        case .iphoneUSB: return "iPhone: \(device.name)"
        }
    }
}

/// Contextual setup help for non-ready states.
private struct SetupHint: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        Group {
            switch coordinator.state {
            case .androidToolsMissing:
                hintBox {
                    Text("Install the Android tools:").font(.caption)
                    CopyableCommand(text: "brew install scrcpy android-platform-tools")
                }
            case .androidUnauthorized:
                hint("On the phone, tap “Allow USB debugging” for this Mac, then rescan.")
            case .androidDebuggingMissing:
                hint("Enable Developer Options ▸ USB debugging on the Android device, then rescan.")
            case .waitingForTrust:
                hintBox {
                    Text("iPhone screen not shared yet").font(.caption).bold()
                    Text("The iPhone is only visible as a wireless Continuity Camera. To record the screen:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("1. Connect the iPhone with a USB data cable.\n2. Unlock the iPhone.\n3. Tap “Trust This Computer” (enter passcode).\n4. Click Reset / Reconnect.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .unsupported:
                hint("This Mac/macOS/device combination does not expose the iPhone screen as a capture source.")
            default:
                EmptyView()
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func hintBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
    }
}

struct CopyableCommand: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Record section

private struct RecordSection: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Recording", systemImage: "record.circle")

            HStack(spacing: 10) {
                Button(action: { coordinator.toggleRecording() }) {
                    Label(primaryLabel, systemImage: primaryIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? .red : .accentColor)
                .controlSize(.large)
                .disabled(!canToggle)
            }

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    coordinator.cancelRecording()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .disabled(!coordinator.state.isBusy)

                if case .saved = coordinator.state {
                    Button { coordinator.revealOutput() } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                }
            }

            if case .failed(let msg) = coordinator.state {
                Text(msg).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { coordinator.acknowledgeResult() }.font(.caption)
            }
            if case .saved = coordinator.state {
                Button("New recording") { coordinator.acknowledgeResult() }.font(.caption)
            }
        }
    }

    private var isRecording: Bool { if case .recording = coordinator.state { return true }; return false }
    private var canToggle: Bool {
        switch coordinator.state { case .ready, .recording: return true; default: return false }
    }
    private var primaryLabel: String { isRecording ? "Stop" : "Record" }
    private var primaryIcon: String { isRecording ? "stop.fill" : "record.circle.fill" }
}

// MARK: - Cursor section

private struct CursorSection: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Cursor", systemImage: "cursorarrow")
                Spacer()
                Text(currentName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            CursorGallery(coordinator: coordinator)

            HStack {
                Button("Choose PNG…") { coordinator.chooseCursorImage() }
                Button("Cursor folder…") { coordinator.revealCursorsFolder() }
            }
            Text("Tap a cursor to use it. Drop transparent PNGs into the cursor folder to add your own.")
                .font(.caption2).foregroundStyle(.tertiary)

            labeledSlider("Scale", value: $coordinator.cursorConfig.scale, range: 0.3...3.0)
            labeledSlider("Opacity", value: $coordinator.cursorConfig.opacity, range: 0.1...1.0)
            labeledSlider("Smoothing", value: $coordinator.cursorConfig.smoothing, range: 0.0...1.0)

            Text("Hotspot (click point)").font(.caption).foregroundStyle(.secondary)
            labeledSlider("Hotspot X", value: $coordinator.cursorConfig.hotspot.x, range: 0.0...1.0)
            labeledSlider("Hotspot Y", value: $coordinator.cursorConfig.hotspot.y, range: 0.0...1.0)

            Toggle("Drop shadow", isOn: $coordinator.cursorConfig.shadowEnabled)
        }
    }

    /// Display name of the currently selected cursor.
    private var currentName: String {
        guard let url = coordinator.cursorConfig.imageURL else { return "Default pointer" }
        if let match = coordinator.allCursors.first(where: { $0.url == url }) { return match.displayName }
        return url.deletingPathExtension().lastPathComponent
    }

    private func labeledSlider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        HStack {
            Text(title).frame(width: 78, alignment: .leading).font(.caption)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = CGFloat($0) }
            ), in: Double(range.lowerBound)...Double(range.upperBound))
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Cursor gallery

/// A visual grid for browsing and selecting cursors (built-in pack + user folder).
private struct CursorGallery: View {
    @ObservedObject var coordinator: RecordingCoordinator

    private let columns = [GridItem(.adaptive(minimum: 60, maximum: 80), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                CursorTile(
                    image: CursorThumbnails.defaultPointer,
                    name: "Default",
                    selected: coordinator.cursorConfig.imageURL == nil
                ) { coordinator.useDefaultCursor() }

                ForEach(coordinator.allCursors) { cursor in
                    CursorTile(
                        image: CursorThumbnails.image(for: cursor),
                        name: cursor.displayName,
                        selected: coordinator.cursorConfig.imageURL == cursor.url
                    ) { coordinator.selectBundledCursor(cursor) }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 196)
        .background(Color(white: 0.5, opacity: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CursorTile: View {
    let image: NSImage?
    let name: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(white: 0.16))
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(7)
                    }
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.08),
                                      lineWidth: selected ? 2.5 : 1)
                }
                .frame(width: 58, height: 58)

                Text(name)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: 72)
            }
        }
        .buttonStyle(.plain)
        .help(name)
    }
}

/// Small NSImage cache for cursor thumbnails so the grid doesn't reload from disk on every
/// re-render.
enum CursorThumbnails {
    private static var cache: [String: NSImage] = [:]

    static let defaultPointer: NSImage? = {
        let cg = CursorRenderer.drawDefaultPointer()
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }()

    static func image(for cursor: BundledCursor) -> NSImage? {
        if let cached = cache[cursor.id] { return cached }
        guard let url = cursor.url, let img = NSImage(contentsOf: url) else { return nil }
        cache[cursor.id] = img
        return img
    }
}

// MARK: - Capture section

private struct CaptureSection: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Capture", systemImage: "gauge.with.dots.needle.bottom.50percent")

            HStack {
                Text("Quality").font(.caption).frame(width: 90, alignment: .leading)
                Picker("", selection: $coordinator.recordingQuality) {
                    ForEach(RecordingQuality.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }

            HStack {
                Text("Frame rate").font(.caption).frame(width: 90, alignment: .leading)
                Picker("", selection: $coordinator.captureFPS) {
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Toggle("Capture audio (window sources)", isOn: $coordinator.captureAudio)
                .font(.caption)

            HStack {
                Text("Crop (trim frame)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { coordinator.crop = .zero }
                    .font(.caption2)
                    .disabled(coordinator.crop.isZero)
            }
            cropSlider("Top", value: $coordinator.crop.top)
            cropSlider("Bottom", value: $coordinator.crop.bottom)
            cropSlider("Left", value: $coordinator.crop.left)
            cropSlider("Right", value: $coordinator.crop.right)

            Text("Frame rate, audio, and crop apply to window sources (iPhone Mirroring, Simulator, any window). Use crop to remove the title bar / device bezel so it's just the screen.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func cropSlider(_ title: String, value: Binding<CGFloat>) -> some View {
        HStack {
            Text(title).frame(width: 56, alignment: .leading).font(.caption)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = CGFloat($0) }
            ), in: 0...0.45)
            Text("\(Int(value.wrappedValue * 100))%")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 36, alignment: .trailing)
        }
    }
}

// MARK: - Output section

private struct OutputSection: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Output", systemImage: "folder")

            HStack(spacing: 4) {
                TextField("Recording name (optional)", text: $coordinator.outputFileName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(coordinator.state.isBusy)
                Text(".mp4").font(.caption).foregroundStyle(.secondary)
            }
            Text("Blank uses a timestamp. Existing files are never overwritten.")
                .font(.caption2).foregroundStyle(.tertiary)

            HStack {
                Text(coordinator.outputFolder.path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Change…") { coordinator.chooseOutputFolder() }
            }
            Text("Saved as MP4 (H.264) with the cursor overlay composited in.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Shared bits

private struct SectionHeader: View {
    let title: String
    let systemImage: String
    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
