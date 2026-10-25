import AppKit
import SwiftUI

struct PopoverView: View {
  let feed: CameraFeed
  let store: ConfigStore
  let onSelectCamera: (Int) -> Void
  let onOpenWindow: () -> Void
  let onOpenCamera: (Int) -> Void
  let onSettings: () -> Void
  let onShift: (Bool) -> Void
  let onClose: () -> Void

  @State private var selection: Int
  @State private var keyMonitor: Any?
  @Environment(\.colorScheme) private var scheme

  init(
    feed: CameraFeed, store: ConfigStore, onSelectCamera: @escaping (Int) -> Void,
    onOpenWindow: @escaping () -> Void, onOpenCamera: @escaping (Int) -> Void,
    onSettings: @escaping () -> Void, onShift: @escaping (Bool) -> Void,
    onClose: @escaping () -> Void
  ) {
    self.feed = feed
    self.store = store
    self.onSelectCamera = onSelectCamera
    self.onOpenWindow = onOpenWindow
    self.onOpenCamera = onOpenCamera
    self.onSettings = onSettings
    self.onShift = onShift
    self.onClose = onClose
    _selection = State(initialValue: feed.cameraID)
  }

  var body: some View {
    VStack(spacing: 12) {
      header
        .frame(height: 24)

      ZStack {
        // Speed first: bare video — whatever the decoder has shows immediately,
        // with an honest connecting pill while no frames are flowing yet.
        VideoLayerView(surface: feed.surface)
        if feed.state == .connecting {
          ConnectingOverlay(caption: nil)
        }
        // Tapping the preview opens that camera maximized in the main window.
        Button(action: { onOpenCamera(feed.cameraID) }) {
          Color.clear
        }
        .buttonStyle(.plain)
        .help("Open this camera in Sentinel Cam")
        // Only a genuine failure gets a cover — never a loading state.
        if case .failed(let message) = feed.state {
          ErrorCover(message: message) { feed.restart() }
        }
      }
      // 16:9 playback box, stretched to fill (matches what VLC shows); height
      // follows the user's menu bar size choice (Small/Medium/Large/XL).
      .frame(height: store.config.menuBarSize.videoHeight)
      .background(.black)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Style.border(scheme), lineWidth: 0.7)
      )
      .contextMenu {
        Button("Open in Sentinel Cam") { onOpenCamera(feed.cameraID) }
        Divider()
        Button("Save Snapshot…") { feed.snapshot() }
        Button("Copy Snapshot") { feed.copySnapshot() }
      }

      statusRow
        .frame(height: 28)

      Rectangle()
        .fill(Style.border(scheme))
        .frame(height: 1)

      footer
        .frame(height: 28)
    }
    .padding(12)
    // A fixed frame is what keeps the popover from jittering as status text,
    // fps, and button labels change. The chrome height is part of MenuBarSize.
    .frame(width: store.config.menuBarSize.popoverWidth, height: store.config.menuBarSize.popoverHeight)
    .tint(Style.accentColor)
    .onChange(of: selection) { _, cameraID in
      guard cameraID != feed.cameraID else { return }
      onSelectCamera(cameraID)
    }
    .onChange(of: feed.cameraID) { _, cameraID in
      if selection != cameraID { selection = cameraID }
    }
    .onMoveCommand { direction in
      guard store.config.enabledCameras.count > 1 else { return }
      switch direction {
      case .left: onShift(false)
      case .right: onShift(true)
      default: break
      }
    }
    .onAppear { installKeyMonitor() }
    .onDisappear { removeKeyMonitor() }
  }

  private func installKeyMonitor() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
      guard event.keyCode == 53 else { return event } // Escape
      onClose()
      return event
    }
  }

  private func removeKeyMonitor() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
  }

  private var header: some View {
    HStack(spacing: 8) {
      StatusDot(state: feed.state, pulses: true)
      Text(store.config.label(for: feed.cameraID))
        .font(.headline)
        .lineLimit(1)
        .foregroundStyle(.primary)

      Spacer(minLength: 6)

      if store.config.enabledCameras.count > 1 {
        HStack(spacing: 2) {
          Button { onShift(false) } label: { Image(systemName: "chevron.left") }
          Button { onShift(true) } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(Style.accentColor)
        .help("Switch camera")

        Picker("", selection: $selection) {
          ForEach(store.config.devices) { device in
            let cameras = device.cameras.filter(\.enabled)
            if !cameras.isEmpty {
              Section(device.name) {
                ForEach(cameras) { camera in
                  Text(camera.name).tag(camera.id)
                }
              }
            }
          }
        }
        .labelsHidden()
        .frame(width: 122)
        .tint(Style.accentColor)
      }
    }
  }

  private var statusRow: some View {
    HStack(spacing: 8) {
      Text(feed.detail.isEmpty ? "connecting…" : feed.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

      if feed.state == .live {
        FpsReadout(feed: feed)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      // Primary action on the same line as fps: open this exact camera,
      // maximized, in the main window.
      Button(action: { onOpenCamera(feed.cameraID) }) {
        Label("Open", systemImage: "macwindow.on.rectangle")
          .lineLimit(1)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .help("Open this camera in Sentinel Cam")

      Button(action: { feed.snapshot() }) {
        Image(systemName: "camera")
          .foregroundStyle(.primary)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .help("Save snapshot")
    }
  }

  private var footer: some View {
    HStack {
      Button(action: onOpenWindow) {
        Label("All Cameras", systemImage: "square.grid.2x2")
      }
      Spacer()
      Button(action: onSettings) {
        Image(systemName: "gearshape")
      }
      .help("Settings (⌘,)")
      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        Image(systemName: "power")
      }
      .help("Quit Sentinel Cam")
    }
    .buttonStyle(.borderless)
    // Adaptive black/white: these are navigation actions, not accent marks.
    .foregroundStyle(.primary)
  }
}
