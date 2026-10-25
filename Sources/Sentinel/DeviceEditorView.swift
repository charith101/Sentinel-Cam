import IPCamKit
import SwiftUI

/// Add or edit a device — a standalone camera or a multi-channel recorder.
/// Shared by first-run setup, "Add Camera…", and Settings → Edit.
///
/// The form is intentionally a starting point, not a camera database: brand
/// presets fill in the usual path, and every field stays editable.
struct DeviceEditorView: View {
  let store: ConfigStore
  let deviceID: Int?
  let onboarding: Bool
  var onFinish: () -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var scheme

  @State private var draft: DeviceConfig
  @State private var password: String
  @State private var recorder: Bool
  @State private var cameraCount: Int
  @State private var nextID: Int
  @State private var pastedURL = ""
  @State private var pasteMessage: String?
  @State private var pasteOK = false
  @State private var showAdvanced: Bool
  @State private var testResult: ProbeResult?
  @State private var testing = false
  @State private var testTask: Task<Void, Never>?

  init(
    store: ConfigStore, deviceID: Int?, onboarding: Bool = false,
    onFinish: @escaping () -> Void
  ) {
    self.store = store
    self.deviceID = deviceID
    self.onboarding = onboarding
    self.onFinish = onFinish

    let existing = deviceID.flatMap { store.config.device($0) }
    let startID = existing?.id ?? store.config.nextDeviceID
    let startCameraID = store.config.nextCameraID
    let startRecorder =
      existing.map { $0.cameras.count > 1 || $0.mainPath.contains("{channel}") } ?? true
    let preset = CameraBrand.dahua.paths(recorder: startRecorder)
    let initialCameras =
      existing?.cameras
      ?? (1...4).map {
        CameraConfig(
          id: startCameraID + $0 - 1, name: "Camera \($0)", enabled: true, channel: $0,
          quality: .main, scale: .fit)
      }
    let initial =
      existing
      ?? DeviceConfig(
        id: startID, name: "Recorder", host: "", port: 554, username: "",
        transport: .tcp, brand: .dahua, mainPath: preset.main, subPath: preset.sub,
        cameras: initialCameras)

    _draft = State(initialValue: initial)
    _password = State(initialValue: existing.flatMap { store.secrets[$0.id] } ?? "")
    _recorder = State(initialValue: startRecorder)
    _cameraCount = State(initialValue: max(initialCameras.count, 1))
    _nextID = State(
      initialValue: existing == nil ? startCameraID + initialCameras.count : startCameraID)
    _showAdvanced = State(initialValue: existing != nil)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          quickStart
          addressGroup
          camerasGroup
          if let testResult { resultGroup(testResult) }
        }
        .padding(20)
      }
      Divider()
      footer
    }
    .frame(width: 600, height: 640)
    .tint(Style.accentColor)
    .interactiveDismissDisabled(testing)
    .onAppear { syncCameras() }
    .onDisappear { testTask?.cancel() }
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(Style.accentColor.opacity(0.14))
          .frame(width: 38, height: 38)
        Image(systemName: recorder ? "externaldrive.connected.to.line.below" : "video.fill")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(Style.accentColor)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.title3.weight(.semibold))
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
    }
    .padding(20)
  }

  private var title: String {
    if deviceID != nil { return "Edit \(draft.name)" }
    return onboarding ? "Add your first camera" : "Add a camera or recorder"
  }

  private var subtitle: String {
    if deviceID != nil {
      return "Update the address, credentials, and cameras. Changes restart any open stream."
    }
    return
      "Paste the RTSP URL from your camera's app, or pick a brand to fill in the usual path."
  }

  // MARK: Quick start

  private var quickStart: some View {
    group("Quick start") {
      VStack(alignment: .leading, spacing: 6) {
        Text("Paste an RTSP URL")
          .font(.callout.weight(.medium))
        HStack(spacing: 8) {
          TextField("rtsp://user:password@192.168.1.50:554/stream1", text: $pastedURL)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .onSubmit { applyPaste() }
          Button("Use") { applyPaste() }
            .disabled(pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if let pasteMessage {
          Label(pasteMessage, systemImage: pasteOK ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.caption)
            .foregroundStyle(pasteOK ? Style.successColor : Style.errorColor)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text("Credentials are split out of the URL and stored only on this Mac.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Address

  private var addressGroup: some View {
    group("Device") {
      HStack(alignment: .top, spacing: 12) {
        labeled("Name") {
          TextField("Recorder", text: $draft.name)
            .textFieldStyle(.roundedBorder)
        }
        labeled("Brand") {
          Picker("", selection: $draft.brand) {
            ForEach(CameraBrand.allCases) { brand in
              Text(brand.label).tag(brand)
            }
          }
          .labelsHidden()
          .frame(width: 210)
        }
        .frame(width: 220)
      }

      Toggle("This device has multiple cameras (NVR / DVR)", isOn: $recorder)
        .toggleStyle(.switch)
        .controlSize(.small)
        .onChange(of: recorder) { _, isRecorder in
          if isRecorder, draft.cameras.count == 1 { cameraCount = 4 }
          if draft.brand != .generic {
            let paths = draft.brand.paths(recorder: isRecorder)
            draft.mainPath = paths.main
            draft.subPath = paths.sub
          }
          syncCameras()
        }

      HStack(alignment: .top, spacing: 12) {
        labeled("Host") {
          TextField("192.168.1.50", text: $draft.host)
            .textFieldStyle(.roundedBorder)
        }
        labeled("Port") {
          TextField("554", value: $draft.port, format: .number)
            .textFieldStyle(.roundedBorder)
        }
        .frame(width: 100)
        labeled("Transport") {
          Picker("", selection: $draft.transport) {
            ForEach(TransportKind.allCases) { kind in
              Text(kind.label).tag(kind)
            }
          }
          .labelsHidden()
          .frame(width: 150)
        }
        .frame(width: 170)
      }

      HStack(alignment: .top, spacing: 12) {
        labeled("Username") {
          TextField("Username", text: $draft.username)
            .textFieldStyle(.roundedBorder)
        }
        labeled("Password") {
          SecureField("Password", text: $password)
            .textFieldStyle(.roundedBorder)
        }
      }

      Text("Leave the username empty only for anonymous access.")
        .font(.caption2)
        .foregroundStyle(.secondary)

      DisclosureGroup("Advanced paths", isExpanded: $showAdvanced) {
        VStack(alignment: .leading, spacing: 10) {
          labeled("Main stream path") {
            TextField("/cam/realmonitor?channel={channel}&subtype=0", text: $draft.mainPath)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
          }
          labeled("Sub stream path (optional)") {
            TextField("/cam/realmonitor?channel={channel}&subtype=1", text: $draft.subPath)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
          }
          Text("Use {channel} where the recorder channel goes. Leave the sub path empty to reuse the main stream.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
      }
      .font(.callout.weight(.medium))
    }
    .onChange(of: draft.brand) { _, brand in
      guard brand != .generic else { return }
      draft.port = brand.defaultPort
      let paths = brand.paths(recorder: recorder)
      draft.mainPath = paths.main
      draft.subPath = paths.sub
      if !brand.supportsRecorder, recorder { recorder = false }
    }
  }

  // MARK: Cameras

  private var camerasGroup: some View {
    group("Cameras") {
      if recorder {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Number of cameras")
            Text("Created as channels 1…N; rename and adjust each one below.")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Stepper("\(cameraCount)", value: $cameraCount, in: 1...64)
            .onChange(of: cameraCount) { _, _ in syncCameras() }
        }
      }

      ForEach($draft.cameras) { $camera in
        HStack(spacing: 8) {
          TextField("Camera name", text: $camera.name)
            .textFieldStyle(.roundedBorder)

          if recorder {
            TextField("Ch", value: $camera.channel, format: .number)
              .textFieldStyle(.roundedBorder)
              .frame(width: 44)
              .help("Recorder channel")
          }

          Picker("", selection: $camera.quality) {
            ForEach(StreamQuality.allCases) { quality in
              Text(quality.label).tag(quality)
            }
          }
          .labelsHidden()
          .frame(width: 76)
          .help("Main is the default; Sub uses the lower-bandwidth stream.")

          Toggle("", isOn: $camera.enabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Show and decode this camera")

          if draft.cameras.count > 1 {
            Button(role: .destructive) {
              removeCamera(camera.id)
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this camera")
          }
        }
      }

      if recorder {
        Button {
          addCamera()
        } label: {
          Label("Add Camera", systemImage: "plus")
        }
        .buttonStyle(.borderless)
      }
    }
  }

  // MARK: Result

  private func resultGroup(_ result: ProbeResult) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
        .font(.system(size: 20))
        .foregroundStyle(result.isSuccess ? Style.successColor : Style.errorColor)
      VStack(alignment: .leading, spacing: 3) {
        Text(result.isSuccess ? "Connected" : "Couldn't connect")
          .font(.headline)
        Text(result.summary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
    }
    .padding(12)
    .background(
      Style.cardFill(scheme),
      in: RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
        .strokeBorder(Style.border(scheme), lineWidth: 1)
    )
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 10) {
      Button("Cancel") {
        testTask?.cancel()
        dismiss()
      }
      .keyboardShortcut(.cancelAction)

      Spacer()

      Button(testing ? "Testing…" : "Test Connection") { runTest() }
        .disabled(!canTest || testing)

      Button(deviceID == nil ? "Add" : "Save") { save() }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSave || testing)
    }
    .padding(16)
  }

  // MARK: Actions

  private var canTest: Bool {
    !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (1...65_535).contains(draft.port)
      && !draft.mainPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !draft.cameras.isEmpty
  }

  private var canSave: Bool {
    canTest && draft.cameras.allSatisfy {
      !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private func takeID() -> Int {
    defer { nextID += 1 }
    return nextID
  }

  private func nextChannel(in cameras: [CameraConfig]) -> Int {
    (cameras.map(\.channel).max() ?? 0) + 1
  }

  private func syncCameras() {
    if recorder {
      let target = max(cameraCount, 1)
      var cameras = draft.cameras
      if cameras.count > target {
        cameras.removeLast(cameras.count - target)
      } else {
        while cameras.count < target {
          let channel = nextChannel(in: cameras)
          cameras.append(
            CameraConfig(
              id: takeID(), name: "Camera \(channel)", enabled: true, channel: channel,
              quality: .main, scale: .fit))
        }
      }
      draft.cameras = cameras
      cameraCount = cameras.count
    } else {
      var cameras = draft.cameras
      if cameras.isEmpty {
        cameras = [
          CameraConfig(
            id: takeID(), name: draft.name.isEmpty ? "Camera" : draft.name, enabled: true,
            channel: 1, quality: .main, scale: .fit)
        ]
      } else if cameras.count > 1 {
        cameras.removeSubrange(1...)
      }
      cameras[0].channel = 1
      draft.cameras = cameras
      cameraCount = 1
    }
  }

  private func addCamera() {
    let channel = nextChannel(in: draft.cameras)
    draft.cameras.append(
      CameraConfig(
        id: takeID(), name: "Camera \(channel)", enabled: true, channel: channel,
        quality: .main, scale: .fit))
    cameraCount = draft.cameras.count
  }

  private func removeCamera(_ id: Int) {
    draft.cameras.removeAll { $0.id == id }
    if draft.cameras.isEmpty { syncCameras() }
    cameraCount = max(draft.cameras.count, 1)
  }

  private func applyPaste() {
    switch RTSPURLParser.parse(pastedURL) {
    case .success(let parsed):
      draft.host = parsed.host
      draft.port = parsed.port
      draft.username = parsed.username
      password = parsed.password
      draft.mainPath = parsed.path
      draft.subPath = ""
      draft.brand = .generic
      if recorder { recorder = false }
      if draft.cameras.isEmpty {
        draft.cameras = [
          CameraConfig(
            id: takeID(), name: "Camera", enabled: true, channel: 1, quality: .main,
            scale: .fit)
        ]
      } else if draft.cameras.count > 1 {
        draft.cameras.removeSubrange(1...)
      }
      cameraCount = 1
      pasteOK = true
      pasteMessage = "Filled from \(parsed.host):\(parsed.port)\(parsed.path)"
      if draft.name.isEmpty || draft.name == "Recorder" { draft.name = "Camera" }
    case .failure(let message):
      pasteOK = false
      pasteMessage = message
    }
  }

  private func runTest() {
    testTask?.cancel()
    testing = true
    testResult = nil

    guard let camera = draft.cameras.first(where: \.enabled) ?? draft.cameras.first else {
      testing = false
      return
    }
    let credentials =
      password.isEmpty ? nil : Credentials(username: draft.username, password: password)
    let target = StreamTarget(
      cameraID: camera.id,
      url: draft.url(for: camera),
      credentials: credentials,
      transport: draft.transport == .tcp ? .tcp : .udp)

    testTask = Task { @MainActor in
      let probe = await ConnectionProbe.probe(target)
      guard !Task.isCancelled else { return }
      testResult = probe
      testing = false
    }
  }

  private func save() {
    var device = draft
    device.name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
    device.host = device.host.trimmingCharacters(in: .whitespacesAndNewlines)
    device.username = device.username.trimmingCharacters(in: .whitespacesAndNewlines)
    device.mainPath = device.mainPath.trimmingCharacters(in: .whitespacesAndNewlines)
    device.subPath = device.subPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if device.name.isEmpty {
      device.name = device.cameras.count > 1 ? "Recorder" : "Camera"
    }
    for index in device.cameras.indices {
      device.cameras[index].channel = max(1, device.cameras[index].channel)
      let name = device.cameras[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
      device.cameras[index].name =
        name.isEmpty ? "Camera \(device.cameras[index].channel)" : name
    }

    if deviceID == nil { device.id = store.config.nextDeviceID }

    // Keep camera IDs unique app-wide without reassigning the ones this device
    // already owned.
    var used = Set(store.config.allCameras.map(\.id))
    if let deviceID, let own = store.config.device(deviceID) {
      for camera in own.cameras { used.remove(camera.id) }
    }
    var next = (used.max() ?? 0) + 1
    for index in device.cameras.indices where used.contains(device.cameras[index].id) {
      while used.contains(next) { next += 1 }
      device.cameras[index].id = next
      used.insert(next)
    }

    if let deviceID,
      let index = store.config.devices.firstIndex(where: { $0.id == deviceID })
    {
      store.config.devices[index] = device
    } else {
      store.config.devices.append(device)
    }
    store.setPassword(password, for: device.id)
    if store.config.menuCameraID == nil {
      store.config.menuCameraID = store.config.resolvedMenuCameraID
    }

    store.toasts.show(
      Toast(
        deviceID == nil ? "Camera added" : "Camera updated",
        detail: "\(device.name) · \(device.host)", severity: .success))
    onFinish()
    dismiss()
  }

  // MARK: Building blocks

  private func group<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased())
        .font(.system(size: 10, weight: .semibold))
        .kerning(0.5)
        .foregroundStyle(.secondary)
        .padding(.leading, 2)

      VStack(alignment: .leading, spacing: 10) {
        content()
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Style.cardFill(scheme),
        in: RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
          .strokeBorder(Style.border(scheme), lineWidth: 1)
      )
    }
  }

  private func labeled<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.callout.weight(.medium))
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
