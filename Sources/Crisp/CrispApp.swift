import SwiftUI
import AppKit

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runBlocking()
            return
        }
        CrispApp.main()
    }
}

/// Finishes an in-flight recording before the app quits (⌘Q, "Quit & Reopen"
/// from System Settings, etc.) — otherwise the master file is left without its
/// moov atom and is unplayable.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.isRecording else { return .terminateNow }
        AppModel.log("terminate requested while recording — finalizing first")
        Task { @MainActor in
            await model.stopRecording()
            AppModel.log("recording finalized, terminating")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct CrispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    init() {
        Theme.registerFonts()
        // When run as a bare executable (swift run), behave like a regular app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        Window("Crisp", id: "main") {
            ContentView()
                .environmentObject(model)
                .themedAppearance()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        WindowGroup("Crisp zoom editor", for: URL.self) { $folder in
            if let folder {
                EditorView(folder: folder)
                    .environmentObject(model)
                    .themedAppearance()
            }
        }
    }
}
