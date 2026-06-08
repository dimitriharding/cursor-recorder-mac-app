import Foundation

/// Locates Homebrew-installed command line tools (adb, scrcpy). V1 does not bundle them.
enum ToolLocator {
    /// Common locations Homebrew installs binaries into, plus anything on PATH.
    private static let searchDirs = [
        "/opt/homebrew/bin",   // Apple Silicon Homebrew
        "/usr/local/bin",      // Intel Homebrew
        "/usr/bin",
        "/bin",
    ]

    /// Returns the absolute path to `tool` if found, otherwise nil.
    static func path(for tool: String) -> String? {
        let fm = FileManager.default
        for dir in searchDirs {
            let candidate = (dir as NSString).appendingPathComponent(tool)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        // Fall back to `which`, honoring the user's login PATH where possible.
        if let viaWhich = which(tool) { return viaWhich }
        return nil
    }

    static var adbPath: String? { path(for: "adb") }
    static var scrcpyPath: String? { path(for: "scrcpy") }

    /// True only when both Android tools are present.
    static var androidToolsAvailable: Bool { adbPath != nil && scrcpyPath != nil }

    /// The setup command users should run when Android tools are missing.
    static let brewInstallCommand = "brew install scrcpy android-platform-tools"

    private static func which(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", tool]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            return nil
        }
        return nil
    }
}
