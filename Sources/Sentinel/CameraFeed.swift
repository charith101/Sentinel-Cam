import AVFoundation
import AppKit
import CoreImage
import IPCamKit
import Observation

enum FeedState: Equatable, Sendable {
  case idle
  case connecting
  case live
  case failed(String)
}

@MainActor
final class VideoSurface {
  let layer = AVSampleBufferDisplayLayer()
  lazy var renderer = VideoRenderer(layer: layer)

  init() {
    // The DVR encodes 16:9 content into unusual 960×1080 pixels; stretching to the
    // container (like VLC's default) is what looks right on screen.
    layer.videoGravity = .resize
    layer.backgroundColor = CGColor.black
  }

  func setStretching(_ stretching: Bool) {
    layer.videoGravity = stretching ? .resize : .resizeAspect
  }

  /// Drops the last decoded frame instantly. A stopped or reconnecting stream
  /// must never show its old picture: a frozen image reads as "live" to the
  /// eye and that is exactly the ambiguity a viewer cannot resolve.
  func discardFrame() {
    layer.sampleBufferRenderer.flush(removingDisplayedImage: true)
  }
}

@MainActor
@Observable
final class CameraFeed: Identifiable {
  nonisolated let cameraID: Int
  nonisolated var id: Int { cameraID }

  let surface = VideoSurface()
  private static let ciContext = CIContext()
  private(set) var state: FeedState = .idle
  private(set) var detail = ""
  private(set) var fps = 0
  /// Whether the camera's RTSP session reports an audio track (nil = unknown
  /// until the first connect).
  private(set) var audioAvailable: Bool?
  /// True while this camera's audio is allowed to reach the speakers; the
  /// maximized camera page sets it, everything else leaves it off. It survives
  /// reconnects and visibility pauses so sound resumes with the picture.
  private(set) var audioEnabled = false

  private let store: ConfigStore
  private let audio = AudioBox()
  private var stream: CameraStream?
  private var audioTrack: AudioTrack?

  var isStreaming: Bool { stream != nil }

  init(cameraID: Int, store: ConfigStore) {
    self.cameraID = cameraID
    self.store = store
  }

  func start() {
    guard stream == nil else { return }
    state = .connecting
    detail = ""
    fps = 0

    guard let target = store.config.target(for: cameraID, secrets: store.secrets) else {
      state = .failed("This camera is no longer in your setup.")
      return
    }
    if let camera = store.config.camera(cameraID) {
      surface.setStretching(camera.scale == .stretch)
    }

    let audioBox = audio
    let stream = CameraStream(
      url: target.url,
      credentials: target.credentials,
      transport: target.transport,
      renderer: surface.renderer,
      onEvent: { [weak self] event in
        Task { @MainActor in self?.apply(event) }
      },
      onAudio: { frame in audioBox.enqueue(frame) })
    stream.start()
    self.stream = stream
    // A reconnect or visibility pause must not silently lose the user's sound
    // choice: rebuild the player if this camera is the maximized one.
    if audioEnabled { ensureAudioPlayer() }
  }

  func stop() {
    stream?.stop()
    stream = nil
    surface.discardFrame()
    state = .idle
    fps = 0
    audio.player?.stop()
    audio.player = nil
  }

  func restart() {
    stop()
    start()
  }

  func setStretching(_ stretching: Bool) {
    surface.setStretching(stretching)
  }

  /// Gates this camera's audio to the speakers. Frames keep flowing into the
  /// player either way; muting just silences output so un-muting is instant
  /// and the engine isn't torn down and rebuilt on every toggle.
  func setAudioEnabled(_ enabled: Bool) {
    audioEnabled = enabled
    if enabled {
      ensureAudioPlayer()
      audio.player?.enabled = true
    } else {
      audio.player?.enabled = false
    }
  }

  private func ensureAudioPlayer() {
    guard audio.player == nil else { return }
    let player = AudioPlayer()
    player.configure(audioTrack)
    player.start()
    audio.player = player
  }

  /// The decoder's current frame as PNG, or nil before the first frame.
  private func snapshotPNG() -> Data? {
    guard #available(macOS 14.4, *) else { return nil }
    let renderer = surface.layer.sampleBufferRenderer
    guard let pixelBuffer = renderer.displayedPixelBuffer() else { return nil }
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = Self.ciContext.createCGImage(image, from: image.extent) else { return nil }
    return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
  }

  private var snapshotsSupported: Bool {
    if #available(macOS 14.4, *) { return true }
    return false
  }

  @MainActor
  func snapshot() {
    guard snapshotsSupported else {
      store.toasts.show(
        Toast(
          "Snapshots need macOS 14.4 or later", detail: "Update macOS to save frames.",
          severity: .warning))
      return
    }
    guard let data = snapshotPNG() else {
      store.toasts.show(
        Toast("No frame to save yet", detail: "Wait for the camera to go live.", severity: .warning))
      return
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let safeName =
      store.config.name(for: cameraID)
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
    let filename = "\(safeName) \(formatter.string(from: .now)).png"
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = filename
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        try data.write(to: url)
        self.store.toasts.show(
          Toast("Snapshot saved", detail: url.lastPathComponent, severity: .success))
      } catch {
        self.store.toasts.show(
          Toast(
            "Couldn't save snapshot", detail: error.localizedDescription, severity: .error))
      }
    }
  }

  /// Copies the current frame to the clipboard — the quick "clip" path when a
  /// file dialog would be overkill (chat, notes, a bug report).
  @MainActor
  func copySnapshot() {
    guard snapshotsSupported else {
      store.toasts.show(
        Toast(
          "Snapshots need macOS 14.4 or later", detail: "Update macOS to copy frames.",
          severity: .warning))
      return
    }
    guard let data = snapshotPNG() else {
      store.toasts.show(
        Toast("No frame to copy yet", detail: "Wait for the camera to go live.", severity: .warning))
      return
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if pasteboard.setData(data, forType: .png) {
      store.toasts.show(
        Toast("Snapshot copied", detail: "Paste it anywhere.", severity: .success))
    } else {
      store.toasts.show(Toast("Couldn't copy snapshot", severity: .error))
    }
  }

  private func apply(_ event: CameraEvent) {
    switch event.kind {
    case .connecting:
      // A reconnect attempt must clear the last picture the decoder held;
      // the connecting pill is only honest if the box beneath it is dark.
      surface.discardFrame()
      state = .connecting
    case .live(let label):
      state = .live
      detail = label
    case .fps(let value):
      fps = value
    case .failed(let message):
      surface.discardFrame()
      state = .failed(message)
      fps = 0
    case .audioTrack(let info):
      audioTrack = info
      audioAvailable = info != nil
      audio.player?.configure(info)
    }
  }
}
