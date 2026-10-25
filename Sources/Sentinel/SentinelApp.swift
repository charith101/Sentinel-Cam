import AppKit
import SwiftUI

/// Sentinel Cam's main window is a plain SwiftUI `Window` scene, exactly the
/// pattern AndroidFileSync uses. The OS owns the window chrome from here on:
/// traffic lights, drag-resize edges, zoom, and clamping to the display all
/// come from the system and cannot drift — the earlier AppKit `NSWindow`
/// hosting is what produced the missing title bar and unreachable edges.
@main
struct SentinelApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    Window("Sentinel Cam", id: "main") {
      MainView(model: appDelegate.model)
    }
    .defaultSize(width: 1000, height: 680)
    .windowStyle(.hiddenTitleBar)
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Settings…") { appDelegate.openSettings() }
          .keyboardShortcut(",")
      }
      CommandGroup(replacing: .newItem) {
        Button("All Cameras") { appDelegate.showAllCameras() }
          .keyboardShortcut("1")
      }
    }
  }
}
