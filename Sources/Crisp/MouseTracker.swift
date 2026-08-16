import Foundation
import AppKit
import CoreMedia

/// Logs global mouse clicks and samples the cursor position at ~60Hz while recording.
/// Positions are stored in master-video pixel coordinates (top-left origin).
/// Timestamps use the same host clock as ScreenCaptureKit sample buffers, so events
/// line up with video frames exactly.
final class MouseTracker {

    private var monitors: [Any] = []
    private var timer: Timer?

    /// Quartz-space bounds (top-left origin, points) of the captured area —
    /// a full display, a window's frame, or a region rect.
    private var captureBounds: CGRect = .zero
    private var scale: Double = 1
    /// Host seconds of the first video frame; nil until capture actually starts.
    private var sessionStart: Double?

    private(set) var events: [MouseEvent] = []
    private(set) var samples: [CursorSample] = []

    static var hostNow: Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    func start(originQuartz: CGPoint, sizePoints: CGSize, scale: Double) {
        self.captureBounds = CGRect(origin: originQuartz, size: sizePoints)
        self.scale = scale
        self.sessionStart = nil
        events = []
        samples = []

        let clickMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown]
        // Global monitor sees other apps; local monitor covers clicks on our own app.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clickMask, handler: { [weak self] event in
            self?.logClick(event)
        }) {
            monitors.append(global)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: clickMask) { [weak self] event in
            self?.logClick(event)
            return event
        } as Any)

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.sampleCursor()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Called once the capture engine writes its first frame.
    func markSessionStart(hostSeconds: Double) {
        sessionStart = hostSeconds
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Logging

    private func logClick(_ event: NSEvent) {
        guard let t = relativeNow() else { return }
        let kind: MouseEvent.Kind
        switch event.type {
        case .leftMouseDown: kind = .leftDown
        case .leftMouseUp: kind = .leftUp
        case .rightMouseDown: kind = .rightDown
        default: return
        }
        guard let p = currentCursorPixel() else { return }
        events.append(MouseEvent(t: t, kind: kind, x: p.x, y: p.y))
    }

    private func sampleCursor() {
        guard let t = relativeNow(), let p = currentCursorPixel() else { return }
        samples.append(CursorSample(t: t, x: p.x, y: p.y))
    }

    private func relativeNow() -> Double? {
        guard let sessionStart else { return nil }
        return Self.hostNow - sessionStart
    }

    /// Current cursor position in master-video pixels, or nil if outside the captured area.
    private func currentCursorPixel() -> (x: Double, y: Double)? {
        // CGEvent location is in Quartz global coordinates (top-left origin, y down),
        // the same space as CGDisplayBounds and SCWindow.frame — no Cocoa y-flip needed.
        guard let loc = CGEvent(source: nil)?.location else { return nil }
        let x = (loc.x - captureBounds.minX) * scale
        let y = (loc.y - captureBounds.minY) * scale
        guard x >= 0, y >= 0,
              x <= captureBounds.width * scale,
              y <= captureBounds.height * scale else { return nil }
        return (x, y)
    }
}
