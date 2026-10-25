import AppKit
import IPCamKit
import SwiftUI

@MainActor
extension Appearance {
  var nsAppearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }

  func applyToApp() {
    NSApp.appearance = nsAppearance
  }
}

/// The popover's live state: which feed is on screen right now. The content
/// controller observes this, so a camera switch is just a SwiftUI update —
/// never a new contentViewController.
@MainActor
@Observable
final class PopoverModel {
  var feed: CameraFeed?
}

/// What the menu bar icon's badge and menu say about the recorder.
enum CameraHealth: Equatable {
  case unknown
  case checking
  case healthy
  case unhealthy

  var menuLabel: String {
    switch self {
    case .unknown: "Camera status unknown"
    case .checking: "Checking cameras…"
    case .healthy: "Cameras online"
    case .unhealthy: "Cameras offline"
    }
  }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let popover = NSPopover()
  private let store: ConfigStore
  private let model = PopoverModel()
  private let openWindow: () -> Void
  private let openCamera: (Int) -> Void
  private let openSettings: () -> Void
  private let openSetup: () -> Void
  private var feed: CameraFeed?
  private var monitors: [Any] = []
  private var healthMonitor: Task<Void, Never>?
  private var health: CameraHealth = .unknown
  private var consecutiveHealthFailures = 0
  private var lastProbedCamera: Int?
  private var hotKeyID: UInt32?
  private let offlineBadge = OfflineBadgeView()

  init(
    store: ConfigStore, openWindow: @escaping () -> Void, openCamera: @escaping (Int) -> Void,
    openSettings: @escaping () -> Void, openSetup: @escaping () -> Void
  ) {
    self.store = store
    self.openWindow = openWindow
    self.openCamera = openCamera
    self.openSettings = openSettings
    self.openSetup = openSetup
    super.init()

    let image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Sentinel Cam")
    image?.isTemplate = true
    statusItem.button?.image = image
    statusItem.button?.target = self
    statusItem.button?.action = #selector(statusItemClicked(_:))
    // A status item's button only sends its action for the left mouse button
    // by default; without this line the right-click menu never appears.
    _ = statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    installOfflineBadge()

    // Click-away is handled explicitly below (see installClickMonitors).
    // `.transient` also closes whenever the accessory app loses key status,
    // which made the preview vanish on its own while the pointer was still on
    // it. Application-defined keeps it up until a real outside click or toggle.
    popover.behavior = .applicationDefined
    popover.animates = false
    popover.delegate = self
    installContent()

    startHealthMonitor()
    installClickMonitors()
    observeSettings()
    applyHotkeySetting(announceFailure: false)
    updateToolTip()
  }

  // MARK: Status item

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    let secondary =
      event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
    if secondary {
      showContextMenu(sender)
    } else if popover.isShown {
      popover.performClose(nil)
    } else {
      open()
    }
  }

  /// The standard status-item menu trick: temporarily attach the menu, let the
  /// button show it, then restore the button's custom action. The menu tracks
  /// modally, so the reset happens after the user makes a choice or dismisses.
  private func showContextMenu(_ button: NSStatusBarButton) {
    let menu = NSMenu()
    menu.autoenablesItems = false

    let status = NSMenuItem(title: health.menuLabel, action: nil, keyEquivalent: "")
    status.isEnabled = false
    menu.addItem(status)
    menu.addItem(.separator())

    let preview = NSMenuItem(
      title: popover.isShown ? "Hide Preview" : "Show Preview",
      action: #selector(menuTogglePreview), keyEquivalent: "c")
    preview.keyEquivalentModifierMask = [.option, .shift]
    preview.target = self
    menu.addItem(preview)

    let all = NSMenuItem(
      title: "All Cameras", action: #selector(menuOpenAll), keyEquivalent: "1")
    all.target = self
    menu.addItem(all)
    menu.addItem(.separator())

    let cameras = store.config.enabledCameras
    if cameras.isEmpty {
      let empty = NSMenuItem(title: "No cameras enabled", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
    } else {
      let current = store.config.resolvedMenuCameraID
      let multipleDevices =
        store.config.devices.filter { $0.cameras.contains(where: \.enabled) }.count > 1
      for device in store.config.devices {
        let enabled = device.cameras.filter(\.enabled)
        guard !enabled.isEmpty else { continue }
        if multipleDevices {
          let parent = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
          let submenu = NSMenu()
          for camera in enabled {
            let item = NSMenuItem(
              title: camera.name, action: #selector(menuOpenCamera(_:)), keyEquivalent: "")
            item.tag = camera.id
            item.target = self
            item.state = camera.id == current ? .on : .off
            submenu.addItem(item)
          }
          parent.submenu = submenu
          menu.addItem(parent)
        } else {
          for camera in enabled {
            let item = NSMenuItem(
              title: camera.name, action: #selector(menuOpenCamera(_:)), keyEquivalent: "")
            item.tag = camera.id
            item.target = self
            item.state = camera.id == current ? .on : .off
            menu.addItem(item)
          }
        }
      }
    }

    menu.addItem(.separator())

    if !store.isConfigured {
      let setup = NSMenuItem(
        title: "Add Camera…", action: #selector(menuOpenSetup), keyEquivalent: "")
      setup.target = self
      menu.addItem(setup)
    }

    let check = NSMenuItem(
      title: "Check Recorder Status", action: #selector(menuCheckStatus), keyEquivalent: "")
    check.target = self
    check.isEnabled = health != .checking
    menu.addItem(check)

    let settings = NSMenuItem(
      title: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)

    let quit = NSMenuItem(
      title: "Quit Sentinel Cam", action: #selector(menuQuit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)

    statusItem.menu = menu
    button.performClick(nil)
    statusItem.menu = nil
  }

  @objc private func menuTogglePreview() {
    if popover.isShown {
      popover.performClose(nil)
    } else {
      open()
    }
  }

  @objc private func menuOpenAll() {
    popover.performClose(nil)
    openWindow()
  }

  @objc private func menuOpenCamera(_ sender: NSMenuItem) {
    popover.performClose(nil)
    openCamera(sender.tag)
  }

  @objc private func menuOpenSettings() {
    popover.performClose(nil)
    openSettings()
  }

  @objc private func menuOpenSetup() {
    popover.performClose(nil)
    openSetup()
  }

  @objc private func menuQuit() {
    NSApp.terminate(nil)
  }

  // MARK: Icon badge

  /// A tiny red dot layered over the template camera glyph. Keeping the base
  /// image as a template lets macOS tint it for light/dark menu bars; the dot
  /// is a subview so it keeps its red color.
  private func installOfflineBadge() {
    guard let button = statusItem.button else { return }
    offlineBadge.autoresizingMask = [.minXMargin, .minYMargin]
    offlineBadge.isHidden = true
    button.addSubview(offlineBadge)
    positionOfflineBadge()
    DispatchQueue.main.async { [weak self] in self?.positionOfflineBadge() }
  }

  private func positionOfflineBadge() {
    guard let button = statusItem.button else { return }
    offlineBadge.frame = NSRect(
      x: button.bounds.maxX - 7, y: button.bounds.maxY - 7, width: 6, height: 6)
  }

  private func setHealth(_ new: CameraHealth) {
    health = new
    switch new {
    case .unhealthy: offlineBadge.isHidden = false
    case .healthy, .unknown: offlineBadge.isHidden = true
    case .checking: break
    }
    updateToolTip()
  }

  private func updateToolTip() {
    let text: String
    switch health {
    case .unknown: text = "Sentinel Cam — live cameras"
    case .checking: text = "Sentinel Cam — checking cameras…"
    case .healthy: text = "Sentinel Cam — cameras online"
    case .unhealthy: text = "Sentinel Cam — cameras offline"
    }
    statusItem.button?.toolTip = text
    statusItem.button?.setAccessibilityLabel(text)
  }

  // MARK: Health

  /// Handshake-only health checks. No frames are decoded, and a live popover
  /// is already the best possible proof that the recorder is up, so the probe
  /// stands down while it is streaming.
  private func startHealthMonitor() {
    healthMonitor = Task { [weak self] in
      while !Task.isCancelled {
        await self?.probeHealth(announce: false)
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  private func probeHealth(announce: Bool) async {
    guard let cameraID = store.config.resolvedMenuCameraID,
      let target = store.config.target(for: cameraID, secrets: store.secrets)
    else {
      setHealth(.unknown)
      if announce {
        store.toasts.replace(
          with: Toast(
            "No cameras enabled", detail: "Add one in Settings.", severity: .warning,
            actionTitle: "Open Settings",
            action: { [weak self] in self?.openSettings() }))
      }
      return
    }
    lastProbedCamera = cameraID

    if feed?.state == .live {
      consecutiveHealthFailures = 0
      setHealth(.healthy)
      if announce {
        store.toasts.replace(
          with: Toast("Cameras online", detail: "The preview is already live.", severity: .success))
      }
      return
    }
    // A connecting preview is already doing a handshake; don't race it.
    if feed?.isStreaming == true {
      if announce {
        store.toasts.replace(
          with: Toast("Still connecting…", detail: "Try again in a moment.", severity: .info))
      }
      return
    }

    setHealth(.checking)
    let result = await ConnectionProbe.probe(target)

    if result.isSuccess {
      consecutiveHealthFailures = 0
      setHealth(.healthy)
      if announce {
        store.toasts.replace(
          with: Toast("Cameras online", detail: result.summary, severity: .success))
      }
    } else {
      consecutiveHealthFailures += 1
      // One transient failure is not a red badge; two in a row is a pattern.
      if announce || consecutiveHealthFailures >= 2 {
        setHealth(.unhealthy)
      } else if health == .checking {
        setHealth(.unknown)
      }
      if announce {
        store.toasts.replace(
          with: Toast("Cameras offline", detail: result.error, severity: .error))
      }
    }
  }

  @objc private func menuCheckStatus() {
    store.toasts.show(Toast("Checking cameras…", severity: .info))
    Task { [weak self] in
      await self?.probeHealth(announce: true)
    }
  }

  // MARK: Popover lifecycle

  /// Every click loads a fresh connection: stop whatever was running, discard
  /// the decoder's last frame, and show the connecting pill until video flows.
  /// (The removed hover-prewarm kept a past session alive between clicks, and
  /// reopening surfaced the layer's frozen last frame — indistinguishable
  /// from live video. Fresh-per-click is unambiguous.)
  private func open() {
    feed?.stop()
    feed = nil
    if let cameraID = store.config.resolvedMenuCameraID {
      let fresh = CameraFeed(cameraID: cameraID, store: store)
      fresh.start()
      feed = fresh
      model.feed = fresh
    } else {
      model.feed = nil
    }
    // Menu Bar size can change between opens; keep the popover's frame in step.
    popover.contentSize = size()
    guard let button = statusItem.button else { return }
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
  }

  /// Camera picked in the popover: reconnect in place with the same fresh-click
  /// semantics (the popover stays open while the new stream connects).
  private func switchCamera(_ cameraID: Int) {
    guard store.config.enabledCameraIDs.contains(cameraID) else { return }
    store.config.menuCameraID = cameraID
    feed?.stop()
    let fresh = CameraFeed(cameraID: cameraID, store: store)
    fresh.start()
    feed = fresh
    model.feed = fresh
    popover.contentSize = size()
  }

  /// Settings can disable the camera currently shown in an open popover. Follow
  /// the resolved camera, or fall back to the empty state if none are left.
  private func syncPopoverCamera() {
    guard popover.isShown else { return }
    guard let cameraID = store.config.resolvedMenuCameraID else {
      feed?.stop()
      feed = nil
      model.feed = nil
      popover.contentSize = size()
      return
    }
    if feed?.cameraID != cameraID {
      switchCamera(cameraID)
    }
  }

  private func installContent() {
    let root = PopoverRoot(
      model: model,
      store: store,
      onSelectCamera: { [weak self] cameraID in
        self?.switchCamera(cameraID)
      },
      onOpenWindow: { [weak self] in
        guard let self else { return }
        self.popover.performClose(nil)
        self.openWindow()
      },
      onOpenCamera: { [weak self] cameraID in
        guard let self else { return }
        self.popover.performClose(nil)
        self.openCamera(cameraID)
      },
      onSettings: { [weak self] in
        guard let self else { return }
        self.popover.performClose(nil)
        self.openSettings()
      },
      onSetup: { [weak self] in
        guard let self else { return }
        self.popover.performClose(nil)
        self.openSetup()
      },
      onShift: { [weak self] forward in
        guard let self else { return }
        let cameras = self.store.config.enabledCameraIDs
        guard let current = self.feed?.cameraID ?? self.store.config.resolvedMenuCameraID,
          !cameras.isEmpty
        else { return }
        let index = cameras.firstIndex(of: current) ?? 0
        let next = cameras[(index + (forward ? 1 : -1) + cameras.count) % cameras.count]
        self.switchCamera(next)
      },
      onClose: { [weak self] in self?.popover.performClose(nil) }
    )

    popover.contentViewController = NSHostingController(rootView: root)
    popover.contentSize = size()
  }

  /// Menu bar preview size tracks the user's Small/Medium/Large choice.
  private func size() -> NSSize {
    NSSize(
      width: store.config.menuBarSize.popoverWidth,
      height: store.config.menuBarSize.popoverHeight)
  }

  func popoverDidClose(_ notification: Notification) {
    // A closed preview decodes nothing; the next click reloads fresh.
    feed?.stop()
    feed = nil
    model.feed = nil
  }

  private func closePopoverIfShown() {
    guard popover.isShown else { return }
    popover.performClose(nil)
  }

  // MARK: Click-away

  private func installClickMonitors() {
    // Accessory-app popovers often never resign key, so macOS's built-in "close
    // on outside click" doesn't fire. Monitor clicks ourselves: a click
    // anywhere outside this app (global) or inside another of our windows
    // (local) closes the popover. Clicks on the status item are skipped so the
    // button's own toggle logic runs.
    if let monitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseUp, .rightMouseUp],
      handler: { [weak self] _ in
        Task { @MainActor in self?.closePopoverIfShown() }
      })
    {
      monitors.append(monitor)
    }
    if let monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseUp, .rightMouseUp],
      handler: { [weak self] event in
        guard let self, let windowID = event.window.map(ObjectIdentifier.init) else {
          return event
        }
        Task { @MainActor in
          let popoverWindow = self.popover.contentViewController?.view.window
          let statusWindow = self.statusItem.button?.window
          if windowID != popoverWindow.map(ObjectIdentifier.init),
            windowID != statusWindow.map(ObjectIdentifier.init)
          {
            self.closePopoverIfShown()
          }
        }
        return event
      })
    {
      monitors.append(monitor)
    }
  }

  // MARK: Settings + hot key

  /// Re-arm the hot key and follow menu-camera changes without a settings
  /// callback plumbing through every view.
  private func observeSettings() {
    withObservationTracking {
      _ = store.config.popoverHotkey
      _ = store.config.menuCameraID
      _ = store.config.enabledCameras
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.applyHotkeySetting(announceFailure: true)
        self.syncPopoverCamera()
        if self.store.isConfigured, self.health == .unknown,
          self.store.config.resolvedMenuCameraID != self.lastProbedCamera
        {
          Task { await self.probeHealth(announce: false) }
        }
        self.observeSettings()
      }
    }
  }

  private func applyHotkeySetting(announceFailure: Bool) {
    if store.config.popoverHotkey {
      guard hotKeyID == nil else { return }
      hotKeyID = GlobalHotKeyCenter.shared.register(
        keyCode: SentinelHotKey.keyCode, modifiers: SentinelHotKey.modifiers
      ) { [weak self] in
        self?.toggleFromHotKey()
      }
      if hotKeyID == nil, announceFailure {
        store.toasts.show(
          Toast(
            "Shortcut unavailable",
            detail: "\(SentinelHotKey.label) is already used by another app.",
            severity: .warning))
      }
    } else if let hotKeyID {
      GlobalHotKeyCenter.shared.unregister(hotKeyID)
      self.hotKeyID = nil
    }
  }

  private func toggleFromHotKey() {
    if popover.isShown {
      popover.performClose(nil)
    } else {
      open()
    }
  }
}

/// A 6pt red dot that draws over the status item's template image without
/// intercepting clicks.
private final class OfflineBadgeView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    let dot = bounds.insetBy(dx: 0.5, dy: 0.5)
    NSColor.systemRed.setFill()
    NSBezierPath(ovalIn: dot).fill()
    NSColor.black.withAlphaComponent(0.35).setStroke()
    let stroke = NSBezierPath(ovalIn: dot)
    stroke.lineWidth = 0.75
    stroke.stroke()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// The main window itself is owned by the SwiftUI `Window` scene (see
// SentinelApp.swift); AppDelegate observes it. Only the menu bar + popover
// live here.

/// Popover content installed once and kept for the app's lifetime; it re-renders
/// as PopoverModel.feed changes. `.id` uses the feed *instance* (ObjectIdentifier),
/// not its camera: every click makes a fresh CameraFeed, and VideoLayerView's
/// NSView binds the video layer only at creation — reusing that view across
/// feeds would leave it showing a dead surface's layer (permanent black).
/// A fresh identity rebuilds it cleanly, inside the same content controller so
/// the popover never re-anchors.
private struct PopoverRoot: View {
  let model: PopoverModel
  let store: ConfigStore
  let onSelectCamera: (Int) -> Void
  let onOpenWindow: () -> Void
  let onOpenCamera: (Int) -> Void
  let onSettings: () -> Void
  let onSetup: () -> Void
  let onShift: (Bool) -> Void
  let onClose: () -> Void

  var body: some View {
    if let feed = model.feed {
      PopoverView(
        feed: feed,
        store: store,
        onSelectCamera: onSelectCamera,
        onOpenWindow: onOpenWindow,
        onOpenCamera: onOpenCamera,
        onSettings: onSettings,
        onShift: onShift,
        onClose: onClose
      )
      .id(ObjectIdentifier(feed))
    } else {
      PopoverEmptyState(store: store, onSetup: onSetup, onSettings: onSettings)
        .frame(
          width: store.config.menuBarSize.popoverWidth,
          height: store.config.menuBarSize.popoverHeight)
    }
  }
}

private struct PopoverEmptyState: View {
  let store: ConfigStore
  let onSetup: () -> Void
  let onSettings: () -> Void
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(spacing: 12) {
      Spacer(minLength: 0)
      EmptyStateCard(
        icon: "video.slash",
        title: "No cameras enabled",
        message: "Turn on at least one camera in Settings to see it here.",
        actionTitle: "Open Settings",
        action: onSettings
      )
      Spacer(minLength: 0)
      Rectangle()
        .fill(Style.border(scheme))
        .frame(height: 1)
      HStack {
        Button("Add Camera…", action: onSetup)
        Spacer()
        Button {
          NSApp.terminate(nil)
        } label: {
          Image(systemName: "power")
        }
        .help("Quit Sentinel Cam")
      }
      .buttonStyle(.borderless)
      .frame(height: 24)
    }
    .padding(12)
    .tint(Style.accentColor)
  }
}
