import AppKit

/// Full-screen drag-to-select overlay (like ⌘⇧4) for choosing a capture region.
/// Returns the rect in points, top-left origin, local to the chosen display.
@MainActor
final class RegionPicker {

    static let shared = RegionPicker()

    private var window: NSWindow?
    private var continuation: CheckedContinuation<CGRect?, Never>?

    func pick(displayID: CGDirectDisplayID) async -> CGRect? {
        guard window == nil,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
              }) else { return nil }

        return await withCheckedContinuation { cont in
            continuation = cont

            let overlay = KeyableWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.level = .screenSaver
            overlay.isReleasedWhenClosed = false
            overlay.hasShadow = false

            let view = RegionSelectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let viewHeight = screen.frame.height
            view.onDone = { [weak self] rect in
                self?.finish(rect, viewHeight: viewHeight)
            }
            overlay.contentView = view
            overlay.makeKeyAndOrderFront(nil)
            overlay.makeFirstResponder(view)
            NSApp.activate(ignoringOtherApps: true)
            window = overlay
        }
    }

    private func finish(_ viewRect: CGRect?, viewHeight: CGFloat) {
        window?.orderOut(nil)
        window = nil
        NSCursor.arrow.set()

        // View coords are bottom-left origin; convert to top-left-origin display-local.
        var result: CGRect?
        if let r = viewRect, r.width >= 40, r.height >= 40 {
            result = CGRect(x: r.minX, y: viewHeight - r.maxY, width: r.width, height: r.height)
        }
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class RegionSelectView: NSView {
    var onDone: ((CGRect?) -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    private var selectionRect: NSRect? {
        guard let a = startPoint, let b = currentPoint else { return nil }
        return NSRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y)
        )
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()

        if let rect = selectionRect {
            // Punch a clear hole where the selection is.
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1.5
            border.stroke()

            let label = String(format: "%.0f × %.0f", rect.width, rect.height)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attrs)
            let labelOrigin = NSPoint(x: rect.minX, y: max(4, rect.minY - size.height - 6))
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSRect(origin: labelOrigin, size: size).insetBy(dx: -4, dy: -2).fill()
            label.draw(at: labelOrigin, withAttributes: attrs)
        } else {
            let hint = "Drag to select a region — Esc to cancel"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = hint.size(withAttributes: attrs)
            hint.draw(
                at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                withAttributes: attrs
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        onDone?(selectionRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            onDone?(nil)
        }
    }
}
