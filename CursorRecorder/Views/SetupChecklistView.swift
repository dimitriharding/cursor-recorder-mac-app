import SwiftUI
import AVFoundation

/// First-run setup checklist. Shows live status for permissions, a connected/ready phone,
/// and the optional Android tooling, with one-tap actions to fix each item.
struct SetupChecklistView: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Setup checklist", systemImage: "checklist")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    cameraRow
                    microphoneRow
                    phoneRow
                    androidToolsRow
                }
                .padding(16)
            }

            Divider()
            HStack {
                Button {
                    coordinator.scan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(coordinator.isScanning)
                Spacer()
                Text("You can reopen this from the Setup button anytime.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .frame(width: 480, height: 460)
    }

    // MARK: - Rows

    private var cameraRow: some View {
        ChecklistRow(
            status: status(for: coordinator.cameraStatus),
            title: "Camera access",
            detail: "Required to read the iPhone USB screen source."
        ) {
            permissionAccessory(for: coordinator.cameraStatus, pane: .camera)
        }
    }

    private var microphoneRow: some View {
        ChecklistRow(
            status: status(for: coordinator.microphoneStatus),
            title: "Microphone access",
            detail: "Needed only to capture audio from the iPhone source."
        ) {
            permissionAccessory(for: coordinator.microphoneStatus, pane: .microphone)
        }
    }

    private var phoneRow: some View {
        let ready = coordinator.readyDevices
        return ChecklistRow(
            status: ready.isEmpty ? .warn : .ok,
            title: ready.isEmpty ? "Connect a phone" : "Phone ready",
            detail: ready.isEmpty
                ? "iPhone: plug in via USB, unlock, and tap “Trust”.\nAndroid: enable Developer Options ▸ USB debugging, then authorize this Mac."
                : ready.map { ($0.platform == .iphone ? "iPhone: " : "Android: ") + $0.name }.joined(separator: "\n")
        ) {
            Button("Rescan") { coordinator.scan() }
                .disabled(coordinator.isScanning)
        }
    }

    private var androidToolsRow: some View {
        ChecklistRow(
            status: coordinator.androidToolsInstalled ? .ok : .optional,
            title: "Android tools (optional)",
            detail: coordinator.androidToolsInstalled
                ? "scrcpy and adb found."
                : "Only needed for Android capture. Install with Homebrew:"
        ) {
            EmptyView()
        } extra: {
            if !coordinator.androidToolsInstalled {
                VStack(alignment: .leading, spacing: 4) {
                    CopyableCommand(text: ToolLocator.brewInstallCommand)
                    HStack(spacing: 12) {
                        toolBadge("scrcpy", coordinator.scrcpyInstalled)
                        toolBadge("adb", coordinator.adbInstalled)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func status(for auth: AVAuthorizationStatus) -> ChecklistStatus {
        switch auth {
        case .authorized: return .ok
        case .notDetermined: return .pending
        default: return .warn
        }
    }

    @ViewBuilder
    private func permissionAccessory(for auth: AVAuthorizationStatus, pane: RecordingCoordinator.PrivacyPane) -> some View {
        switch auth {
        case .authorized:
            EmptyView()
        case .notDetermined:
            Button("Grant") { coordinator.requestPermissionsAndRescan() }
        default:
            Button("Open Settings") { coordinator.openPrivacyPane(pane) }
        }
    }

    private func toolBadge(_ name: String, _ found: Bool) -> some View {
        Label(name, systemImage: found ? "checkmark.circle.fill" : "xmark.circle")
            .font(.caption)
            .foregroundStyle(found ? Color.green : Color.secondary)
    }
}

enum ChecklistStatus { case ok, warn, pending, optional }

/// A single checklist row: status icon, title, detail, optional trailing accessory, and an
/// optional full-width extra block beneath the text.
private struct ChecklistRow<Accessory: View, Extra: View>: View {
    let status: ChecklistStatus
    let title: String
    let detail: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var extra: () -> Extra

    init(
        status: ChecklistStatus,
        title: String,
        detail: String,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }
    ) {
        self.status = status
        self.title = title
        self.detail = detail
        self.accessory = accessory
        self.extra = extra
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.system(size: 16))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                accessory()
            }
            let extraView = extra()
            if !(extraView is EmptyView) {
                extraView.padding(.leading, 30)
            }
        }
    }

    private var icon: String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .pending: return "circle"
        case .optional: return "minus.circle"
        }
    }

    private var color: Color {
        switch status {
        case .ok: return .green
        case .warn: return .orange
        case .pending: return .secondary
        case .optional: return .secondary
        }
    }
}
