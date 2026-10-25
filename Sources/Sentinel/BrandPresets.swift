import Foundation

/// Starting points for the major RTSP families. Paths are editable in the
/// device editor because firmware varies; these cover the common defaults.
enum CameraBrand: String, Codable, CaseIterable, Identifiable, Sendable {
  case dahua, hikvision, reolink, tapo, axis, uniview, foscam, hanwha, vivotek, generic

  var id: String { rawValue }

  var label: String {
    switch self {
    case .dahua: "Dahua / Amcrest"
    case .hikvision: "Hikvision / HiLook"
    case .reolink: "Reolink"
    case .tapo: "Tapo / VIGI"
    case .axis: "Axis"
    case .uniview: "Uniview"
    case .foscam: "Foscam"
    case .hanwha: "Hanwha / Wisenet"
    case .vivotek: "Vivotek"
    case .generic: "Generic RTSP"
    }
  }

  /// Other names people search for, shown as a subtitle.
  var family: String {
    switch self {
    case .dahua: "Dahua, Amcrest, Lorex, Imou, CP Plus"
    case .hikvision: "Hikvision, HiLook, Annke, EZVIZ"
    case .reolink: "Reolink cameras and NVRs"
    case .tapo: "TP-Link Tapo and VIGI"
    case .axis: "Axis cameras"
    case .uniview: "Uniview / UNV"
    case .foscam: "Foscam and clones"
    case .hanwha: "Samsung / Hanwha / Wisenet"
    case .vivotek: "Vivotek cameras"
    case .generic: "Any camera with an RTSP URL"
    }
  }

  var defaultPort: Int { self == .foscam ? 88 : 554 }

  /// Brands that commonly ship as multi-channel recorders. Tapo, Axis, and
  /// Foscam are cameras in practice, so the editor defaults them to one camera.
  var supportsRecorder: Bool {
    switch self {
    case .tapo, .axis, .foscam, .generic: false
    default: true
    }
  }

  /// Main and substream path templates. `{channel}` is replaced with the
  /// recorder channel; `{channel:02}` is the zero-padded Reolink form.
  func paths(recorder: Bool) -> (main: String, sub: String) {
    switch self {
    case .dahua:
      return (
        "/cam/realmonitor?channel={channel}&subtype=0",
        "/cam/realmonitor?channel={channel}&subtype=1"
      )
    case .hikvision:
      return ("/Streaming/Channels/{channel}01", "/Streaming/Channels/{channel}02")
    case .reolink:
      return ("/Preview_{channel:02}_main", "/Preview_{channel:02}_sub")
    case .tapo:
      return ("/stream1", "/stream2")
    case .axis:
      return ("/axis-media/media.amp", "")
    case .uniview:
      if recorder {
        return ("/unicast/c{channel}/s0/live", "/unicast/c{channel}/s1/live")
      }
      return ("/media/video1", "/media/video2")
    case .foscam:
      return ("/videoMain", "/videoSub")
    case .hanwha:
      return ("/profile2/media.smp", "/profile3/media.smp")
    case .vivotek:
      return ("/live.sdp", "/live2.sdp")
    case .generic:
      return ("", "")
    }
  }
}

// MARK: - URL parsing

struct ParsedRTSPURL: Equatable, Sendable {
  var host: String
  var port: Int
  var username: String
  var password: String
  /// Path plus query string, always starting with `/`.
  var path: String
}

/// Parses a pasted RTSP URL into device fields. It deliberately splits at the
/// last `@` so passwords containing `@` still work, and handles bracketed IPv6.
/// The parser's two outcomes. A plain enum (rather than `Result` with a
/// String error) keeps the failure text available without an Error wrapper.
enum RTSPURLParseResult {
  case success(ParsedRTSPURL)
  case failure(String)
}

enum RTSPURLParser {
  static func parse(_ raw: String) -> RTSPURLParseResult {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .failure("Paste an rtsp:// URL first.") }

    guard let schemeRange = trimmed.range(of: "://") else {
      return .failure("The URL needs an rtsp:// prefix.")
    }
    let scheme = trimmed[..<schemeRange.lowerBound].lowercased()
    guard scheme == "rtsp" else {
      return .failure("Only rtsp:// is supported (not \(scheme)://).")
    }

    let rest = String(trimmed[schemeRange.upperBound...])
    let authorityEnd =
      rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
    let authority = String(rest[..<authorityEnd])
    var path = String(rest[authorityEnd...])
    if path.isEmpty || path.hasPrefix("#") { path = "/" }
    if path.hasPrefix("?") { path = "/" + path }
    if !path.hasPrefix("/") { path = "/" + path }

    guard !authority.isEmpty else { return .failure("The URL is missing a host.") }

    var hostPort = authority
    var username = ""
    var password = ""
    if let at = authority.lastIndex(of: "@") {
      let userInfo = String(authority[..<at])
      hostPort = String(authority[authority.index(after: at)...])
      if let colon = userInfo.firstIndex(of: ":") {
        username = decode(String(userInfo[..<colon]))
        password = decode(String(userInfo[userInfo.index(after: colon)...]))
      } else {
        username = decode(userInfo)
      }
    }

    guard !hostPort.isEmpty else { return .failure("The URL is missing a host.") }

    var host = hostPort
    var port = 554
    if hostPort.hasPrefix("[") {
      guard let close = hostPort.firstIndex(of: "]") else {
        return .failure("The IPv6 address is missing a closing bracket.")
      }
      host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
      let after = hostPort[hostPort.index(after: close)...]
      if after.hasPrefix(":") {
        guard let value = Int(after.dropFirst()), (1...65_535).contains(value) else {
          return .failure("The port must be between 1 and 65535.")
        }
        port = value
      }
    } else if hostPort.contains(":") {
      // A hostname has at most one colon (the port separator). More than one
      // means an unbracketed IPv6 address, which would parse ambiguously.
      guard hostPort.filter({ $0 == ":" }).count == 1,
        let colon = hostPort.firstIndex(of: ":")
      else {
        return .failure("Wrap IPv6 addresses in [ ].")
      }
      let portText = hostPort[hostPort.index(after: colon)...]
      guard let value = Int(portText), (1...65_535).contains(value) else {
        return .failure("The port must be a number between 1 and 65535.")
      }
      host = String(hostPort[..<colon])
      port = value
    }

    guard !host.isEmpty else { return .failure("The URL is missing a host.") }
    return .success(
      ParsedRTSPURL(
        host: host, port: port, username: username, password: password, path: path))
  }

  private static func decode(_ value: String) -> String {
    value.removingPercentEncoding ?? value
  }
}

// MARK: - Stream target

#if canImport(IPCamKit)
  import IPCamKit

  /// Everything one feed needs to connect, resolved from the current config.
  struct StreamTarget {
    let cameraID: Int
    let url: String
    let credentials: Credentials?
    let transport: Transport
  }

  extension AppConfig {
    func target(for cameraID: Int, secrets: [Int: String]) -> StreamTarget? {
      guard let device = device(for: cameraID), let camera = camera(cameraID) else {
        return nil
      }
      let password = secrets[device.id] ?? ""
      let credentials =
        password.isEmpty ? nil : Credentials(username: device.username, password: password)
      return StreamTarget(
        cameraID: cameraID,
        url: device.url(for: camera),
        credentials: credentials,
        transport: device.transport == .tcp ? .tcp : .udp)
    }
  }
#endif
