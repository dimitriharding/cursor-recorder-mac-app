import Foundation
import AppKit

/// Tracks the real Mac pointer over a specific on-screen window (the iPhone Mirroring
/// window) and reports its position normalized to that window. This lets the user control
/// the phone in the iPhone Mirroring app as usual while the recorder renders the chosen
/// finger/cursor exactly where they're interacting.
///
/// Uses polling of `NSEvent.mouseLocation` + `NSEvent.pressedMouseButtons`, which require no
/// special permissions (unlike global keyboard monitoring).
final class GlobalCursorTracker {

    /// Called ~60×/sec with the pointer state in window-normalized (top-left) coordinates.
    var onSample: ((_ normalizedPoint: CGPoint, _ visible: Bool, _ interaction: CursorInteraction) -> Void)?

    private var windowID: CGWindowID?
    private var crop: CropInsets = .zero
    private var timer: Timer?
    private var wasPressed = false

    func start(windowID: CGWindowID, crop: CropInsets = .zero) {
        stop()
        self.windowID = windowID
        self.crop = crop
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        windowID = nil
        crop = .zero
        wasPressed = false
    }

    private func tick() {
        guard let windowID, let bounds = Self.windowBounds(windowID) else { return }

        // Map the pointer into the cropped sub-region of the window, so the rendered cursor
        // aligns with the cropped ("just the screen") recording.
        let region = CGRect(
            x: bounds.minX + bounds.width * crop.left,
            y: bounds.minY + bounds.height * crop.top,
            width: bounds.width * crop.widthFraction,
            height: bounds.height * crop.heightFraction
        )
        let mouse = Self.mouseLocationTopLeft()
        let nx = (mouse.x - region.minX) / region.width
        let ny = (mouse.y - region.minY) / region.height
        let visible = (0...1).contains(nx) && (0...1).contains(ny)

        let pressed = (NSEvent.pressedMouseButtons & 0x1) != 0
        let interaction: CursorInteraction
        if pressed && !wasPressed { interaction = .click }
        else if !pressed && wasPressed { interaction = .mouseUp }
        else { interaction = .move }
        wasPressed = pressed

        let clamped = CGPoint(x: min(1, max(0, nx)), y: min(1, max(0, ny)))
        onSample?(clamped, visible, interaction)
    }

    /// Current pointer in global top-left screen coordinates (CG space), matching the
    /// coordinate space returned by `CGWindowListCopyWindowInfo` bounds.
    private static func mouseLocationTopLeft() -> CGPoint {
        let p = NSEvent.mouseLocation                       // bottom-left, primary-screen origin
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// Live bounds of the window (top-left screen coordinates). Window bounds are available
    /// without Screen Recording permission, so tracking works even before it's granted.
    private static func windowBounds(_ windowID: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], windowID
        ) as? [[String: Any]],
        let dict = info.first,
        let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
            return nil
        }
        return rect.width > 1 && rect.height > 1 ? rect : nil
    }
}
