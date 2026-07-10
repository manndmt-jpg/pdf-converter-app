import SwiftUI
import AppKit
import Sparkle

@main
struct PDFConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var queue = ConversionQueue.shared

    // Constructed in init: Sparkle reads its UserDefaults keys at updater creation
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(queue)
        }
        .defaultSize(width: 440, height: 560)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // First-launch convenience: import API key from shell env if Keychain is empty
        // (works when the binary is started from a terminal).
        if Keychain.readAPIKey() == nil,
           let envKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"],
           !envKey.isEmpty {
            Keychain.saveAPIKey(envKey)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // Finder "Open With" and Dock-icon drops land here.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            ConversionQueue.shared.add(urls: urls)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if ConversionQueue.shared.isBusy {
            let alert = NSAlert()
            alert.messageText = "Conversion in progress"
            alert.informativeText = "A PDF is still being converted. Quit anyway and lose the queue?"
            alert.addButton(withTitle: "Keep Converting")
            alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn {
                return .terminateCancel
            }
        }
        return .terminateNow
    }
}
