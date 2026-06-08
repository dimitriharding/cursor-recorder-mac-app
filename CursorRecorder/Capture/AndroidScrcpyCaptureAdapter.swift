import Foundation
import QuartzCore

/// Captures an Android device using Homebrew-installed `scrcpy` + `adb`. scrcpy records a
/// clean source MP4; the cursor overlay is composited in afterwards via `VideoCompositor`.
final class AndroidScrcpyCaptureAdapter: PhoneCaptureAdapter {

    let platform: PhonePlatform = .android

    private let renderer: CursorRenderer
    private let telemetry: CursorTelemetryRecorder

    private var scrcpyProcess: Process?
    private var tempSourceURL: URL?
    private var finalOutputURL: URL?
    private var activeSerial: String?
    private var quality: RecordingQuality = .source

    init(renderer: CursorRenderer, telemetry: CursorTelemetryRecorder) {
        self.renderer = renderer
        self.telemetry = telemetry
    }

    /// Android has no embeddable preview layer; the UI uses an aspect-correct canvas and
    /// scrcpy's own mirror window for the live view.
    var previewLayer: CALayer? { nil }

    // MARK: - Discovery

    func scanDevices() async throws -> [PhoneCaptureDevice] {
        guard ToolLocator.androidToolsAvailable, let adb = ToolLocator.adbPath else {
            return [PhoneCaptureDevice(
                id: "android-tools-missing",
                platform: .android,
                name: "Android tools not installed",
                connection: .usb,
                width: nil, height: nil,
                supportsAudio: false,
                readiness: .missingAndroidTools,
                backend: .android
            )]
        }

        let result = runCapture(adb, ["devices", "-l"])
        let lines = result.stdout
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("List of devices") && !$0.hasPrefix("*") }

        var devices: [PhoneCaptureDevice] = []
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }
            let serial = parts[0]
            let state = parts[1]
            let model = parseModel(from: line) ?? serial

            switch state {
            case "device":
                let dims = deviceSize(adb: adb, serial: serial)
                devices.append(PhoneCaptureDevice(
                    id: serial, platform: .android, name: model, connection: .usb,
                    width: dims?.width, height: dims?.height,
                    supportsAudio: true, readiness: .ready, backend: .android
                ))
            case "unauthorized":
                devices.append(PhoneCaptureDevice(
                    id: serial, platform: .android, name: "\(model) (unauthorized)", connection: .usb,
                    width: nil, height: nil, supportsAudio: false, readiness: .waitingForTrust,
                    backend: .android
                ))
            case "offline":
                devices.append(PhoneCaptureDevice(
                    id: serial, platform: .android, name: "\(model) (offline)", connection: .usb,
                    width: nil, height: nil, supportsAudio: false, readiness: .disconnected,
                    backend: .android
                ))
            default:
                continue
            }
        }
        return devices
    }

    // MARK: - Preview

    func startPreview(device: PhoneCaptureDevice) async throws {
        guard ToolLocator.androidToolsAvailable else {
            throw CaptureError.toolMissing("Install Android tools with: \(ToolLocator.brewInstallCommand)")
        }
        switch device.readiness {
        case .ready:
            activeSerial = device.id
        case .waitingForTrust:
            throw CaptureError.deviceNotReady(
                "This device is unauthorized. On the phone, allow USB debugging for this Mac, then rescan."
            )
        case .missingAndroidTools:
            throw CaptureError.toolMissing("Install Android tools with: \(ToolLocator.brewInstallCommand)")
        default:
            throw CaptureError.deviceNotReady("This Android device is not ready.")
        }
    }

    func stopPreview() async { activeSerial = nil }

    // MARK: - Recording

    func startRecording(session: RecordingSession) async throws {
        guard let scrcpy = ToolLocator.scrcpyPath else {
            throw CaptureError.toolMissing("Install scrcpy with: \(ToolLocator.brewInstallCommand)")
        }
        guard let serial = activeSerial ?? (session.device.platform == .android ? session.device.id : nil) else {
            throw CaptureError.deviceNotReady("No Android device selected.")
        }

        renderer.update(config: session.cursor)

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpr-source-\(session.id.uuidString).mp4")
        tempSourceURL = temp
        finalOutputURL = session.outputURL
        quality = session.quality

        let process = Process()
        process.executableURL = URL(fileURLWithPath: scrcpy)
        process.arguments = [
            "-s", serial,
            "--record", temp.path,
            "--window-title", "Cursor Recorder — recording",
        ]
        // Ensure scrcpy can find adb if it's not on the inherited PATH.
        var env = ProcessInfo.processInfo.environment
        if let adb = ToolLocator.adbPath {
            env["ADB"] = adb
            let dir = (adb as NSString).deletingLastPathComponent
            env["PATH"] = dir + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        }
        process.environment = env
        process.standardError = Pipe()
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw CaptureError.processFailed("Failed to launch scrcpy: \(error.localizedDescription)")
        }

        // Detect an immediate early exit (e.g. device vanished).
        try await Task.sleep(nanoseconds: 700_000_000)
        if !process.isRunning {
            throw CaptureError.processFailed("scrcpy exited immediately. Check the device connection and authorization.")
        }

        scrcpyProcess = process
        telemetry.begin(at: CACurrentMediaTime())
    }

    func stopRecording() async throws -> URL {
        guard let process = scrcpyProcess, let temp = tempSourceURL, let output = finalOutputURL else {
            throw CaptureError.processFailed("No active Android recording.")
        }

        // SIGINT lets scrcpy finalize (write the moov atom) the recording cleanly.
        if process.isRunning {
            process.interrupt()
            await waitForExit(process, timeout: 8)
            if process.isRunning {
                process.terminate()
                await waitForExit(process, timeout: 4)
            }
        }
        scrcpyProcess = nil

        guard FileManager.default.fileExists(atPath: temp.path),
              (try? temp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 > 0 else {
            throw CaptureError.sourceInvalid("scrcpy did not produce a valid source recording.")
        }

        do {
            let result = try await VideoCompositor.export(
                source: temp,
                output: output,
                renderer: renderer,
                telemetry: telemetry,
                quality: quality
            ) { _ in }
            try? FileManager.default.removeItem(at: temp)
            tempSourceURL = nil
            return result
        } catch {
            // Keep the temp source so the failure can be diagnosed; surface the error.
            throw error
        }
    }

    /// Variant that reports post-processing progress.
    func stopRecording(progress: @escaping (Double) -> Void) async throws -> URL {
        guard let process = scrcpyProcess, let temp = tempSourceURL, let output = finalOutputURL else {
            throw CaptureError.processFailed("No active Android recording.")
        }
        if process.isRunning {
            process.interrupt()
            await waitForExit(process, timeout: 8)
            if process.isRunning { process.terminate(); await waitForExit(process, timeout: 4) }
        }
        scrcpyProcess = nil

        guard FileManager.default.fileExists(atPath: temp.path),
              (try? temp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 > 0 else {
            throw CaptureError.sourceInvalid("scrcpy did not produce a valid source recording.")
        }

        let result = try await VideoCompositor.export(
            source: temp, output: output, renderer: renderer, telemetry: telemetry,
            quality: quality, progress: progress
        )
        try? FileManager.default.removeItem(at: temp)
        tempSourceURL = nil
        return result
    }

    func cancelRecording() async {
        if let process = scrcpyProcess, process.isRunning {
            process.terminate()
            await waitForExit(process, timeout: 4)
        }
        scrcpyProcess = nil
        if let temp = tempSourceURL { try? FileManager.default.removeItem(at: temp) }
        if let output = finalOutputURL { try? FileManager.default.removeItem(at: output) }
        tempSourceURL = nil
        finalOutputURL = nil
    }

    // MARK: - Helpers

    private func deviceSize(adb: String, serial: String) -> (width: Int, height: Int)? {
        let out = runCapture(adb, ["-s", serial, "shell", "wm", "size"]).stdout
        // e.g. "Physical size: 1080x2400" (and possibly an "Override size:" line).
        for line in out.split(separator: "\n") {
            if let range = line.range(of: #"(\d+)x(\d+)"#, options: .regularExpression) {
                let dims = line[range].split(separator: "x")
                if dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]) {
                    return (w, h)
                }
            }
        }
        return nil
    }

    private func parseModel(from line: String) -> String? {
        guard let range = line.range(of: #"model:([^\s]+)"#, options: .regularExpression) else { return nil }
        return String(line[range]).replacingOccurrences(of: "model:", with: "")
            .replacingOccurrences(of: "_", with: " ")
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) async {
        let deadline = CACurrentMediaTime() + timeout
        while process.isRunning && CACurrentMediaTime() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @discardableResult
    private func runCapture(_ path: String, _ args: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }
}
