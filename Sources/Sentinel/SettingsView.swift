import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The settings page of the main window's split view, laid out like System
/// Settings: a scrollable stack of grouped cards, with the label (and a short
/// explanation) on the left and the control on the right. Edits are persisted
/// by `ConfigStore` with a short debounce.
struct SettingsView: View {
  @Bindable var store: ConfigStore
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var activeSheet: SettingsSheet?
  @State private var removal: Removal?
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(spacing: 0) {
      PageHeader("Settings", subtitle: "Cameras, menu bar, and startup")

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          devicesSection
          camerasSection
          menuBarSection
          generalSection
          keyboardSection
          configurationSection
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(Style.contentFill(scheme))
    .tint(Style.accentColor)
    .sheet(item: $activeSheet) { sheet in
      switch sheet {
      case .tester:
        ConnectionTesterView(store: store)
      case .setup, .addDevice:
        SetupWizardView(store: store) { activeSheet = nil }
      case .editDevice(let id):
        DeviceEditorView(store: store, deviceID: id) { activeSheet = nil }
      }
    }
    .confirmationDialog(
      removalTitle,
      isPresented: Binding(
        get: { removal != nil },
        set: { if !$0 { removal = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) { performRemoval() }
      Button("Cancel", role: .cancel) { removal = nil }
    } message: {
      Text("This removes it from Sentinel. Your camera itself is not changed.")
    }
  }

  private enum SettingsSheet: Identifiable {
    case tester
    case setup
    case addDevice
    case editDevice(Int)

    var id: String {
      switch self {
      case .tester: "tester"
      case .setup: "setup"
      case .addDevice: "add"
      case .editDevice(let id): "edit-\(id)"
      }
    }
  }

  private enum Removal: Identifiable {
    case device(Int, String)
    case camera(Int, Int, String)

    var id: String {
      switch self {
      case .device(let id, _): "device-\(id)"
      case .camera(_, let cameraID, _): "camera-\(cameraID)"
      }
    }
  }

  private var removalTitle: String {
    switch removal {
    case .device(_, let name): "Remove \(name)?"
    case .camera(_, _, let name): "Remove \(name)?"
    case nil: "Remove?"
    }
  }

  private func performRemoval() {
    switch removal {
    case .device(let id, _):
      store.removeDevice(id)
    case .camera(let deviceID, let cameraID, _):
      guard let index = store.config.devices.firstIndex(where: { $0.id == deviceID }) else {
        break
      }
      store.config.devices[index].cameras.removeAll { $0.id == cameraID }
      if store.config.devices[index].cameras.isEmpty {
        store.removeDevice(deviceID)
      }
    case nil:
      break
    }
    removal = nil
  }

  // MARK: Devices

  private var devicesSection: some View {
    card(
      "Devices",
      footnote:
        "A camera is one device; an NVR or DVR is one device with several cameras. Passwords stay on this Mac and are never exported."
    ) {
      if store.config.devices.isEmpty {
        row("No cameras yet", caption: "Add a camera or recorder to start watching.", divider: false) {
          Button("Add Camera…") { activeSheet = .setup }
            .buttonStyle(.borderedProminent)
        }
      } else {
        ForEach(store.config.devices) { device in
          row(
            device.name,
            caption: "\(device.host):\(device.port) · \(cameraCountLabel(device.cameras.count)) · \(device.brand.label)"
          ) {
            HStack(spacing: 8) {
              Button("Edit…") { activeSheet = .editDevice(device.id) }
              Button(role: .destructive) {
                removal = .device(device.id, device.name)
              } label: {
                Image(systemName: "trash")
              }
              .help("Remove \(device.name)")
            }
          }
        }
        row("Add", caption: nil, divider: false) {
          HStack(spacing: 8) {
            Button("Add Camera…") { activeSheet = .setup }
            Button("Test All…") { activeSheet = .tester }
          }
        }
      }
    }
  }

  private func cameraCountLabel(_ count: Int) -> String {
    count == 1 ? "1 camera" : "\(count) cameras"
  }

  // MARK: Cameras

  private var camerasSection: some View {
    card(
      "Cameras",
      footnote:
        "Main stream is the default. Choose Sub for a camera only when you want its lower-bandwidth stream."
    ) {
      row(
        "Tiles per page",
        caption: "More tiles decode more streams at once — CPU scales with what is on screen."
      ) {
        Picker("", selection: $store.config.gridDensity) {
          ForEach(GridDensity.allCases) { density in
            Text(density.label).tag(density)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)
      }

      if store.config.devices.allSatisfy({ $0.cameras.isEmpty }) {
        row("No cameras", caption: "Add a camera to a device first.", divider: false) {
          Button("Add Camera…") { activeSheet = .setup }
        }
      } else {
        ForEach($store.config.devices) { $device in
          if !device.cameras.isEmpty {
            deviceHeader(device.name)
            ForEach($device.cameras) { $camera in
              cameraRow(deviceID: device.id, camera: $camera)
            }
          }
        }
      }
    }
  }

  private func deviceHeader(_ name: String) -> some View {
    HStack {
      Text(name)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.top, 10)
    .padding(.bottom, 2)
  }

  private func cameraRow(deviceID: Int, camera: Binding<CameraConfig>) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        // Flexible so the row fills the card: name hugs the left edge, and the
        // channel, quality, switch, and delete button sit at the right edge
        // instead of leaving a dead zone on the right.
        TextField("Camera name", text: camera.name)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: .infinity, alignment: .leading)

        TextField("Ch", value: camera.channel, format: .number)
          .textFieldStyle(.roundedBorder)
          .frame(width: 46)
          .help("Recorder channel")

        Picker("", selection: camera.quality) {
          ForEach(StreamQuality.allCases) { quality in
            Text(quality.label).tag(quality)
          }
        }
        .labelsHidden()
        .frame(width: 82)
        .help("Main is the default; Sub uses the lower-bandwidth stream.")

        Toggle("", isOn: camera.enabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
          .help("Show and decode this camera")

        Button(role: .destructive) {
          removal = .camera(deviceID, camera.wrappedValue.id, camera.wrappedValue.name)
        } label: {
          Image(systemName: "trash")
        }
        .help("Remove \(camera.wrappedValue.name)")
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 7)

      Divider().padding(.leading, 14)
    }
  }

  // MARK: Menu bar

  private var menuBarSection: some View {
    card("Menu Bar") {
      row("Live camera", caption: "Which camera streams from the menu bar icon.") {
        if store.config.enabledCameras.isEmpty {
          Text("No cameras enabled")
            .foregroundStyle(.secondary)
        } else {
          Picker("", selection: $store.config.menuCameraID) {
            ForEach(store.config.devices) { device in
              let cameras = device.cameras.filter(\.enabled)
              if !cameras.isEmpty {
                Section(device.name) {
                  ForEach(cameras) { camera in
                    Text(camera.name).tag(Optional(camera.id))
                  }
                }
              }
            }
          }
          .labelsHidden()
          .frame(width: 220)
        }
      }

      row(
        "Stream size",
        caption: "Preview size when you click the menu bar icon. Applies the next time it opens.",
        divider: false
      ) {
        Picker("", selection: $store.config.menuBarSize) {
          ForEach(MenuBarSize.allCases) { size in
            Text(size.label).tag(size)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 280)
      }
    }
  }

  // MARK: General

  private var generalSection: some View {
    card("General") {
      row("Appearance", caption: "Match the system, or pin Sentinel Cam to one look.") {
        Picker("", selection: $store.config.appearance) {
          ForEach(Appearance.allCases) { appearance in
            Text(appearance.label).tag(appearance)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240)
      }
      .onChange(of: store.config.appearance) { _, appearance in
        appearance.applyToApp()
      }

      row("Launch at login", caption: "Keeps the menu bar icon available after restarting your Mac.") {
        Toggle("", isOn: $launchAtLogin)
          .labelsHidden()
          .toggleStyle(.switch)
      }
      .onChange(of: launchAtLogin) { _, enabled in
        do {
          if enabled {
            try SMAppService.mainApp.register()
          } else {
            try SMAppService.mainApp.unregister()
          }
        } catch {
          store.toasts.show(
            Toast(
              "Couldn't change login item", detail: error.localizedDescription, severity: .error))
        }
      }

      row(
        "Open main window at launch",
        caption: "Show the camera grid as soon as Sentinel Cam starts."
      ) {
        Toggle("", isOn: $store.config.openWindowOnLaunch)
          .labelsHidden()
          .toggleStyle(.switch)
      }

      row("Version", divider: false) {
        Text(versionString)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Keyboard

  private var keyboardSection: some View {
    card("Keyboard") {
      row(
        "Toggle menu bar preview",
        caption: "Works from any app; no Accessibility permission is needed."
      ) {
        HStack(spacing: 10) {
          ShortcutCaps(keys: ["⌥", "⇧", "C"])
          Toggle("", isOn: $store.config.popoverHotkey)
            .labelsHidden()
            .toggleStyle(.switch)
        }
      }

      shortcutRow("Show all cameras", ["⌘", "1"])
      shortcutRow("Settings", ["⌘", ","])
      shortcutRow("Previous page / camera", ["←"])
      shortcutRow("Next page / camera", ["→"])
      shortcutRow("Exit maximized camera", ["esc"], divider: false)
    }
  }

  private func shortcutRow(_ title: String, _ keys: [String], divider: Bool = true) -> some View {
    row(title, divider: divider) {
      ShortcutCaps(keys: keys)
    }
  }

  // MARK: Configuration

  private var configurationSection: some View {
    card(
      "Configuration",
      footnote: "Settings are portable JSON. Passwords are never exported."
    ) {
      row(
        "Backup",
        caption: "Export the device and camera setup, or restore it on another Mac.",
        divider: false
      ) {
        HStack(spacing: 8) {
          Button("Export…") { exportSettings() }
          Button("Import…") { importSettings() }
        }
      }
    }
  }

  private func exportSettings() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "Sentinel Cam Settings.json"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(store.config).write(to: url, options: .atomic)
        store.toasts.show(
          Toast("Settings exported", detail: url.lastPathComponent, severity: .success))
      } catch {
        store.toasts.show(
          Toast(
            "Couldn't export settings", detail: error.localizedDescription, severity: .error))
      }
    }
  }

  private func importSettings() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do {
        let imported = try JSONDecoder()
          .decode(AppConfig.self, from: Data(contentsOf: url))
          .normalized()
        store.config = imported
        imported.appearance.applyToApp()
        store.toasts.show(
          Toast(
            "Settings imported",
            detail: "Re-enter device passwords in Edit… if this is a new Mac.",
            severity: .success))
      } catch {
        store.toasts.show(
          Toast(
            "Couldn't import settings", detail: error.localizedDescription, severity: .error))
      }
    }
  }

  private var versionString: String {
    let name =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? "Sentinel Cam"
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "\(name) \(version) (\(build))"
  }

  // MARK: Building blocks

  /// A System Settings-style group: a section title, a card of rows, and an
  /// optional footnote underneath.
  @ViewBuilder
  private func card<Content: View>(
    _ title: String, footnote: String? = nil, @ViewBuilder rows: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.system(size: 12.5, weight: .semibold))
        .padding(.leading, 2)

      VStack(spacing: 0) {
        rows()
      }
      .background(
        Style.cardFill(scheme),
        in: RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
          .strokeBorder(Style.border(scheme), lineWidth: 1)
      )

      if let footnote {
        Text(footnote)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 2)
          .padding(.top, 1)
      }
    }
  }

  /// One label-left / control-right row. The control column is capped so long
  /// captions keep room to wrap instead of squeezing the control.
  @ViewBuilder
  private func row<Control: View>(
    _ title: String, caption: String? = nil, divider: Bool = true,
    @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        if let caption {
          Text(caption)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 12)
      control()
        .frame(maxWidth: 320, alignment: .trailing)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)

    if divider {
      Divider().padding(.leading, 14)
    }
  }
}

// MARK: - Connection Tester

/// Probes every enabled camera with the same handshake the setup wizard uses.
/// Nothing is decoded; this is just DESCRIBE → SETUP → PLAY and teardown.
private struct ConnectionTesterView: View {
  let store: ConfigStore
  @Environment(\.dismiss) private var dismiss

  @State private var results: [Int: HealthState] = [:]
  @State private var testing = false
  @State private var testTask: Task<Void, Never>?

  private enum HealthState {
    case testing
    case ok(ProbeResult)
    case error(String)
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 4) {
        Text("Connection Tester")
          .font(.headline)
        Text("Handshake only — no video is decoded.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 20)
      .padding(.bottom, 16)

      if store.config.enabledCameras.isEmpty {
        EmptyStateCard(
          icon: "video.slash",
          title: "No cameras enabled",
          message: "Enable a camera in Settings, then run the test again."
        )
        .padding(24)
        .frame(maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(spacing: 8) {
            ForEach(store.config.enabledCameras) { camera in
              resultRow(camera)
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
        }
        .frame(height: 300)
      }

      Divider()

      HStack(spacing: 12) {
        if !store.config.enabledCameras.isEmpty {
          Text(summary)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Close") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(testing ? "Testing…" : "Test Again") { runTest() }
          .buttonStyle(.borderedProminent)
          .disabled(testing || store.config.enabledCameras.isEmpty)
      }
      .padding(16)
    }
    .frame(width: 520)
    .tint(Style.accentColor)
    .onAppear { runTest() }
    .onDisappear { testTask?.cancel() }
  }

  private func resultRow(_ camera: CameraConfig) -> some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(camera.name)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        if let device = store.config.device(for: camera.id) {
          Text(device.name)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)

      switch results[camera.id] {
      case .testing:
        ProgressView()
          .controlSize(.small)
      case .ok(let result):
        Text(result.summary)
          .font(.caption)
          .foregroundStyle(Style.successColor)
          .lineLimit(1)
          .help(result.summary)
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(Style.successColor)
      case .error(let message):
        Text(message)
          .font(.caption)
          .foregroundStyle(Style.errorColor)
          .lineLimit(2)
          .multilineTextAlignment(.trailing)
          .help(message)
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(Style.errorColor)
      case nil:
        Text("Waiting…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
  }

  private var summary: String {
    let total = store.config.enabledCameras.count
    let connected = results.values.filter {
      if case .ok = $0 { return true }
      return false
    }.count
    return "\(connected) of \(total) connected"
  }

  @MainActor
  private func runTest() {
    testTask?.cancel()
    results = [:]
    testing = true

    let cameras = store.config.enabledCameras
    let config = store.config
    let secrets = store.secrets
    testTask = Task { @MainActor in
      for camera in cameras {
        guard !Task.isCancelled else { return }
        results[camera.id] = .testing
        guard let target = config.target(for: camera.id, secrets: secrets) else {
          results[camera.id] = .error("This camera is no longer in your setup.")
          continue
        }
        let probe = await ConnectionProbe.probe(target)
        guard !Task.isCancelled else { return }
        results[camera.id] = probe.isSuccess ? .ok(probe) : .error(probe.error ?? "Unknown error")
      }
      testing = false
    }
  }
}
