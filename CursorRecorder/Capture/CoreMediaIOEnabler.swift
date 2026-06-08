import Foundation
import CoreMediaIO

/// Enables CoreMediaIO "screen capture" (DAL) devices so that a USB-tethered, trusted
/// iPhone shows up in `AVCaptureDevice` discovery as a muxed/external source.
///
/// This is the non-obvious step that QuickTime performs internally: without setting
/// `kCMIOHardwarePropertyAllowScreenCaptureDevices`, the iPhone screen source is hidden
/// from AVFoundation.
enum CoreMediaIOEnabler {
    /// Call once, early, before scanning for iPhone capture devices. Idempotent.
    static func enableScreenCaptureDevices() {
        var property = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var allow: UInt32 = 1
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &property,
            0,
            nil,
            size,
            &allow
        )

        if status != noErr {
            NSLog("CoreMediaIOEnabler: failed to enable screen capture devices (status \(status))")
        }
    }
}
