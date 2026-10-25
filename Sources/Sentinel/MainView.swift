import Observation
import SwiftUI

/// Sidebar destinations. The camera page shows exactly one stream, the grid
/// page shows a page of tiles, and settings decodes nothing.
enum SidebarPage: Hashable {
  case grid
  case camera(Int)
  case settings
}

/// The main window: a plain sidebar column and a detail pane. Streams follow
/// the selection, so only what is shown decodes.
///
/// Deliberately simple: no NavigationSplitView, no List-based sidebar, no
/// toolbar, no window minima. Earlier builds stacked those together and the
/// result was an AppKit ↔ SwiftUI "Update Constraints in Window pass" loop
/// (the window kept re-marking itself dirty every layout pass until AppKit
/// threw — the EXC_BREAKPOINT crash). Plain stacks layout in one pass and
/// stay quiet.
struct MainView: View {
  let model: GridModel

  @State private var selection: SidebarPage = .grid
  @State private var page = 0
  @State private var showSetupWizard = false
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: Style.sidebarWidth)
      Rectangle()
        .fill(Style.hairline)
        .frame(width: 1)
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Style.contentFill(scheme))
    .ignoresSafeArea(.container, edges: .top)
    .tint(Style.accentColor)
    .sheet(isPresented: $showSetupWizard) {
      SetupWizardView(store: model.store) {
        showSetupWizard = false
        withAnimation(.snappy(duration: 0.2)) { selection = .grid }
      }
    }
    .onChange(of: selection) { _, _ in applySync() }
    .onChange(of: page) { _, _ in applySync() }
    .onChange(of: model.windowVisible) { _, visible in
      if visible { applySync() }
    }
    .onChange(of: model.resyncTick) { _, _ in applySync() }
    .onChange(of: model.settingsTick) { _, _ in selection = .settings }
    .onChange(of: model.gridTick) { _, _ in selection = .grid }
    .onChange(of: model.wantsSetup) { _, wants in
      guard wants else { return }
      model.wantsSetup = false
      showSetupWizard = true
    }
    .onChange(of: model.requestedCamera) { _, cameraID in
      // A click on the menu bar preview jumps straight to that camera.
      guard let cameraID else { return }
      model.requestedCamera = nil
      selection = .camera(cameraID)
    }
    .onChange(of: model.store.config.gridDensity) { _, _ in
      page = clampPage(page)
      applySync()
    }
    .onChange(of: model.store.config.enabledCameraIDs) { _, ids in
      // A camera that was disabled in settings must not stay on screen.
      if case .camera(let cameraID) = selection, !ids.contains(cameraID) {
        selection = .grid
      }
      page = clampPage(page)
      applySync()
    }
    // Editing a URL, password, transport, or quality restarts what is visible.
    .onChange(of: model.store.streamRevision) { _, _ in applySync(force: true) }
    .onChange(of: showSetupWizard) { _, _ in applySync() }
    .task {
      if model.wantsSetup {
        model.wantsSetup = false
        showSetupWizard = true
      }
      applySync()
    }
  }

  // MARK: Sidebar

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      brandHeader

      ScrollView {
        VStack(alignment: .leading, spacing: 1) {
          Text("CAMERAS").sidebarSectionHeader()

          sidebarRow(
            .grid, systemName: "square.grid.2x2", title: "All Cameras",
            count: model.store.config.enabledCameras.count)

          ForEach(model.store.config.devices) { device in
            let cameras = device.cameras.filter(\.enabled)
            if !cameras.isEmpty {
              Text(device.name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(device.name)
                .padding(.horizontal, 9)
                .padding(.top, 12)
                .padding(.bottom, 3)
              ForEach(cameras) { camera in
                cameraRow(camera)
              }
            }
          }

          if model.store.config.devices.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
              Text("No cameras yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
              Text("Add one to start watching.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.top, 6)
          }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 14)
      }
      .scrollIndicators(.never)

      bottomBar
    }
    .background(Style.sidebarFill(scheme))
  }

  private var brandHeader: some View {
    HStack(spacing: 9) {
      ZStack {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(Style.accentColor.opacity(0.15))
          .frame(width: 26, height: 26)
        Image(systemName: "video.fill")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Style.accentColor)
          .accessibilityHidden(true)
      }
      Text("Sentinel Cam")
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
      Spacer(minLength: 4)
      Button {
        showSetupWizard = true
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 22, height: 22)
          .contentShape(.rect)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .help("Add a camera or recorder")
    }
    .padding(.horizontal, 14)
    .padding(.top, Style.titlebarInset + 6)
    .padding(.bottom, 10)
  }

  private var bottomBar: some View {
    VStack(spacing: 0) {
      Rectangle()
        .fill(Style.hairline)
        .frame(height: 1)

      sidebarRow(.settings, systemName: "gearshape", title: "Settings")
        .padding(.horizontal, 10)
        .padding(.top, 8)

      HStack(spacing: 6) {
        Circle()
          .fill(streamCount > 0 ? Style.successColor : Color(nsColor: .tertiaryLabelColor))
          .frame(width: 6, height: 6)
        Text("\(cameraCountLabel) · \(streamCount) live")
          .monospacedDigit()
        Spacer(minLength: 0)
      }
      .font(.system(size: 10))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 14)
      .padding(.top, 6)
      .padding(.bottom, 9)
      .allowsHitTesting(false)
    }
  }

  private func cameraRow(_ camera: CameraConfig) -> some View {
    sidebarButton(selected: selection == .camera(camera.id)) {
      withAnimation(.snappy(duration: 0.18)) { selection = .camera(camera.id) }
    } content: {
      Image(systemName: "video")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(selection == .camera(camera.id) ? Style.accentColor : Color.secondary)
        .frame(width: 16)
      Text(camera.name)
        .font(.system(size: 12.5, weight: selection == .camera(camera.id) ? .semibold : .regular))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      if let feed = model.feedIfExists(camera.id) {
        StatusDot(state: feed.state)
      }
    }
  }

  private func sidebarRow(
    _ page: SidebarPage, systemName: String, title: String, count: Int? = nil
  ) -> some View {
    let selected = selection == page
    return sidebarButton(selected: selected) {
      withAnimation(.snappy(duration: 0.18)) { selection = page }
    } content: {
      Image(systemName: systemName)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(selected ? Style.accentColor : Color.secondary)
        .frame(width: 16)
      Text(title)
        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
        .foregroundStyle(.primary)
        .lineLimit(1)
      Spacer(minLength: 4)
      if let count, count > 0 {
        Text("\(count)")
          .font(.system(size: 10, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    }
  }

  /// One native-style sidebar row: 28pt tall, 7pt selection pill, no hover
  /// tracking (cursor-tracking hit tests are what the old crash report
  /// implicated; selection is enough feedback here).
  private func sidebarButton<Content: View>(
    selected: Bool, action: @escaping () -> Void,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        content()
      }
      .padding(.horizontal, 9)
      .frame(height: 28)
      .background {
        if selected {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Style.selectionFill(scheme))
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private var streamCount: Int {
    model.feeds.filter(\.isStreaming).count
  }

  private var cameraCountLabel: String {
    let count = model.store.config.enabledCameras.count
    return count == 1 ? "1 camera" : "\(count) cameras"
  }

  // MARK: Detail

  @ViewBuilder private var detail: some View {
    switch selection {
    case .grid:
      GridPage(
        model: model, page: $page,
        onFocus: { cameraID in
          withAnimation(.snappy(duration: 0.2)) { selection = .camera(cameraID) }
        },
        onOpenSettings: {
          withAnimation(.snappy(duration: 0.2)) { selection = .settings }
        }
      )
    case .camera(let cameraID):
      // `id` makes camera-to-camera switches create a fresh page state
      // (otherwise the page would keep decoding state for the previous feed).
      CameraPage(
        model: model, cameraID: cameraID,
        onExit: { withAnimation(.snappy(duration: 0.2)) { selection = .grid } },
        onShift: { shiftSelection(forward: $0) }
      )
      .id(cameraID)
    case .settings:
      SettingsView(store: model.store)
    }
  }

  private func shiftSelection(forward: Bool) {
    let cameras = model.store.config.enabledCameraIDs
    guard let current = selection.cameraID, !cameras.isEmpty else { return }
    let index = cameras.firstIndex(of: current) ?? 0
    let next = cameras[(index + (forward ? 1 : -1) + cameras.count) % cameras.count]
    withAnimation(.snappy(duration: 0.2)) { selection = .camera(next) }
  }

  // MARK: Stream lifecycle

  private var pageCount: Int {
    max((model.store.config.enabledCameras.count + density.perPage - 1) / density.perPage, 1)
  }

  private var density: GridDensity {
    model.store.config.gridDensity
  }

  private func clampPage(_ page: Int) -> Int {
    min(max(page, 0), max(pageCount - 1, 0))
  }

  private func pageIDs(_ page: Int) -> [Int] {
    let enabled = model.store.config.enabledCameraIDs
    let start = clampPage(page) * density.perPage
    return Array(enabled[start ..< min(start + density.perPage, enabled.count)])
  }

  private func applySync(force: Bool = false) {
    // A setup sheet is a modal pause: don't start streams that would just fail
    // against the old (or empty) credentials while the user is configuring.
    guard !showSetupWizard else {
      model.syncVisible([])
      return
    }
    switch selection {
    case .camera(let cameraID):
      model.syncVisible([cameraID], force: force)
    case .settings:
      model.syncVisible([], force: force)
    case .grid:
      model.syncVisible(pageIDs(page), force: force)
    }
  }
}

extension SidebarPage {
  var cameraID: Int? {
    if case .camera(let cameraID) = self { return cameraID }
    return nil
  }
}

// MARK: - Small sidebar helpers

private extension Text {
  func sidebarSectionHeader() -> some View {
    self
      .font(.system(size: 10, weight: .semibold))
      .kerning(0.6)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 9)
      .padding(.top, 4)
      .padding(.bottom, 4)
  }
}
