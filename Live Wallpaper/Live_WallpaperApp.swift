import SwiftUI

@main
struct LiveWallpaperApp: App {
    @StateObject private var manager = WallpaperManager()
    @Environment(\.openWindow) var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu Bar Icon
        MenuBarExtra("Live Wallpaper", systemImage: "display") {
            Button("Control Panel") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }

        // Settings Window (Hidden by default)
        Window("Control Panel", id: "settings") {
            ControlPanelView()
                .environmentObject(manager)
                .frame(minWidth: 600, minHeight: 400)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 600, height: 500)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock safely after launch
        NSApp.setActivationPolicy(.accessory)
    }
}
