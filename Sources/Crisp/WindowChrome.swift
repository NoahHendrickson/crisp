import SwiftUI
import AppKit

/// Light/dark appearance ownership and per-window titlebar chrome.
enum AppAppearance: String {
    case light, dark

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }

    var nsAppearance: NSAppearance {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)!
    }

    var other: AppAppearance { self == .dark ? .light : .dark }

    // Persistence and the AppKit/SwiftUI apply are owned by `AppearanceGate`;
    // everything else only flips the stored value.
    static let storageKey = "appearance"

    static var stored: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .dark
    }

    static func toggle() {
        UserDefaults.standard.set(stored.other.rawValue, forKey: storageKey)
    }
}

// MARK: - Window chrome

/// Paints the titlebar with the theme background so the window reads as one
/// surface, like the Figma frame.
///
/// Applied once, when the view lands in its window. The background is a
/// dynamic NSColor and the window inherits `NSApp.appearance`, so light/dark
/// switches need no re-apply here.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = Theme.backgroundNSColor
        }
    }
}

/// The single owner of the light/dark setting: observes the persisted value
/// and applies it to SwiftUI (`preferredColorScheme`) and AppKit
/// (`NSApp.appearance`). Views change it via `AppAppearance.toggle()`.
struct AppearanceGate: ViewModifier {
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.dark.rawValue

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .dark
    }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(appearance.colorScheme)
            .onAppear { NSApp.appearance = appearance.nsAppearance }
            .onChange(of: appearanceRaw) { _, _ in
                NSApp.appearance = appearance.nsAppearance
            }
    }
}

extension View {
    func themedAppearance() -> some View {
        modifier(AppearanceGate())
    }
}
