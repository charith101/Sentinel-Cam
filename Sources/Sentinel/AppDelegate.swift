import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let store: ConfigStore
  let model: GridModel
  private var statusController: StatusItemController!
  private var toastPresenter: ToastPresenter?
  private let showWindowOnLaunch: Bool

  override init() {
    if CommandLine.arguments.contains("--selftest") {
      Self.runSelfTest()
      print("selftest ok")
      exit(0)
    }
    let store = ConfigStore()
    self.store = store
    model = GridModel(store: store)
    showWindowOnLaunch = CommandLine.arguments.contains("--window")
    super.init()
  }

  /// Pure, hardware-free checks for the parts that are easy to get subtly
  /// wrong: URL building, presets, pasted URLs, migration, and normalization.
  private static func runSelfTest() {
    let camera = CameraConfig(id: 1, name: "Front", channel: 1, quality: .main)
    let dahua = DeviceConfig(
      id: 1, name: "DVR", host: "192.168.1.100", port: 554, username: "admin",
      transport: .tcp, brand: .dahua,
      mainPath: "/cam/realmonitor?channel={channel}&subtype=0",
      subPath: "/cam/realmonitor?channel={channel}&subtype=1", cameras: [camera])

    precondition(
      dahua.url(for: camera)
        == "rtsp://192.168.1.100:554/cam/realmonitor?channel=1&subtype=0")
    var subCamera = camera
    subCamera.quality = .sub
    precondition(
      dahua.url(for: subCamera)
        == "rtsp://192.168.1.100:554/cam/realmonitor?channel=1&subtype=1")

    var channel3 = camera
    channel3.channel = 3
    let hikvision = DeviceConfig(
      id: 2, name: "NVR", host: "10.0.0.5",
      mainPath: "/Streaming/Channels/{channel}01", subPath: "/Streaming/Channels/{channel}02")
    precondition(hikvision.url(for: channel3).hasSuffix("/Streaming/Channels/301"))
    var channel3Sub = channel3
    channel3Sub.quality = .sub
    precondition(hikvision.url(for: channel3Sub).hasSuffix("/Streaming/Channels/302"))

    let reolink = DeviceConfig(
      id: 3, name: "Reolink", host: "10.0.0.6",
      mainPath: "/Preview_{channel:02}_main", subPath: "/Preview_{channel:02}_sub")
    precondition(reolink.url(for: camera).hasSuffix("/Preview_01_main"))

    let ipv6 = DeviceConfig(id: 4, name: "v6", host: "fe80::1", mainPath: "/stream1")
    precondition(ipv6.url(for: camera) == "rtsp://[fe80::1]:554/stream1")

    // No sub path: sub quality falls back to main instead of an empty URL.
    let noSub = DeviceConfig(id: 5, name: "Tapo", host: "10.0.0.7", mainPath: "/stream1")
    precondition(noSub.url(for: subCamera).hasSuffix("/stream1"))

    // Pasted URL parsing.
    let pasted =
      "rtsp://user:p%40ss@192.168.1.50:8554/cam/realmonitor?channel=1&subtype=0"
    switch RTSPURLParser.parse(pasted) {
    case .success(let parsed):
      precondition(parsed.host == "192.168.1.50")
      precondition(parsed.port == 8554)
      precondition(parsed.username == "user")
      precondition(parsed.password == "p@ss")
      precondition(parsed.path == "/cam/realmonitor?channel=1&subtype=0")
    case .failure(let message):
      preconditionFailure("URL parser rejected a valid URL: \(message)")
    }
    if case .success = RTSPURLParser.parse("rtsps://camera.local/stream") {
      preconditionFailure("URL parser accepted rtsps, which IPCamKit cannot play")
    }
    switch RTSPURLParser.parse("rtsp://[fe80::1]:554/live") {
    case .success(let parsed):
      precondition(parsed.host == "fe80::1")
      precondition(parsed.port == 554)
    case .failure(let message):
      preconditionFailure("IPv6 parse failed: \(message)")
    }
    // A malformed port and an unbracketed IPv6 host must be rejected, not
    // silently folded into the hostname.
    if case .success = RTSPURLParser.parse("rtsp://camera.local:abc/stream") {
      preconditionFailure("URL parser accepted a non-numeric port")
    }
    if case .success = RTSPURLParser.parse("rtsp://fe80::1/live") {
      preconditionFailure("URL parser accepted an unbracketed IPv6 host")
    }

    // v1 migration.
    let legacy = """
      {
        "host": "192.168.1.100",
        "port": 554,
        "username": "admin",
        "pathTemplate": "/cam/realmonitor?channel={channel}&subtype=0",
        "channels": [
          {"id": 1, "name": "Driveway", "enabled": true},
          {"id": 2, "name": "Back", "enabled": false}
        ],
        "menuChannel": 2,
        "transport": "tcp",
        "appearance": "dark",
        "menuBarSize": "large",
        "gridDensity": "twoByTwo",
        "openWindowOnLaunch": false,
        "popoverHotkey": true
      }
      """
    guard
      let migrated = try? JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
    else {
      preconditionFailure("Legacy config did not decode")
    }
    precondition(migrated.devices.count == 1)
    precondition(migrated.devices[0].cameras.count == 2)
    precondition(migrated.devices[0].cameras[0].name == "Driveway")
    precondition(migrated.devices[0].cameras[0].scale == .stretch)
    precondition(migrated.devices[0].cameras[0].quality == .main)
    precondition(migrated.devices[0].subPath.contains("subtype=1"))
    precondition(migrated.appearance == .dark)
    precondition(migrated.menuBarSize == .large)
    // Channel 2 was disabled, so the menu falls back to the first enabled one.
    precondition(migrated.menuCameraID == 1)
    precondition(
      migrated.devices[0].url(for: migrated.devices[0].cameras[0])
        == "rtsp://192.168.1.100:554/cam/realmonitor?channel=1&subtype=0")

    // v2 round-trip.
    if let data = try? JSONEncoder().encode(migrated),
      let decoded = try? JSONDecoder().decode(AppConfig.self, from: data)
    {
      precondition(decoded.devices == migrated.devices)
      precondition(decoded.menuCameraID == migrated.menuCameraID)
    } else {
      preconditionFailure("v2 round-trip failed")
    }

    // Duplicate IDs are repaired, and empty devices are dropped.
    var duplicate = AppConfig()
    duplicate.devices = [dahua, dahua]
    let cleaned = duplicate.normalized()
    precondition(cleaned.devices.count == 2)
    precondition(Set(cleaned.devices.map(\.id)).count == 2)
    precondition(Set(cleaned.allCameras.map(\.id)).count == 2)
    var empty = AppConfig()
    empty.devices = [DeviceConfig(id: 1, name: "Broken", host: "", mainPath: "/")]
    precondition(empty.normalized().devices.isEmpty)

    // Every non-generic brand has a main path and a sane port.
    for brand in CameraBrand.allCases where brand != .generic {
      precondition(!brand.paths(recorder: true).main.isEmpty)
      precondition((1...65_535).contains(brand.defaultPort))
    }
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    // Never two copies: racing instances fight over the window restoration
    // state and the status item (that race is what crashed my test launches).
    if let bundleID = Bundle.main.bundleIdentifier {
      let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
      if others.first != nil {
        exit(0)
      }
    }
    // Menu-bar first: the Dock icon appears only while the window is open.
    NSApp.setActivationPolicy(.accessory)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.appearance = store.config.appearance.nsAppearance
    hideSceneWindowUntilRequested()

    // Create the single toast host before anything can post a message to it.
    toastPresenter = ToastPresenter(queue: store.toasts)

    statusController = StatusItemController(
      store: store,
      openWindow: { [weak self] in self?.showAllCameras() },
      openCamera: { [weak self] cameraID in self?.showCamera(cameraID) },
      openSettings: { [weak self] in self?.openSettings() },
      openSetup: { [weak self] in self?.showSetup() })

    if !store.isConfigured {
      // First run: walk the user through the handshake test before any stream
      // starts. Cancelling leaves the normal Settings page available.
      showSetup()
    } else if showWindowOnLaunch || store.config.openWindowOnLaunch {
      showAllCameras()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    showAllCameras()
    return true
  }

  // MARK: Opening the window

  func showAllCameras() {
    openMain()
    model.gridTick += 1
  }

  /// Opens the window directly on one camera (clicked in the menu bar preview).
  func showCamera(_ cameraID: Int) {
    openMain()
    model.requestedCamera = cameraID
  }

  func openSettings() {
    openMain()
    model.settingsTick += 1
  }

  /// Opens the first-run/setup sheet over the main window. The flag is
  /// consumed by MainView, so it also works when the window is still being
  /// created during launch.
  func showSetup() {
    openMain()
    model.wantsSetup = true
  }

  private func openMain() {
    guard let window = sceneWindow() else { return }
    attachDelegate()
    model.windowVisible = true
    model.resyncTick += 1
    // Behave like a normal app while a window is open: Dock icon + our menus.
    NSApp.setActivationPolicy(.regular)
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
    Self.clampFrameToWorkArea(window)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// The Window scene creates its window at launch, but a menu-bar app must not
  /// show it until asked — hide it now; every later open just orders it back in.
  private func hideSceneWindowUntilRequested() {
    attachDelegate()
    sceneWindow()?.orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
    // The scene may order its window in right after this callback; try once
    // more on the next runloop turn so no window flashes at startup.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.model.windowVisible == false else { return }
      self.sceneWindow()?.orderOut(nil)
    }
  }

  /// Sentinel Cam's one real window (the popover's and status bar's windows are
  /// excluded by title).
  private func sceneWindow() -> NSWindow? {
    NSApp.windows.first { $0.title == "Sentinel Cam" }
  }

  private func attachDelegate() {
    guard let window = sceneWindow() else { return }
    window.delegate = self
  }

  /// A frame saved for another screen (or by an older build) can sit under the
  /// Dock or half off-screen, which makes the resize edges impossible to grab.
  /// Pull it back into the current work area.
  private static func clampFrameToWorkArea(_ window: NSWindow) {
    guard let screen = window.screen ?? NSScreen.main else { return }
    let visible = screen.visibleFrame
    var frame = window.frame
    let minSize = NSSize(width: 700, height: 500)
    frame.size.width = min(max(frame.size.width, minSize.width), visible.size.width)
    frame.size.height = min(max(frame.size.height, minSize.height), visible.size.height - 30)
    frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.size.width))
    frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.size.height))
    if frame != window.frame {
      window.setFrame(frame, display: true)
    }
  }

  // MARK: NSWindowDelegate — the window hides instead of closing

  /// Closing hides the window and keeps it alive, so every reopen path (Dock
  /// click, ⌘1, popover) is just an order-front on the same window.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hideMainWindow(sender)
    return false
  }

  func windowWillClose(_ notification: Notification) {
    model.windowVisible = false
    NSApp.setActivationPolicy(.accessory)
  }

  private func hideMainWindow(_ window: NSWindow) {
    window.orderOut(nil)
    model.windowVisible = false
    NSApp.setActivationPolicy(.accessory)
  }

  func windowDidMiniaturize(_ notification: Notification) {
    model.windowVisible = false
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    model.windowVisible = true
  }

  /// Streams only decode while the window is actually on screen (also covers ⌘H
  /// and full-screen Spaces), so an idle Sentinel costs nothing.
  func windowDidChangeOcclusionState(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === sceneWindow(),
      !window.isMiniaturized
    else { return }
    model.windowVisible = window.occlusionState.contains(.visible)
  }
}
