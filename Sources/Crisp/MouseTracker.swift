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
    /// Master-video size in pixels; cursor positions are mapped proportionally
    /// into it so a window that is resized mid-recording still lines up.
    private var pixelSize: CGSize = .zero
    /// For window captures: the window to follow. Its bounds are re-read while
    /// recording so a moved or resized window keeps mapping correctly.
    private var windowID: CGWindowID?
    /// For cropped window captures: the crop's origin relative to the window.
    /// The crop keeps its size when the window is resized mid-recording.
    private var cropInset: CGPoint?
    private var ticksSinceBoundsRefresh = 0
    /// Host seconds of the first video frame; nil until capture actually starts.
    /// Deliberately not reset by `start()`: the engine may report it before or
    /// after the tracker starts, and a tracker is single-use anyway.
    private var sessionStart: Double?

    private(set) var events: [MouseEvent] = []
    private(set) var samples: [CursorSample] = []

    static var hostNow: Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    func start(
        originQuartz: CGPoint, sizePoints: CGSize, scale: Double,
        windowID: CGWindowID? = nil, cropInset: CGPoint? = nil
    ) {
        self.captureBounds = CGRect(origin: originQuartz, size: sizePoints)
        self.scale = scale
        self.pixelSize = CGSize(width: sizePoints.width * scale, height: sizePoints.height * scale)
        self.windowID = windowID
        self.cropInset = cropInset
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

    /// Safety net: `stop()` is the contract, but a dropped tracker must not
    /// leave global event monitors installed and the run-loop-retained timer
    /// firing for the rest of the app's life.
    deinit {
        stop()
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
        refreshWindowBoundsIfDue()
        guard let t = relativeNow(), let p = currentCursorPixel() else { return }
        let kind = Self.classify()
        samples.append(CursorSample(t: t, x: p.x, y: p.y, kind: kind == .arrow ? nil : kind))
    }

    // MARK: - Cursor kind

    /// Size + hotspot of the last classified system cursor. Cheap to read, and
    /// the three stock kinds we care about don't share a signature.
    private struct CursorSignature: Equatable {
        var size: CGSize
        var hotSpot: CGPoint
    }

    private static var stockTIFFs: [(Data, CursorKind)]?
    private static var lastSignature: CursorSignature?
    private static var lastKind: CursorKind = .arrow

    /// Arrow / pointing hand / I-beam from the live system cursor. Signature
    /// first (size + hotspot); TIFF of the smallest rep only when it changes.
    private static func classify() -> CursorKind {
        guard let cursor = NSCursor.currentSystem else { return .arrow }
        let signature = CursorSignature(size: cursor.image.size, hotSpot: cursor.hotSpot)
        if signature == lastSignature { return lastKind }
        lastSignature = signature
        lastKind = match(cursor)
        return lastKind
    }

    private static func match(_ cursor: NSCursor) -> CursorKind {
        ensureStockTIFFs()
        guard let tiff = smallestTIFF(cursor.image),
              let hit = stockTIFFs?.first(where: { $0.0 == tiff }) else { return .arrow }
        return hit.1
    }

    /// Stock cursor images are empty 0×0 in a process without an NSApplication
    /// connection (only pointingHand loads standalone). Compute on first use.
    private static func ensureStockTIFFs() {
        guard stockTIFFs == nil else { return }
        var pairs: [(Data, CursorKind)] = []
        if let d = smallestTIFF(NSCursor.arrow.image) { pairs.append((d, .arrow)) }
        if let d = smallestTIFF(NSCursor.pointingHand.image) { pairs.append((d, .pointer)) }
        if let d = smallestTIFF(NSCursor.iBeam.image) { pairs.append((d, .iBeam)) }
        stockTIFFs = pairs
    }

    private static func smallestTIFF(_ image: NSImage) -> Data? {
        guard image.size.width >= 1, image.size.height >= 1 else { return nil }
        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let smallest = bitmaps.min {
            pixelCount($0) < pixelCount($1)
        }
        guard let tiff = smallest?.tiffRepresentation ?? image.tiffRepresentation,
              !tiff.isEmpty else { return nil }
        return tiff
    }

    private static func pixelCount(_ rep: NSBitmapImageRep) -> Int {
        let w = rep.pixelsWide > 0 ? rep.pixelsWide : Int(rep.size.width)
        let h = rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(rep.size.height)
        return max(0, w) * max(0, h)
    }

    /// Window captures follow the window wherever it goes; re-read its frame a
    /// few times a second so the cursor mapping follows too.
    private func refreshWindowBoundsIfDue() {
        guard let windowID else { return }
        ticksSinceBoundsRefresh += 1
        guard ticksSinceBoundsRefresh >= 10 else { return }
        ticksSinceBoundsRefresh = 0
        guard let bounds = Self.currentBounds(of: windowID), bounds.width > 0, bounds.height > 0 else { return }
        if let cropInset {
            captureBounds.origin = CGPoint(x: bounds.minX + cropInset.x, y: bounds.minY + cropInset.y)
        } else {
            captureBounds = bounds
        }
    }

    /// Quartz-global bounds (points, top-left origin) of a window, or nil if it
    /// has gone away.
    private static func currentBounds(of windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let dict = list.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict) else { return nil }
        return rect
    }

    private func relativeNow() -> Double? {
        guard let sessionStart else { return nil }
        return Self.hostNow - sessionStart
    }

    /// Current cursor position in master-video pixels, or nil if outside the captured area.
    private func currentCursorPixel() -> (x: Double, y: Double)? {
        // CGEvent location is in Quartz global coordinates (top-left origin, y down),
        // the same space as CGDisplayBounds and SCWindow.frame — no Cocoa y-flip needed.
        guard let loc = CGEvent(source: nil)?.location,
              captureBounds.width > 0, captureBounds.height > 0 else { return nil }
        let x = (loc.x - captureBounds.minX) / captureBounds.width * pixelSize.width
        let y = (loc.y - captureBounds.minY) / captureBounds.height * pixelSize.height
        guard x >= 0, y >= 0, x <= pixelSize.width, y <= pixelSize.height else { return nil }
        return (Double(x), Double(y))
    }
}
