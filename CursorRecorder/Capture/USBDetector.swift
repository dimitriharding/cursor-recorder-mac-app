import Foundation

/// Lightweight USB inspection via `ioreg`, used to distinguish "no iPhone plugged in" from
/// "iPhone plugged in but not yet trusted / not exposing a capture source".
enum USBDetector {

    /// True if an Apple mobile device (iPhone/iPad) appears on the USB bus.
    static func appleMobileDevicePresent() -> Bool {
        let dump = ioregUSBDump().lowercased()
        guard !dump.isEmpty else { return false }
        // Apple vendor id is 0x05ac; mobile devices advertise iPhone/iPad product names.
        let appleVendor = dump.contains("\"idvendor\" = 1452") // 0x05AC == 1452
        let mobileName = dump.contains("iphone") || dump.contains("ipad")
        return mobileName || appleVendor
    }

    private static func ioregUSBDump() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-p", "IOUSB", "-l", "-w", "0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
