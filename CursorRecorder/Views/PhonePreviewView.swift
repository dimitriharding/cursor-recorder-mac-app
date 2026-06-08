import SwiftUI
import AppKit
import QuartzCore

/// SwiftUI wrapper around an NSView that hosts the phone preview, tracks the Mac pointer,
/// and draws the live cursor overlay. Pointer motion is normalized to phone-video
/// coordinates and forwarded to the coordinator.
struct PhonePreviewView: NSViewRepresentable {
    @ObservedObject var coordinator: RecordingCoordinator

    func makeNSView(context: Context) -> GPRPreviewNSView {
        let view = GPRPreviewNSView()
        view.coordinator = coordinator
        return view
    }

    func updateNSView(_ nsView: GPRPreviewNSView, context: Context) {
        nsView.coordinator = coordinator
        nsView.aspectRatio = coordinator.effectiveAspectRatio
        nsView.hasLiveLayer = coordinator.selectedDevice?.platform == .iphone
        nsView.attachPreviewLayer(coordinator.previewLayer)
        nsView.cursorConfig = coordinator.cursorConfig
        nsView.tracksLocalMouse = !coordinator.usesGlobalCursor
        nsView.platformLabel = Self.placeholderLabel(for: coordinator)
        nsView.refresh()
    }

    private static func placeholderLabel(for coordinator: RecordingCoordinator) -> String {
        guard let device = coordinator.selectedDevice else { return "No phone connected" }
        if device.backend == .mirroring {
            return "\(device.name)\nControl the phone in the iPhone Mirroring window —\nyour cursor renders here and in the recording."
        }
        if device.platform == .android {
            return "\(device.name)\nLive view appears in the scrcpy window.\nMove the pointer here to place the cursor."
        }
        return device.name
    }
}

/// The backing NSView. Non-flipped (bottom-left origin) to keep CALayer math simple.
final class GPRPreviewNSView: NSView {

    weak var coordinator: RecordingCoordinator?
    var aspectRatio: CGFloat = 9.0 / 19.5
    var hasLiveLayer = false
    /// When false (iPhone Mirroring), the cursor is driven by the global tracker instead of
    /// this view's local mouse events.
    var tracksLocalMouse = true
    var cursorConfig: CursorOverlayConfig = .default {
        didSet { if cursorConfig.imageURL != oldValue.imageURL { cursorCGImage = nil } }
    }
    var platformLabel: String = ""

    private var attachedPreviewLayer: CALayer?
    private let contentLayer = CALayer()
    private let cursorLayer = CALayer()
    private let placeholderText = CATextLayer()
    private var cursorCGImage: CGImage?
    private var trackingAreaRef: NSTrackingArea?
    private var cursorRenderTimer: Timer?

    private let baseHeightFraction: CGFloat = 0.06

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        contentLayer.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        contentLayer.cornerRadius = 6
        contentLayer.masksToBounds = true
        layer?.addSublayer(contentLayer)

        placeholderText.alignmentMode = .center
        placeholderText.foregroundColor = NSColor(white: 0.6, alpha: 1).cgColor
        placeholderText.fontSize = 13
        placeholderText.contentsScale = 2
        placeholderText.isWrapped = true
        contentLayer.addSublayer(placeholderText)

        cursorLayer.isHidden = true
        cursorLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(cursorLayer)

        // Render the cursor overlay from the shared live position (driven by either local
        // mouse tracking or the global iPhone Mirroring tracker).
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.renderLiveCursor()
        }
        RunLoop.main.add(t, forMode: .common)
        cursorRenderTimer = t
    }

    deinit { cursorRenderTimer?.invalidate() }

    private func renderLiveCursor() {
        guard let coordinator else { cursorLayer.isHidden = true; return }
        let live = coordinator.liveCursor.current
        guard live.visible else { cursorLayer.isHidden = true; return }
        // Map normalized (top-left) into this view's (bottom-left) content rect.
        let rect = contentRect()
        let vx = rect.minX + live.point.x * rect.width
        let vy = rect.minY + (rect.height - live.point.y * rect.height)
        positionCursorLayer(at: CGPoint(x: vx, y: vy), visible: true)
    }

    override var isFlipped: Bool { false }

    func attachPreviewLayer(_ previewLayer: CALayer?) {
        guard attachedPreviewLayer !== previewLayer else { return }
        attachedPreviewLayer?.removeFromSuperlayer()
        attachedPreviewLayer = previewLayer
        if let previewLayer {
            previewLayer.removeFromSuperlayer()
            contentLayer.addSublayer(previewLayer)
        }
    }

    func refresh() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let rect = contentRect()
        contentLayer.frame = rect
        attachedPreviewLayer?.frame = contentLayer.bounds
        attachedPreviewLayer?.isHidden = !hasLiveLayer

        placeholderText.isHidden = hasLiveLayer
        placeholderText.string = platformLabel
        placeholderText.frame = CGRect(
            x: 8, y: rect.height / 2 - 30, width: rect.width - 16, height: 60
        )

        CATransaction.commit()
        updateTrackingAreas()
    }

    /// The aspect-fit rectangle for the phone video inside the view bounds.
    private func contentRect() -> CGRect {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return b }
        let viewAR = b.width / b.height
        var w = b.width, h = b.height
        if viewAR > aspectRatio {
            h = b.height
            w = h * aspectRatio
        } else {
            w = b.width
            h = w / aspectRatio
        }
        return CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
    }

    // MARK: - Mouse tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) { handlePointer(event, interaction: .move) }
    override func mouseDragged(with event: NSEvent) { handlePointer(event, interaction: .move) }
    override func mouseDown(with event: NSEvent) { handlePointer(event, interaction: .click) }
    override func mouseUp(with event: NSEvent) { handlePointer(event, interaction: .mouseUp) }
    override func mouseExited(with event: NSEvent) {
        guard tracksLocalMouse else { return }
        let p = normalizedPoint(for: event)
        coordinator?.updateCursor(normalizedPoint: p.point, visible: false, interaction: .move)
    }

    private func handlePointer(_ event: NSEvent, interaction: CursorInteraction) {
        guard tracksLocalMouse else { return }   // Mirroring uses the global tracker.
        let result = normalizedPoint(for: event)
        coordinator?.updateCursor(
            normalizedPoint: result.point, visible: result.visible, interaction: interaction
        )
        // The render timer positions the cursor layer from the shared live position.
    }

    /// Converts an event to normalized top-left phone coordinates plus the raw view point.
    private func normalizedPoint(for event: NSEvent) -> (point: CGPoint, visible: Bool, viewPoint: CGPoint) {
        let p = convert(event.locationInWindow, from: nil)
        let rect = contentRect()
        guard rect.width > 0, rect.height > 0 else { return (CGPoint(x: 0.5, y: 0.5), false, p) }
        let nx = (p.x - rect.minX) / rect.width
        let nyBottom = (p.y - rect.minY) / rect.height
        let visible = (0...1).contains(nx) && (0...1).contains(nyBottom)
        let clampedX = min(1, max(0, nx))
        let clampedYBottom = min(1, max(0, nyBottom))
        // Convert to top-left origin for phone-video coordinates.
        let topLeft = CGPoint(x: clampedX, y: 1 - clampedYBottom)
        return (topLeft, visible, p)
    }

    // MARK: - Live cursor overlay

    private func positionCursorLayer(at viewPoint: CGPoint, visible: Bool) {
        guard visible, cursorConfig.opacity > 0 else { cursorLayer.isHidden = true; return }

        if cursorCGImage == nil {
            cursorCGImage = CursorRenderer.cgImage(for: cursorConfig.imageURL)
        }
        guard let image = cursorCGImage else { cursorLayer.isHidden = true; return }

        let rect = contentRect()
        let imgAspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        let ch = rect.height * baseHeightFraction * max(0.1, cursorConfig.scale)
        let cw = ch * imgAspect

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.contents = image
        cursorLayer.opacity = Float(cursorConfig.opacity)
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: cw, height: ch)
        // Anchor at the hotspot (config hotspot is top-left fractional; layer anchor is
        // bottom-left fractional, so flip y).
        cursorLayer.anchorPoint = CGPoint(x: cursorConfig.hotspot.x, y: 1 - cursorConfig.hotspot.y)
        cursorLayer.position = viewPoint
        if cursorConfig.shadowEnabled {
            cursorLayer.shadowColor = NSColor.black.cgColor
            cursorLayer.shadowOpacity = 0.5
            cursorLayer.shadowRadius = 3
            cursorLayer.shadowOffset = CGSize(width: 1, height: -1)
        } else {
            cursorLayer.shadowOpacity = 0
        }
        cursorLayer.isHidden = false
        CATransaction.commit()
    }
}
