import SwiftUI
import AppKit

@main
struct CursorRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = RecordingCoordinator()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(coordinator: coordinator)
                .frame(minWidth: 920, minHeight: 600)
                .onAppear { coordinator.scan() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Quick access from the macOS menu bar — stays alive even with no window open.
        MenuBarExtra {
            MenuBarContent(coordinator: coordinator)
        } label: {
            Image(systemName: coordinator.isRecordingActive ? "record.circle.fill" : "cursorarrow.rays")
        }
    }
}

/// Applies the persisted Dock-visibility (activation policy) at launch and keeps the app
/// running as a menu-bar utility when its window is closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "menuBarOnly") {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // Don't quit when the last window is closed — live on in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Re-open the main window when the Dock icon is clicked (regular mode).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }
}

/// The menu shown from the menu-bar icon: status, record/stop, device & quality, quick actions.
private struct MenuBarContent: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(coordinator.menuBarStatus)

        if coordinator.isRecordingActive {
            Button("Stop Recording") { coordinator.stopRecording() }
            Button("Cancel Recording") { coordinator.cancelRecording() }
        } else {
            Button("Start Recording") { coordinator.startRecording() }
                .disabled(!coordinator.canStartRecording)
        }

        Divider()

        if !coordinator.devices.isEmpty {
            Picker("Device", selection: Binding(
                get: { coordinator.selectedDeviceID ?? "" },
                set: { coordinator.selectDevice($0) }
            )) {
                ForEach(coordinator.devices) { Text($0.name).tag($0.id) }
            }
        }
        Picker("Quality", selection: $coordinator.recordingQuality) {
            ForEach(RecordingQuality.allCases) { Text($0.label).tag($0) }
        }
        Button("Refresh Windows & Simulators") { coordinator.scan() }
            .disabled(coordinator.isScanning || coordinator.state.isBusy)

        Divider()

        Button("Reveal Last Recording") { coordinator.revealOutput() }
            .disabled(coordinator.lastOutputURL == nil)
        Button("Open Cursor Recorder") {
            coordinator.bringToFront(openWindow: { openWindow(id: "main") })
        }
        Toggle("Run in Menu Bar Only (hide Dock icon)", isOn: $coordinator.menuBarOnly)

        Divider()

        Button("Quit Cursor Recorder") { NSApp.terminate(nil) }
    }
}
