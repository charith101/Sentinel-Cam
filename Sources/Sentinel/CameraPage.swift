import SwiftUI

/// One camera, maximized: the stream fills the pane. Fit keeps the stream's
/// real aspect ratio; Stretch fills the box (the old CCTV-client look). Esc or
/// the arrows walk you back / to the next camera.
struct CameraPage: View {
  let model: GridModel
  let cameraID: Int
  var onExit: () -> Void
  var onShift: (Bool) -> Void

  @State private var scale: ScaleMode
  @State private var feed: CameraFeed?
  @Environment(\.colorScheme) private var scheme

  init(
    model: GridModel, cameraID: Int, onExit: @escaping () -> Void,
    onShift: @escaping (Bool) -> Void
  ) {
    self.model = model
    self.cameraID = cameraID
    self.onExit = onExit
    self.onShift = onShift
    _scale = State(initialValue: model.store.config.camera(cameraID)?.scale ?? .fit)
  }

  var body: some View {
    VStack(spacing: 0) {
      PageHeader(model.label(for: cameraID), subtitle: streamSubtitle) {
        HStack(spacing: 8) {
          headerButton("chevron.left", "Previous camera (←)") { onShift(false) }
          headerButton("chevron.right", "Next camera (→)") { onShift(true) }
          headerButton("square.grid.2x2", "All cameras (⌘1)") { onExit() }
          Picker("Scale", selection: $scale) {
            ForEach(ScaleMode.allCases) { mode in
              Text(mode.label).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(width: 132)
          .tint(Style.accentColor)
          headerButton(
            (feed?.audioEnabled ?? false) ? "speaker.wave.2.fill" : "speaker.slash",
            "Mute / Unmute",
            active: feed?.audioEnabled ?? false
          ) {
            feed?.setAudioEnabled(!(feed?.audioEnabled ?? false))
          }
          .disabled(feed?.audioAvailable == false)
          moreMenu
        }
      }
      video
    }
    .tint(Style.accentColor)
    .background(Style.contentFill(scheme))
    .onExitCommand(perform: onExit)
    .onMoveCommand { direction in
      switch direction {
      case .left: onShift(false)
      case .right: onShift(true)
      default: break
      }
    }
    .onAppear {
      // Feeds are created outside body evaluation (see GridModel); stream start
      // itself is driven by MainView's syncVisible.
      let current = model.feed(for: cameraID)
      current.setStretching(scale == .stretch)
      feed = current
      // A single maximized camera is the one place with sound.
      current.setAudioEnabled(true)
    }
    .onDisappear { feed?.setAudioEnabled(false) }
    .onChange(of: scale) { _, mode in
      feed?.setStretching(mode == .stretch)
      persist(mode)
    }
  }

  private var streamSubtitle: String {
    let quality = model.store.config.camera(cameraID)?.quality ?? .main
    return "\(quality.label) stream"
  }

  private var moreMenu: some View {
    Menu {
      Button("Save Snapshot…") { feed?.snapshot() }
      Button("Copy Snapshot") { feed?.copySnapshot() }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .contentShape(.rect)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .frame(width: 24, height: 24)
    .help("Snapshots")
  }

  /// Scale is a display preference, not a connection setting: it saves without
  /// restarting the stream.
  private func persist(_ mode: ScaleMode) {
    let config = model.store.config
    guard let deviceIndex = config.devices.firstIndex(where: {
      $0.cameras.contains { $0.id == cameraID }
    }),
      let cameraIndex = config.devices[deviceIndex].cameras.firstIndex(where: {
        $0.id == cameraID
      })
    else { return }
    model.store.config.devices[deviceIndex].cameras[cameraIndex].scale = mode
  }

  private func headerButton(
    _ systemName: String, _ help: String, active: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(active ? Style.accentColor : Color.secondary)
        .frame(width: 24, height: 24)
        .contentShape(.rect)
    }
    .buttonStyle(.borderless)
    .help(help)
  }

  @ViewBuilder private var video: some View {
    Group {
      if let feed {
        ZStack {
          Color.black
          VideoLayerView(surface: feed.surface)
          overlayLoading(feed)
        }
      } else {
        Color.black
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .overlay(alignment: .bottomTrailing) { fpsBadge }
    .clipped()
  }

  @ViewBuilder private var fpsBadge: some View {
    if let feed, feed.state == .live {
      FpsReadout(feed: feed)
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(12)
        .allowsHitTesting(false)
    }
  }

  @ViewBuilder private func overlayLoading(_ feed: CameraFeed) -> some View {
    switch feed.state {
    case .failed(let message):
      ErrorCover(message: message) { feed.restart() }
    case .connecting:
      ConnectingOverlay()
        .environment(\.colorScheme, .dark)
    case .idle, .live:
      EmptyView()
    }
  }
}
