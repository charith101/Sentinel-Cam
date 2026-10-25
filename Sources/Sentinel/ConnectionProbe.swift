import Foundation
import IPCamKit

/// The result of a handshake-only connection test. No frames are decoded:
/// `RTSPClientSession.start()` performs DESCRIBE → SETUP → PLAY and returns
/// the stream description, which is exactly what setup needs to validate.
struct ProbeResult: Sendable {
  let codec: String?
  let resolution: String?
  let hasAudio: Bool
  let error: String?

  var isSuccess: Bool { error == nil }

  /// "H.265 · 960×1080 · audio" — the useful one-line summary.
  var summary: String {
    guard isSuccess else { return error ?? "Unknown error" }
    var parts: [String] = []
    if let codec { parts.append(codec) }
    if let resolution { parts.append(resolution) }
    parts.append(hasAudio ? "audio" : "no audio")
    return parts.joined(separator: " · ")
  }
}

enum ConnectionProbe {
  /// Performs the RTSP handshake for one target and immediately tears it down.
  /// Safe to call while streams are stopped; don't call it for a camera that is
  /// already streaming (the camera may reject a second session).
  static func probe(_ target: StreamTarget) async -> ProbeResult {
    await probe(
      url: target.url, credentials: target.credentials, transport: target.transport)
  }

  static func probe(url: String, credentials: Credentials?, transport: Transport)
    async -> ProbeResult
  {
    let session = RTSPClientSession(
      url: url, credentials: credentials, transport: transport, onDiagnostic: nil)

    do {
      let description = try await session.start()
      await session.stop()
      let video = description.video
      return ProbeResult(
        codec: video.map { $0.codec == .h265 ? "H.265" : "H.264" },
        resolution: video?.resolution.map { "\($0.width)×\($0.height)" },
        hasAudio: description.audio != nil,
        error: nil
      )
    } catch {
      await session.stop()
      return ProbeResult(
        codec: nil, resolution: nil, hasAudio: false, error: friendlyError(error))
    }
  }

  /// Turns IPCamKit's precise but technical errors into something a person can
  /// act on. The original text is kept where it is genuinely useful.
  static func friendlyError(_ error: Error) -> String {
    if error is CancellationError { return "Test cancelled." }

    if let rtsp = error as? RTSPError {
      switch rtsp {
      case .authenticationFailed:
        return "The username or password was rejected."
      case .timeout:
        return "The camera didn't answer. Check the IP address and that it's on the same network."
      case .connectionFailed(let message):
        return "Could not reach the camera: \(message)"
      case .sessionSetupFailed(let code, let reason):
        return "The camera refused the stream (\(code): \(reason))."
      case .transportNegotiationFailed:
        return "The camera and Sentinel couldn't agree on a transport. Try TCP."
      case .unexpectedDisconnection:
        return "The camera closed the connection."
      case .invalidSDP(let message):
        return "The stream description was invalid: \(message)"
      case .depacketizationError(let message):
        return "The stream data was invalid: \(message)"
      case .invalidState(let message):
        return "Internal error: \(message)"
      }
    }

    let description = error.localizedDescription
    return description.isEmpty ? String(describing: error) : description
  }
}
