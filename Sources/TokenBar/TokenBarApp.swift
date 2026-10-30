import SwiftUI
import TokenBarLib

@main
struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // SwiftUI App needs a scene. The real settings UI is an AppKit window
        // owned by AppDelegate. This scene stays empty so it can own the
        // Settings menu slot; AppDelegate refuses to present it.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appDelegate.openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
