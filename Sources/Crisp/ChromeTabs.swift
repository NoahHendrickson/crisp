import Foundation
import AppKit
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
            repeat with i from 1 to count of ids
                if item i of ids is \(tab.tabID) then
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
