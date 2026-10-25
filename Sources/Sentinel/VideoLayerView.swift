import AVFoundation
import SwiftUI

struct VideoLayerView: NSViewRepresentable {
  let surface: VideoSurface

  func makeNSView(context: Context) -> VideoLayerHost {
    VideoLayerHost(surface.layer)
  }

  func updateNSView(_ nsView: VideoLayerHost, context: Context) {}
}

/// AppKit manages the backing layer's frame; setting `view.layer` directly would not.
final class VideoLayerHost: NSView {
  private let videoLayer: AVSampleBufferDisplayLayer

  init(_ layer: AVSampleBufferDisplayLayer) {
    videoLayer = layer
    super.init(frame: .zero)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { nil }

  override func makeBackingLayer() -> CALayer { videoLayer }

  /// The video layer is display-only: SwiftUI's controls layered over it (the
  /// popover's tap-to-open-camera button, camera page buttons) must get the
  /// clicks instead of this view swallowing them.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
