import AVFoundation
import CoreMedia
import Foundation
import IPCamKit
import os

/// What the SDP advertised for the audio track. Carries the AAC
/// AudioSpecificConfig so the player can build a decoder before frames arrive.
struct AudioTrack: Sendable {
  let codec: PublicAudioCodec
  let sampleRate: UInt32
  let channels: Int
  let extraData: Data?
}

struct CameraEvent: Sendable {
  enum Kind: Sendable {
    case connecting
    case live(String)
    case fps(Int)
    case failed(String)
    case audioTrack(AudioTrack?)
  }
  let kind: Kind
}

enum StreamError: Error {
  case noVideo
  case ended
}

/// Builds VideoToolbox samples from IPCamKit frames and feeds a display layer.
/// Called only from the stream task.
final class VideoRenderer: @unchecked Sendable {
  private let layer: AVSampleBufferDisplayLayer
  private var codec: VideoCodec = .h265
  private var format: CMVideoFormatDescription?
  private var waitingForKeyframe = true

  init(layer: AVSampleBufferDisplayLayer) {
    self.layer = layer
  }

  func configure(codec: VideoCodec, sps: Data, pps: Data, vps: Data?) {
    self.codec = codec
    format = Self.formatDescription(codec: codec, sps: sps, pps: pps, vps: vps)
    waitingForKeyframe = true
  }

  @discardableResult
  func enqueue(_ frame: PublicVideoFrame) -> Bool {
    if format == nil, let sps = frame.sps, let pps = frame.pps {
      format = Self.formatDescription(codec: codec, sps: sps, pps: pps, vps: frame.vps)
    }
    guard let format else { return false }

    let renderer = layer.sampleBufferRenderer
    if renderer.status == .failed {
      renderer.flush(removingDisplayedImage: false, completionHandler: nil)
      waitingForKeyframe = true
      return false
    }
    if waitingForKeyframe {
      guard frame.isKeyframe else { return false }
      waitingForKeyframe = false
    }
    guard let sample = Self.sampleBuffer(frame, codec: codec, format: format) else { return false }
    renderer.enqueue(sample)
    return true
  }

  private static func formatDescription(
    codec: VideoCodec, sps: Data, pps: Data, vps: Data?
  ) -> CMVideoFormatDescription? {
    var format: CMVideoFormatDescription?
    let status: OSStatus
    switch codec {
    case .h264:
      let spsBytes = Array(sps)
      let ppsBytes = Array(pps)
      guard !spsBytes.isEmpty, !ppsBytes.isEmpty else { return nil }
      status = spsBytes.withUnsafeBufferPointer { spsPtr in
        ppsBytes.withUnsafeBufferPointer { ppsPtr in
          guard let spsBase = spsPtr.baseAddress, let ppsBase = ppsPtr.baseAddress else {
            return -1
          }
          var pointers = [spsBase, ppsBase]
          var sizes = [spsBytes.count, ppsBytes.count]
          return CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: nil, parameterSetCount: 2, parameterSetPointers: &pointers,
            parameterSetSizes: &sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }
      }
    case .h265:
      let vpsBytes = Array(vps ?? Data())
      let spsBytes = Array(sps)
      let ppsBytes = Array(pps)
      guard !spsBytes.isEmpty, !ppsBytes.isEmpty else { return nil }
      status = vpsBytes.withUnsafeBufferPointer { vpsPtr in
        spsBytes.withUnsafeBufferPointer { spsPtr in
          ppsBytes.withUnsafeBufferPointer { ppsPtr in
            guard let spsBase = spsPtr.baseAddress, let ppsBase = ppsPtr.baseAddress else {
              return -1
            }
            var pointers: [UnsafePointer<UInt8>] = []
            var sizes: [Int] = []
            if let base = vpsPtr.baseAddress, !vpsBytes.isEmpty {
              pointers.append(base)
              sizes.append(vpsBytes.count)
            }
            pointers.append(spsBase)
            sizes.append(spsBytes.count)
            pointers.append(ppsBase)
            sizes.append(ppsBytes.count)
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
              allocator: nil, parameterSetCount: pointers.count,
              parameterSetPointers: &pointers, parameterSetSizes: &sizes,
              nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
          }
        }
      }
    }
    return status == noErr ? format : nil
  }

  private static func sampleBuffer(
    _ frame: PublicVideoFrame, codec: VideoCodec, format: CMVideoFormatDescription
  ) -> CMSampleBuffer? {
    // AVCC: 4-byte length before each NAL. Parameter sets live in the format description.
    var avcc = Data()
    for nal in frame.nalus {
      guard !nal.isEmpty else { continue }
      let firstByte = nal[nal.startIndex]
      let nalType: UInt8 = codec == .h264 ? (firstByte & 0x1F) : ((firstByte >> 1) & 0x3F)
      if codec == .h264 && (6...9).contains(nalType) { continue }
      if codec == .h265 && (32...40).contains(nalType) { continue }
      var length = UInt32(nal.count).bigEndian
      withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
      avcc.append(nal)
    }
    guard !avcc.isEmpty else { return nil }

    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
        customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0,
        blockBufferOut: &block) == noErr, let block
    else { return nil }
    CMBlockBufferAssureBlockMemory(block)
    guard let base = avcc.withUnsafeBytes({ $0.baseAddress }) else { return nil }
    _ = avcc.withUnsafeBytes { _ in
      CMBlockBufferReplaceDataBytes(
        with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
    }

    var sample: CMSampleBuffer?
    var size = avcc.count
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    guard
      CMSampleBufferCreateReady(
        allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
      let sample
    else { return nil }

    guard
      let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
      let attachments = array as NSArray?,
      attachments.count > 0,
      let dict = attachments[0] as? NSMutableDictionary
    else { return sample }
    dict[kCMSampleAttachmentKey_DisplayImmediately] = true
    if !frame.isKeyframe { dict[kCMSampleAttachmentKey_NotSync] = true }
    return sample
  }
}

/// One RTSP connection + decode pipeline, with reconnect backoff.
final class CameraStream: @unchecked Sendable {
  private let url: String
  private let credentials: Credentials?
  private let transport: Transport
  private let renderer: VideoRenderer
  private let onEvent: @Sendable (CameraEvent) -> Void
  private let onAudio: @Sendable (PublicAudioFrame) -> Void
  private let log = Logger(subsystem: "com.charith.sentinel", category: "camera")
  private var task: Task<Void, Never>?

  init(
    url: String, credentials: Credentials?, transport: Transport, renderer: VideoRenderer,
    onEvent: @escaping @Sendable (CameraEvent) -> Void,
    onAudio: @escaping @Sendable (PublicAudioFrame) -> Void
  ) {
    self.url = url
    self.credentials = credentials
    self.transport = transport
    self.renderer = renderer
    self.onEvent = onEvent
    self.onAudio = onAudio
  }

  func start() {
    guard task == nil else { return }
    task = Task.detached(priority: .userInitiated) { [self] in await run() }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  private func run() async {
    var backoff = Duration.milliseconds(400)
    var authFailures = 0
    while !Task.isCancelled {
      onEvent(CameraEvent(kind: .connecting))
      let session = RTSPClientSession(
        url: url, credentials: credentials, transport: transport,
        onDiagnostic: { [log] diagnostic in
          let severity = String(describing: diagnostic.severity)
          log.info("\(severity, privacy: .public): \(diagnostic.message, privacy: .public)")
        })

      do {
        let description = try await session.start()
        guard let video = description.video else { throw StreamError.noVideo }
        if let sps = video.sps, let pps = video.pps {
          renderer.configure(codec: video.codec, sps: sps, pps: pps, vps: video.vps)
        }
        let resolution = video.resolution
        let label = "\(video.codec) \(resolution.map { "\($0.width)×\($0.height)" } ?? "live")"
        log.notice("connected: \(label, privacy: .public)")
        let track = description.audio.map {
          AudioTrack(
            codec: $0.codec, sampleRate: $0.sampleRate,
            channels: Int($0.channels ?? 1), extraData: $0.extraData)
        }
        onEvent(CameraEvent(kind: .audioTrack(track)))
        backoff = .milliseconds(400)
        authFailures = 0

        var frames = 0
        var announced = false
        var lastTick = ContinuousClock.now

        try await withTaskCancellationHandler {
          for try await item in session.frames() {
            if Task.isCancelled { break }
            if case .video(let frame) = item {
              if renderer.enqueue(frame), !announced {
                announced = true
                onEvent(CameraEvent(kind: .live(label)))
              }
              frames += 1
            } else if case .audio(let frame) = item {
              onAudio(frame)
            }
            let now = ContinuousClock.now
            if now - lastTick >= .seconds(1) {
              onEvent(CameraEvent(kind: .fps(frames)))
              frames = 0
              lastTick = now
            }
          }
        } onCancel: {
          Task { await session.stop() }
        }

        await session.stop()
        if Task.isCancelled { break }
        throw StreamError.ended
      } catch {
        await session.stop()
        if Task.isCancelled { break }
        log.error("stream failed: \(String(describing: error), privacy: .public)")

        // A wrong password will never fix itself. Stop after three attempts so
        // the camera isn't hammered (and eventually locked out) forever.
        if Self.isAuthenticationFailure(error) {
          authFailures += 1
          if authFailures >= 3 {
            onEvent(
              CameraEvent(
                kind: .failed(
                  "The camera rejected the username or password. Check it in Settings, then retry."
                )))
            break
          }
        }
        onEvent(CameraEvent(kind: .failed(String(describing: error))))
      }

      if Task.isCancelled { break }
      // Jitter keeps several cameras from reconnecting in lockstep after a
      // recorder reboot or a Wi-Fi blip.
      let jitter = Duration.milliseconds(Int.random(in: 0...300))
      try? await Task.sleep(for: backoff + jitter)
      backoff = min(backoff * 2, .seconds(8))
    }
  }

  private static func isAuthenticationFailure(_ error: Error) -> Bool {
    guard let rtsp = error as? RTSPError else { return false }
    if case .authenticationFailed = rtsp { return true }
    return false
  }
}
