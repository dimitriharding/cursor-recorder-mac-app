import Foundation
import CoreImage
import AppKit

/// Renders the cursor overlay. Used to composite the cursor into video frames during
/// recording (iPhone direct path) and during post-processing (Android path).
final class CursorRenderer {

    private(set) var config: CursorOverlayConfig
    /// Full-resolution cursor artwork in Core Image space.
    private var cursorImage: CIImage
    /// Pixel size of the source cursor artwork.
    private var cursorPixelSize: CGSize

    /// Base cursor height as a fraction of the video height (before `config.scale`).
    private let baseHeightFraction: CGFloat = 0.06

    init(config: CursorOverlayConfig) {
        self.config = config
        let loaded = CursorRenderer.loadCursor(config.imageURL)
        self.cursorImage = loaded.image
        self.cursorPixelSize = loaded.size
    }

    func update(config: CursorOverlayConfig) {
        let imageChanged = config.imageURL != self.config.imageURL
        self.config = config
        if imageChanged {
            let loaded = CursorRenderer.loadCursor(config.imageURL)
            self.cursorImage = loaded.image
            self.cursorPixelSize = loaded.size
        }
    }

    /// Composites the cursor onto `base` at `normalizedPoint` (top-left origin, 0...1).
    /// `baseSize` is the pixel size of `base`. Returns `base` unchanged if not visible.
    func composite(base: CIImage, normalizedPoint: CGPoint, visible: Bool, baseSize: CGSize) -> CIImage {
        guard visible, config.opacity > 0 else { return base }

        // Target cursor display height in pixels, preserving artwork aspect ratio.
        let targetHeight = baseSize.height * baseHeightFraction * max(0.1, config.scale)
        let aspect = cursorPixelSize.width / max(1, cursorPixelSize.height)
        let cw = targetHeight * aspect
        let ch = targetHeight

        let scaleX = cw / max(1, cursorPixelSize.width)
        let scaleY = ch / max(1, cursorPixelSize.height)
        var cursor = cursorImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Apply opacity.
        if config.opacity < 1.0 {
            cursor = cursor.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: config.opacity)
            ])
        }

        // Map normalized (top-left) target into Core Image (bottom-left) space.
        let targetX = normalizedPoint.x * baseSize.width
        let targetCIY = baseSize.height - normalizedPoint.y * baseSize.height

        // Hotspot location inside the scaled cursor, in CI (bottom-left) space.
        let hotspotX = config.hotspot.x * cw
        let hotspotCIY = ch - config.hotspot.y * ch

        let tx = targetX - hotspotX
        let ty = targetCIY - hotspotCIY

        var output = base

        // Optional soft drop shadow drawn beneath the cursor.
        if config.shadowEnabled {
            let shadow = cursor
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5 * config.opacity),
                ])
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(2, ch * 0.06)])
                .transformed(by: CGAffineTransform(translationX: tx + ch * 0.03, y: ty - ch * 0.03))
            output = shadow.composited(over: output)
        }

        let placed = cursor.transformed(by: CGAffineTransform(translationX: tx, y: ty))
        output = placed.composited(over: output)
        // Keep the output bounded to the base extent.
        return output.cropped(to: base.extent)
    }

    // MARK: - Cursor artwork loading

    private static func loadCursor(_ url: URL?) -> (image: CIImage, size: CGSize) {
        if let url, let img = CIImage(contentsOf: url) {
            return (img, img.extent.size)
        }
        // Fall back to a programmatically drawn pointer.
        let cg = drawDefaultPointer()
        let ci = CIImage(cgImage: cg)
        return (ci, ci.extent.size)
    }

    /// The cursor artwork as a CGImage for the given config, for live preview rendering.
    static func cgImage(for url: URL?) -> CGImage? {
        if let url, let rep = NSImage(contentsOf: url) {
            var rect = CGRect(origin: .zero, size: rep.size)
            return rep.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return drawDefaultPointer()
    }

    /// Draws a classic arrow pointer with the hotspot at the top-left tip.
    static func drawDefaultPointer() -> CGImage {
        let size = CGSize(width: 240, height: 360)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // Core Graphics is bottom-left origin; define the arrow in top-left terms then flip.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        let path = CGMutablePath()
        // Arrow outline (top-left tip at origin).
        path.move(to: CGPoint(x: 12, y: 12))
        path.addLine(to: CGPoint(x: 12, y: 270))
        path.addLine(to: CGPoint(x: 78, y: 210))
        path.addLine(to: CGPoint(x: 120, y: 312))
        path.addLine(to: CGPoint(x: 162, y: 294))
        path.addLine(to: CGPoint(x: 120, y: 192))
        path.addLine(to: CGPoint(x: 204, y: 192))
        path.closeSubpath()

        ctx.addPath(path)
        ctx.setFillColorSpace(cs)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()

        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(14)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        return ctx.makeImage()!
    }
}
