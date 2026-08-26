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
/// surface, like the Figma frame. The main window also uses
/// `.windowStyle(.hiddenTitleBar)` and draws its own titlebar strip
/// (`TitlebarStrip`), because on macOS 26 the system titlebar paints a glass
/// material over `titlebarAppearsTransparent` windows.
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
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = Theme.backgroundNSColor
        }
    }
}

/// The 33pt titlebar strip of a hidden-title-bar window (Figma 68:11636):
/// a 16pt row inside 8pt padding — the title at 12pt medium, 16pt after the
/// 52pt traffic-light cluster — over a 1pt `--border` divider. Place at the
/// top of the root stack.
struct TitlebarStrip: View {
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(Theme.font(.label12))
                .foregroundStyle(Theme.foreground)
                .padding(.leading, 76)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 32)
            Rectangle().fill(Theme.border).frame(height: 1)
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
