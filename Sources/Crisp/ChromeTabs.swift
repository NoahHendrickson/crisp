import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit

/// One open tab in Google Chrome, as reported over Apple Events.
struct ChromeTab: Identifiable, Hashable {
    /// Chrome's own per-window id (stable while the window lives; NOT a CGWindowID).
    let windowID: Int
    /// 1 = frontmost Chrome window.
    let windowIndex: Int
    /// 1-based position within its window at listing time.
    let tabIndex: Int
    /// Whether this tab was the window's visible tab at listing time.
    let isActive: Bool
    let tabID: Int
    let title: String
    let url: String
    /// Window frame in Quartz-global points (top-left origin), same space as `SCWindow.frame`.
    let windowBounds: CGRect
    let windowMinimized: Bool

    var id: String { "\(windowID)-\(tabID)" }

    var displayTitle: String {
        title.isEmpty ? (host ?? "Untitled tab") : title
    }

    var host: String? {
        guard let url = URL(string: url), let host = url.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

enum ChromeBridgeError: LocalizedError {
    case notRunning
    case notPermitted
    case timedOut
    case tabClosed
    case windowNotFound
    case script(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Google Chrome isn't running."
        case .notPermitted:
            return "Crisp isn't allowed to control Google Chrome. Allow it under Privacy & Security → Automation."
        case .timedOut: return "Google Chrome didn't respond in time."
        case .tabClosed: return "That Chrome tab is no longer open."
        case .windowNotFound: return "Couldn't find that Chrome window on screen."
        case .script(let message): return message
        }
    }
}

/// Talks to Google Chrome over Apple Events (AppleScript). Requires the
/// `com.apple.security.automation.apple-events` entitlement under hardened
/// runtime and `NSAppleEventsUsageDescription` in Info.plist; macOS asks the
/// user once ("Crisp wants to control Google Chrome") on first use.
///
/// ScreenCaptureKit records windows, not tabs, so "recording a tab" means:
/// make it the active tab of its window, then capture that Chrome window.
enum ChromeBridge {
    static let bundleID = "com.google.Chrome"

    /// Separators the listing script uses (never appear in titles/URLs).
    private static let recordSeparator = "\u{1E}"
    private static let fieldSeparator = "\u{1F}"

    private static let queue = DispatchQueue(label: "crisp.chrome-bridge", qos: .userInitiated)

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static let automationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    )!

    // MARK: - Listing

    /// Every tab of every Chrome window, front-to-back, tabs in bar order.
    ///
    /// The generous timeout leaves room for the user to answer the one-time
    /// Automation consent prompt, which blocks the event until they do.
    static func listTabs() async throws -> [ChromeTab] {
        guard isRunning else { throw ChromeBridgeError.notRunning }
        let script = """
        with timeout of 45 seconds
        tell application id "\(bundleID)"
            set rs to character id 30
            set fs to character id 31
            set out to {}
            set wi to 0
            repeat with w in windows
                set wi to wi + 1
                set b to bounds of w
                set ai to active tab index of w
                set wid to id of w
                set mini to minimized of w
                set tabIDs to id of tabs of w
                set tabURLs to URL of tabs of w
                set tabTitles to title of tabs of w
                repeat with ti from 1 to count of tabIDs
                    set end of out to (wi as text) & fs & (wid as text) & fs & (ti as text) & fs & (ai as text) & fs & ((item 1 of b) as text) & fs & ((item 2 of b) as text) & fs & ((item 3 of b) as text) & fs & ((item 4 of b) as text) & fs & (mini as text) & fs & ((item ti of tabIDs) as text) & fs & ((item ti of tabURLs) as text) & fs & ((item ti of tabTitles) as text)
                end repeat
            end repeat
            set AppleScript's text item delimiters to rs
            return out as text
        end tell
        end timeout
        """
        let raw = try await run(script)
        return raw.components(separatedBy: recordSeparator).compactMap(parseTab)
    }

    private static func parseTab(_ record: String) -> ChromeTab? {
        let f = record.components(separatedBy: fieldSeparator)
        // Fields, in script order: window index, window id, tab index, active
        // tab index, bounds ×4, minimized, tab id, URL, title (12 total).
        guard f.count >= 12,
              let windowIndex = Int(f[0]), let windowID = Int(f[1]),
              let tabIndex = Int(f[2]), let activeIndex = Int(f[3]),
              let left = Double(f[4]), let top = Double(f[5]),
              let right = Double(f[6]), let bottom = Double(f[7]),
              let tabID = Int(f[9])
        else { return nil }
        // Titles can't contain the separators, but be lenient: join anything
        // past the title field back rather than dropping the tab.
        let title = f[11...].joined(separator: fieldSeparator)
        return ChromeTab(
            windowID: windowID,
            windowIndex: windowIndex,
            tabIndex: tabIndex,
            isActive: tabIndex == activeIndex,
            tabID: tabID,
            title: title,
            url: f[10],
            windowBounds: CGRect(x: left, y: top, width: right - left, height: bottom - top),
            windowMinimized: f[8] == "true"
        )
    }

    // MARK: - Activation

    struct Activated {
        var title: String
        var bounds: CGRect
    }

    /// Make `tab` the visible tab of its window (un-minimizing if needed) and
    /// report the window's current title and bounds for matching.
    static func activate(_ tab: ChromeTab) async throws -> Activated {
        guard isRunning else { throw ChromeBridgeError.notRunning }
        let script = """
        with timeout of 15 seconds
        tell application id "\(bundleID)"
            set fs to character id 31
            set w to window id \(tab.windowID)
            set ids to id of tabs of w
            set found to 0
            -- Chrome reports tab ids as text; `is` does not coerce text ↔ integer.
            repeat with i from 1 to count of ids
                set tid to (item i of ids) as text
                if tid is "\(tab.tabID)" then
                    set found to i
                    exit repeat
                end if
            end repeat
            if found is 0 then error "tab closed" number -1728
            if minimized of w then set minimized of w to false
            set active tab index of w to found
            set b to bounds of w
            return (title of active tab of w) & fs & ((item 1 of b) as text) & fs & ((item 2 of b) as text) & fs & ((item 3 of b) as text) & fs & ((item 4 of b) as text)
        end tell
        end timeout
        """
        let raw = try await run(script)
        let f = raw.components(separatedBy: fieldSeparator)
        guard f.count >= 5,
              let left = Double(f[f.count - 4]), let top = Double(f[f.count - 3]),
              let right = Double(f[f.count - 2]), let bottom = Double(f[f.count - 1])
        else { throw ChromeBridgeError.script("Unexpected reply from Google Chrome.") }
        let title = f[0..<(f.count - 4)].joined(separator: fieldSeparator)
        return Activated(
            title: title,
            bounds: CGRect(x: left, y: top, width: right - left, height: bottom - top)
        )
    }

    // MARK: - Window matching

    /// Chrome's AppleScript windows and ScreenCaptureKit's `SCWindow`s share no
    /// id, so match on what both expose: the window title (Chrome titles its
    /// windows after the active tab) and the frame. Frames are the tiebreaker
    /// when several windows show tabs with the same title.
    static func matchWindow(title: String, bounds: CGRect, in windows: [SCWindow]) -> SCWindow? {
        let candidates = windows.filter {
            $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0
        }
        func score(_ window: SCWindow) -> Int {
            var s = 0
            if let wt = window.title, !wt.isEmpty, !title.isEmpty {
                if wt == title { s += 4 }
                else if wt.hasPrefix(title) || title.hasPrefix(wt) { s += 2 }
            }
            if framesMatch(window.frame, bounds) { s += 3 }
            return s
        }
        // `windows` is front-to-back, so ties resolve to the frontmost window.
        var best: (SCWindow, Int)?
        for window in candidates {
            let s = score(window)
            if s > 0, s > (best?.1 ?? 0) { best = (window, s) }
        }
        return best?.0
    }

    private static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    // MARK: - Script execution

    private static func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var errorInfo: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: ChromeBridgeError.script("Couldn't build the Chrome script."))
                    return
                }
                let result = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
                    let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(code)"
                    AppModel.log("chrome bridge error \(code): \(message)")
                    continuation.resume(throwing: mapError(code: code, message: message))
                    return
                }
                continuation.resume(returning: result.stringValue ?? "")
            }
        }
    }

    private static func mapError(code: Int, message: String) -> ChromeBridgeError {
        switch code {
        case -1743: return .notPermitted   // errAEEventNotPermitted
        case -1712: return .timedOut       // errAETimeout
        case -1728: return .tabClosed      // errAENoSuchObject (or our own "tab closed")
        case -600: return .notRunning      // procNotFound
        default: return .script(message)
        }
    }
}

// MARK: - Page area

/// Where a Chrome window shows its page. ScreenCaptureKit records whole
/// windows, so a "tab" recording crops to the active tab's web area, found in
/// Chrome's accessibility tree. That needs the Accessibility grant (a
/// separate one from Screen Recording and Automation); without it the whole
/// window, tab strip and toolbar included, is recorded.
extension ChromeBridge {
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    /// `prompt` shows the system's one-time "Crisp would like to control this
    /// computer using accessibility features" dialog.
    static func hasAccessibilityAccess(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Smallest page area worth cropping to; anything less means the probe
    /// hit a bubble or a collapsed pane rather than the page.
    private static let minimumPageSize = CGSize(width: 120, height: 90)

    /// The page area of `window`, local to its top-left corner in points, or
    /// nil when the whole window should be recorded: no Accessibility access,
    /// Chrome exposing no page there, or a page that already fills the window.
    static func pageCrop(in window: SCWindow) async -> CGRect? {
        guard hasAccessibilityAccess(), let pid = window.owningApplication?.processID else { return nil }
        let frame = window.frame
        return await withCheckedContinuation { continuation in
            queue.async {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 2)
                // Chrome builds its accessibility tree lazily; this Chrome-
                // specific attribute asks for it without a screen reader.
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                var crop: CGRect?
                for attempt in 0..<3 {
                    if attempt > 0 { Thread.sleep(forTimeInterval: 0.15) }
                    if let area = webAreaFrame(app: app, windowFrame: frame) {
                        crop = localCrop(of: area, in: frame)
                        break
                    }
                }
                continuation.resume(returning: crop)
            }
        }
    }

    /// Screen frame of the outermost AXWebArea under a point well inside the
    /// page (below the toolbar and any bookmarks bar). Iframes nest their own
    /// web areas, so keep climbing to the top and remember the last one.
    private static func webAreaFrame(app: AXUIElement, windowFrame: CGRect) -> CGRect? {
        let probe = CGPoint(x: windowFrame.midX, y: windowFrame.minY + windowFrame.height * 0.6)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(probe.x), Float(probe.y), &hit) == .success,
              var element = hit else { return nil }
        var outermost: CGRect?
        for _ in 0..<64 {
            if axString(element, kAXRoleAttribute) == "AXWebArea", let frame = axFrame(element) {
                outermost = frame
            }
            guard let parent = axElement(element, kAXParentAttribute) else { break }
            element = parent
        }
        return outermost
    }

    private static func localCrop(of area: CGRect, in frame: CGRect) -> CGRect? {
        let local = area.offsetBy(dx: -frame.minX, dy: -frame.minY)
            .intersection(CGRect(origin: .zero, size: frame.size))
            .integral
        guard local.width >= minimumPageSize.width, local.height >= minimumPageSize.height,
              local.width * local.height < frame.width * frame.height - 1 else { return nil }
        return local
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        axValue(element, attribute) as? String
    }

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = axValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Screen-space frame (points, top-left origin) of an element.
    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = axValue(element, kAXPositionAttribute),
              let size = axValue(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
