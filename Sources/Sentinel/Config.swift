import Foundation
import Observation

// MARK: - Camera model

/// Which RTSP stream a camera uses. Main is the default everywhere; sub is a
/// per-camera opt-in for recorders whose substream is cheaper to decode.
enum StreamQuality: String, Codable, CaseIterable, Identifiable, Sendable {
  case main, sub
  var id: String { rawValue }
  var label: String { self == .main ? "Main" : "Sub" }
  var caption: String { self == .main ? "Full resolution" : "Lower bandwidth" }
}

/// How the video fits its box. Stretch matches what most CCTV clients show;
/// Fit keeps the stream's real aspect ratio with letterboxing.
enum ScaleMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case fit, stretch
  var id: String { rawValue }
  var label: String { self == .fit ? "Fit" : "Stretch" }
}

/// One camera. `channel` is the recorder channel (always 1 for a standalone
/// camera) and is substituted into a device's path template.
struct CameraConfig: Codable, Identifiable, Hashable, Sendable {
  var id: Int
  var name: String
  var enabled: Bool
  var channel: Int
  var quality: StreamQuality
  var scale: ScaleMode

  init(
    id: Int, name: String, enabled: Bool = true, channel: Int = 1,
    quality: StreamQuality = .main, scale: ScaleMode = .fit
  ) {
    self.id = id
    self.name = name
    self.enabled = enabled
    self.channel = channel
    self.quality = quality
    self.scale = scale
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, enabled, channel, quality, scale
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Camera"
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? 1
    quality = try c.decodeIfPresent(StreamQuality.self, forKey: .quality) ?? .main
    scale = try c.decodeIfPresent(ScaleMode.self, forKey: .scale) ?? .fit
  }
}

/// A camera or recorder. Standalone cameras are devices with one camera;
/// recorders are devices with several cameras sharing host and credentials.
struct DeviceConfig: Codable, Identifiable, Hashable, Sendable {
  var id: Int
  var name: String
  var host: String
  var port: Int
  var username: String
  var transport: TransportKind
  var brand: CameraBrand
  var mainPath: String
  var subPath: String
  var cameras: [CameraConfig]

  init(
    id: Int, name: String, host: String, port: Int = 554, username: String = "",
    transport: TransportKind = .tcp, brand: CameraBrand = .generic,
    mainPath: String, subPath: String = "", cameras: [CameraConfig] = []
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.port = port
    self.username = username
    self.transport = transport
    self.brand = brand
    self.mainPath = mainPath
    self.subPath = subPath
    self.cameras = cameras
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, host, port, username, transport, brand, mainPath, subPath, cameras
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Camera"
    host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
    port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 554
    username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
    transport = try c.decodeIfPresent(TransportKind.self, forKey: .transport) ?? .tcp
    brand = try c.decodeIfPresent(CameraBrand.self, forKey: .brand) ?? .generic
    mainPath = try c.decodeIfPresent(String.self, forKey: .mainPath) ?? ""
    subPath = try c.decodeIfPresent(String.self, forKey: .subPath) ?? ""
    cameras = try c.decodeIfPresent([CameraConfig].self, forKey: .cameras) ?? []
  }

  /// The RTSP URL for one camera, honouring its Main/Sub choice. A device with
  /// no sub path falls back to the main stream rather than failing.
  func url(for camera: CameraConfig) -> String {
    let template = camera.quality == .sub && !subPath.isEmpty ? subPath : mainPath
    return Self.buildURL(
      host: host, port: port, path: Self.resolve(template, channel: max(1, camera.channel)))
  }

  static func buildURL(host: String, port: Int, path: String) -> String {
    var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    if host.contains(":") && !host.hasPrefix("[") { host = "[\(host)]" }
    var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.isEmpty { path = "/" }
    if !path.hasPrefix("/") { path = "/" + path }
    return "rtsp://\(host):\(port)\(path)"
  }

  /// Replaces `{channel}` and the zero-padded `{channel:02}` used by Reolink.
  static func resolve(_ template: String, channel: Int) -> String {
    var out = template
    out = out.replacingOccurrences(of: "{channel:02}", with: String(format: "%02d", channel))
    out = out.replacingOccurrences(of: "{channel}", with: String(channel))
    return out
  }

  /// Best-effort substream for a path imported from the old single-recorder
  /// config. Only used during migration; never guesses wildly.
  static func derivedSubPath(from main: String) -> String {
    if main.contains("subtype=0") {
      return main.replacingOccurrences(of: "subtype=0", with: "subtype=1")
    }
    if main.hasSuffix("01") {
      return String(main.dropLast(2)) + "02"
    }
    return ""
  }
}

// MARK: - Shared enums

enum TransportKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case tcp, udp
  var id: String { rawValue }
  var label: String { self == .tcp ? "TCP (recommended)" : "UDP" }
}

enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable {
  case system, light, dark
  var id: String { rawValue }

  var label: String {
    switch self {
    case .system: "Match System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

/// How large the menu bar popover's live stream renders. The video box is a
/// true 16:9 fit of the inner width (popover padding is 12pt on each side).
/// The fixed chrome is 153pt: 24pt outer padding, four 12pt gaps, a 24pt
/// header, a 28pt status row, a 1pt divider, and a 28pt footer.
enum MenuBarSize: String, Codable, CaseIterable, Identifiable, Sendable {
  case small, medium, large, extraLarge
  var id: String { rawValue }

  var label: String {
    switch self {
    case .small: "Small"
    case .medium: "Medium"
    case .large: "Large"
    case .extraLarge: "XL"
    }
  }

  var popoverWidth: CGFloat {
    switch self {
    case .small: 300
    case .medium: 340
    case .large: 420
    case .extraLarge: 540
    }
  }

  var videoHeight: CGFloat { round((popoverWidth - 24) * 9 / 16) }
  var popoverHeight: CGFloat { videoHeight + 153 }
}

/// How many 16:9 tiles in the all-cameras grid. More tiles = more concurrent decodes.
enum GridDensity: String, Codable, CaseIterable, Identifiable, Sendable {
  case twoByTwo
  case threeByThree
  var id: String { rawValue }

  var label: String {
    switch self {
    case .twoByTwo: "4 (2 × 2)"
    case .threeByThree: "9 (3 × 3)"
    }
  }

  var perPage: Int {
    switch self {
    case .twoByTwo: 4
    case .threeByThree: 9
    }
  }

  var columns: Int {
    switch self {
    case .twoByTwo: 2
    case .threeByThree: 3
    }
  }
}

// MARK: - App config

struct AppConfig: Codable, Equatable, Sendable {
  var schemaVersion = 2
  var devices: [DeviceConfig] = []
  var menuCameraID: Int?
  var appearance: Appearance = .system
  var menuBarSize: MenuBarSize = .medium
  var gridDensity: GridDensity = .twoByTwo
  var openWindowOnLaunch = false
  /// Global ⌥⇧C shortcut toggling the menu bar preview from anywhere.
  var popoverHotkey = true

  init() {}

  // MARK: Lookup

  func device(_ id: Int) -> DeviceConfig? { devices.first { $0.id == id } }

  func camera(_ id: Int) -> CameraConfig? {
    for device in devices {
      if let camera = device.cameras.first(where: { $0.id == id }) { return camera }
    }
    return nil
  }

  func device(for cameraID: Int) -> DeviceConfig? {
    devices.first { $0.cameras.contains { $0.id == cameraID } }
  }

  var allCameras: [CameraConfig] { devices.flatMap(\.cameras) }
  var enabledCameras: [CameraConfig] { allCameras.filter(\.enabled) }
  var enabledCameraIDs: [Int] { enabledCameras.map(\.id) }

  func name(for cameraID: Int) -> String { camera(cameraID)?.name ?? "Camera" }

  func label(for cameraID: Int) -> String {
    guard let device = device(for: cameraID), let camera = camera(cameraID) else {
      return "Camera"
    }
    return devices.count > 1 ? "\(device.name) — \(camera.name)" : camera.name
  }

  var nextDeviceID: Int { (devices.map(\.id).max() ?? 0) + 1 }
  var nextCameraID: Int { (allCameras.map(\.id).max() ?? 0) + 1 }

  /// A hash of everything that changes how a camera connects (not names or
  /// view scale). `ConfigStore` uses it to restart open streams only when a
  /// reconnect is actually needed.
  var connectionSignature: Int {
    var hasher = Hasher()
    for device in devices {
      hasher.combine(device.id)
      hasher.combine(device.host)
      hasher.combine(device.port)
      hasher.combine(device.username)
      hasher.combine(device.transport)
      hasher.combine(device.mainPath)
      hasher.combine(device.subPath)
      for camera in device.cameras {
        hasher.combine(camera.id)
        hasher.combine(camera.channel)
        hasher.combine(camera.quality)
        hasher.combine(camera.enabled)
      }
    }
    return hasher.finalize()
  }

  /// The camera the menu bar should actually show. Falls back to the first
  /// enabled camera when the saved choice was disabled or removed, so a
  /// settings change can never strand the popover on a dead camera.
  var resolvedMenuCameraID: Int? {
    if let selected = menuCameraID, camera(selected)?.enabled == true { return selected }
    return enabledCameras.first?.id
  }

  // MARK: Normalization

  /// A defensive copy used when a config arrives from disk, import, or the
  /// device editor. It keeps broken values and duplicate IDs from reaching a
  /// stream or SwiftUI's identity machinery.
  func normalized() -> AppConfig {
    var copy = self
    copy.schemaVersion = 2

    var usedDeviceIDs = Set<Int>()
    var usedCameraIDs = Set<Int>()
    var nextDeviceID = 1
    var nextCameraID = 1
    var devices: [DeviceConfig] = []

    for var device in copy.devices {
      device.host = device.host.trimmingCharacters(in: .whitespacesAndNewlines)
      device.username = device.username.trimmingCharacters(in: .whitespacesAndNewlines)
      device.mainPath = device.mainPath.trimmingCharacters(in: .whitespacesAndNewlines)
      device.subPath = device.subPath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !device.host.isEmpty, !device.mainPath.isEmpty else { continue }
      if !(1...65_535).contains(device.port) { device.port = 554 }
      if device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        device.name = device.cameras.count > 1 ? "Recorder" : "Camera"
      }
      if usedDeviceIDs.contains(device.id) {
        while usedDeviceIDs.contains(nextDeviceID) { nextDeviceID += 1 }
        device.id = nextDeviceID
      }
      usedDeviceIDs.insert(device.id)
      nextDeviceID = max(nextDeviceID, device.id + 1)

      var cameras: [CameraConfig] = []
      for var camera in device.cameras {
        if usedCameraIDs.contains(camera.id) {
          while usedCameraIDs.contains(nextCameraID) { nextCameraID += 1 }
          camera.id = nextCameraID
        }
        usedCameraIDs.insert(camera.id)
        nextCameraID = max(nextCameraID, camera.id + 1)
        camera.channel = max(1, camera.channel)
        if camera.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          camera.name = "Camera \(camera.channel)"
        }
        cameras.append(camera)
      }
      device.cameras = cameras
      guard !cameras.isEmpty else { continue }
      devices.append(device)
    }

    copy.devices = devices
    if let selected = copy.menuCameraID, copy.camera(selected)?.enabled == true {
      copy.menuCameraID = selected
    } else {
      copy.menuCameraID = copy.enabledCameras.first?.id
    }
    return copy
  }

  // MARK: Codable

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, devices, menuCameraID, appearance, menuBarSize, gridDensity
    case openWindowOnLaunch, popoverHotkey
    // Legacy single-recorder keys (v1).
    case host, port, username, pathTemplate, channels, menuChannel, transport
  }

  private struct LegacyChannel: Codable {
    var id: Int
    var name: String
    var enabled: Bool
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
    menuBarSize = try c.decodeIfPresent(MenuBarSize.self, forKey: .menuBarSize) ?? .medium
    gridDensity =
      try c.decodeIfPresent(GridDensity.self, forKey: .gridDensity) ?? .twoByTwo
    openWindowOnLaunch =
      try c.decodeIfPresent(Bool.self, forKey: .openWindowOnLaunch) ?? false
    popoverHotkey = try c.decodeIfPresent(Bool.self, forKey: .popoverHotkey) ?? true

    if let devices = try c.decodeIfPresent([DeviceConfig].self, forKey: .devices) {
      schemaVersion = 2
      self.devices = devices
      menuCameraID = try c.decodeIfPresent(Int.self, forKey: .menuCameraID)
      return
    }

    // v1: one recorder with N channels and a single password file.
    schemaVersion = 1
    let host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
    let port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 554
    let username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
    let path = try c.decodeIfPresent(String.self, forKey: .pathTemplate) ?? ""
    let transport = try c.decodeIfPresent(TransportKind.self, forKey: .transport) ?? .tcp
    let channels =
      try c.decodeIfPresent([LegacyChannel].self, forKey: .channels) ?? []
    let legacyMenu = try c.decodeIfPresent(Int.self, forKey: .menuChannel) ?? 1

    guard !host.isEmpty, !path.isEmpty else {
      devices = []
      menuCameraID = nil
      return
    }

    let cameras: [CameraConfig]
    if channels.isEmpty {
      cameras = [
        CameraConfig(
          id: 1, name: "Camera 1", enabled: true, channel: 1, quality: .main, scale: .stretch)
      ]
    } else {
      // Migrated cameras keep Stretch so the user's current picture is unchanged.
      cameras = channels.map {
        CameraConfig(
          id: $0.id, name: $0.name, enabled: $0.enabled, channel: $0.id,
          quality: .main, scale: .stretch)
      }
    }

    devices = [
      DeviceConfig(
        id: 1, name: "Recorder", host: host, port: port, username: username,
        transport: transport, brand: .dahua, mainPath: path,
        subPath: DeviceConfig.derivedSubPath(from: path), cameras: cameras)
    ]
    menuCameraID =
      cameras.first(where: { $0.channel == legacyMenu && $0.enabled })?.id
      ?? cameras.first(where: \.enabled)?.id
      ?? cameras.first?.id
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(2, forKey: .schemaVersion)
    try c.encode(devices, forKey: .devices)
    try c.encodeIfPresent(menuCameraID, forKey: .menuCameraID)
    try c.encode(appearance, forKey: .appearance)
    try c.encode(menuBarSize, forKey: .menuBarSize)
    try c.encode(gridDensity, forKey: .gridDensity)
    try c.encode(openWindowOnLaunch, forKey: .openWindowOnLaunch)
    try c.encode(popoverHotkey, forKey: .popoverHotkey)
  }
}

// MARK: - Secrets

/// Per-device passwords in a 0600 JSON file. Keychain is deliberately not used:
/// ad-hoc signed builds change identity on every rebuild, which makes macOS
/// re-prompt for the login keychain password each time.
enum SecretStore {
  static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Sentinel", isDirectory: true)
  }

  static var fileURL: URL { directory.appendingPathComponent("secrets.json") }

  /// The v1 single password file. Read once during migration, never deleted.
  static var legacyPasswordURL: URL { directory.appendingPathComponent("password") }

  static func read() -> [Int: String] {
    guard let data = try? Data(contentsOf: fileURL),
      let raw = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    var values: [Int: String] = [:]
    for (key, value) in raw {
      if let id = Int(key), !value.isEmpty { values[id] = value }
    }
    return values
  }

  static func write(_ values: [Int: String]) {
    let manager = FileManager.default
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    guard !values.isEmpty else {
      try? manager.removeItem(at: fileURL)
      return
    }
    let raw = Dictionary(uniqueKeysWithValues: values.map { (String($0.key), $0.value) })
    guard let data = try? JSONEncoder().encode(raw) else { return }
    try? data.write(to: fileURL, options: .atomic)
    try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  static func readLegacyPassword() -> String {
    guard let raw = try? String(contentsOf: legacyPasswordURL, encoding: .utf8) else {
      return ""
    }
    return raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
  }
}

// MARK: - Store

@MainActor
@Observable
final class ConfigStore {
  let toasts = ToastQueue()

  var config: AppConfig {
    didSet {
      // Disabling or deleting the camera that feeds the menu bar must not leave
      // the picker pointing at a dead camera. If every camera is off, keep the
      // old choice; `resolvedMenuCameraID` repairs it at read time.
      if let selected = config.menuCameraID, config.camera(selected)?.enabled == true {
        // Still valid.
      } else if let first = config.enabledCameras.first?.id,
        first != config.menuCameraID
      {
        config.menuCameraID = first
        return
      }
      scheduleSave()
      if config.connectionSignature != oldValue.connectionSignature {
        streamRevision &+= 1
      }
    }
  }

  /// Device ID → password. Only devices with a password have an entry.
  var secrets: [Int: String] {
    didSet {
      SecretStore.write(secrets)
      streamRevision &+= 1
    }
  }

  /// Bumped whenever something that affects an open connection changes, so
  /// visible feeds can restart with the new URL, credentials, or quality.
  private(set) var streamRevision = 0

  /// Debounced persistence: coalesces rapid edits (typing in Settings) into a
  /// single disk write ~0.5 s after the last change.
  private var saveTask: Task<Void, Never>?

  private let fileURL: URL

  init() {
    let dir = SecretStore.directory
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    fileURL = dir.appendingPathComponent("config.json")

    let rawData = try? Data(contentsOf: fileURL)
    var migratedFromV1 = false
    let loadedConfig: AppConfig
    if let rawData,
      let saved = try? JSONDecoder().decode(AppConfig.self, from: rawData)
    {
      migratedFromV1 = saved.schemaVersion < 2
      loadedConfig = saved.normalized()
    } else {
      loadedConfig = AppConfig()
    }
    config = loadedConfig

    var loaded = SecretStore.read()
    if loaded.isEmpty, let first = loadedConfig.devices.first {
      let legacy = SecretStore.readLegacyPassword()
      if !legacy.isEmpty {
        loaded[first.id] = legacy
        SecretStore.write(loaded)
      }
    }
    secrets = loaded

    if migratedFromV1 {
      // Keep the original next to the new file, then write v2 once so the
      // migration is not repeated on every launch.
      if let rawData {
        try? rawData.write(
          to: dir.appendingPathComponent("config.v1.backup.json"), options: .atomic)
      }
      save()
    }
  }

  // MARK: Credentials

  func password(for deviceID: Int) -> String { secrets[deviceID] ?? "" }

  func setPassword(_ value: String, for deviceID: Int) {
    if value.isEmpty {
      secrets.removeValue(forKey: deviceID)
    } else {
      secrets[deviceID] = value
    }
  }

  // MARK: Device management

  func removeDevice(_ deviceID: Int) {
    config.devices.removeAll { $0.id == deviceID }
    secrets.removeValue(forKey: deviceID)
  }

  /// True when at least one device exists. Anonymous cameras are valid, so a
  /// missing password alone does not mean "not configured".
  var isConfigured: Bool { !config.devices.isEmpty }

  private func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(0.5))
      guard !Task.isCancelled else { return }
      save()
      saveTask = nil
    }
  }

  private func save() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(config) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
