import AVFoundation
import Foundation
import IPCamKit
import os

/// Plays one camera's audio track through the system output. AAC (channel 1)
/// is decoded with an `AVAudioConverter`; G.711 A-law/µ-law and L16 are
/// expanded directly. All become interleaved PCM in a small ring buffer feeding
/// an `AVAudioSourceNode`. Only a maximized camera enables it — grid tiles and
/// the menu bar stay silent.
final class AudioPlayer: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let ring = PCM16RingBuffer(capacity: 32_000)  // 2 s at 16 kHz mono
  private let lock = NSLock()
  private let engineLock = NSLock()
  private let aac = AACDecoder()
  private let log = Logger(subsystem: "com.charith.sentinel", category: "audio")
  private var _enabled = true
  private var running = false
  private var format: AVAudioFormat?
  private var source: AVAudioSourceNode?

  var enabled: Bool {
    get { lock.lock(); defer { lock.unlock() }; return _enabled }
    set { lock.lock(); _enabled = newValue; lock.unlock() }
  }

  /// Hands the player the SDP's audio description. Only AAC needs it (its
  /// AudioSpecificConfig is required to build a decoder).
  func configure(_ track: AudioTrack?) {
    guard let track else { return }
    if case .aac = track.codec {
      aac.configure(extraData: track.extraData)
    }
  }

  func start() {
    lock.lock()
    running = true
    lock.unlock()
  }

  func stop() {
    lock.lock()
    running = false
    lock.unlock()
    engineLock.lock()
    if engine.isRunning {
      engine.stop()
    }
    engine.reset()
    // Reset format/source so the engine can be (re)started on the next frame
    // when the player is reused. Without this, prepareEngine's guard on
    // `format == nil` prevents engine.start() from ever running again.
    format = nil
    source = nil
    engineLock.unlock()
  }

  func enqueue(_ frame: PublicAudioFrame) {
    lock.lock()
    let active = running
    lock.unlock()
    guard active else { return }

    switch frame.codec {
    case .aac:
      // Channel 1 on the DVR is AAC; everything else is G.711.
      guard
        let decoded = aac.decode(
          frame.data, sampleRate: frame.sampleRate, channels: Int(frame.channels ?? 1))
      else { return }
      prepareEngine(sampleRate: decoded.sampleRate, channels: decoded.channels)
      ring.append(decoded.samples)

    case .pcma, .pcmu, .l16:
      let channels = Int(frame.channels ?? 1)
      guard channels == 1 || channels == 2 else { return }
      let samples: [Int16]
      switch frame.codec {
      case .pcma: samples = Self.decodeALaw(frame.data)
      case .pcmu: samples = Self.decodeULaw(frame.data)
      case .l16: samples = Self.decodeL16(frame.data)
      default: return
      }
      guard !samples.isEmpty else { return }
      prepareEngine(sampleRate: frame.sampleRate, channels: channels)
      ring.append(samples)

    case .g722, .g723, .other:
      return  // not sent by this recorder
    }
  }

  /// The source node needs the track's format up front; build it on the first
  /// frame (sample rate / channel count come from the SDP via that frame).
  private func prepareEngine(sampleRate: UInt32, channels: Int) {
    engineLock.lock()
    defer { engineLock.unlock() }
    guard format == nil, sampleRate >= 8000, channels == 1 || channels == 2 else { return }
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
        channels: AVAudioChannelCount(channels), interleaved: false)
    else { return }
    self.format = format

    let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, buffers -> OSStatus
      in
      self?.render(frameCount: Int(frameCount), buffers: buffers)
      return noErr
    }
    engine.mainMixerNode.outputVolume = 1
    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: format)
    do {
      try engine.start()
      self.source = source
    } catch {
      log.error("audio engine failed to start: \(String(describing: error), privacy: .public)")
    }
  }

  /// Audio render thread: drain the ring, convert Int16 to float. While muted
  /// the samples are still consumed (so un-muting never replays a backlog).
  private func render(frameCount: Int, buffers: UnsafeMutablePointer<AudioBufferList>) {
    let list = UnsafeMutableAudioBufferListPointer(buffers)
    let pointers = list.compactMap { $0.mData?.assumingMemoryBound(to: Float32.self) }
    guard !pointers.isEmpty else { return }
    let isOn = enabled

    if pointers.count == 1 {
      let out = pointers[0]
      for frame in 0..<frameCount {
        let sample = ring.pop() ?? 0
        out[frame] = isOn ? Float32(sample) / 32_768 : 0
      }
    } else if pointers.count >= 2 {
      // Ring holds interleaved pairs; output buffers are one plane per channel.
      let left = pointers[0]
      let right = pointers[1]
      for frame in 0..<frameCount {
        let l = ring.pop() ?? 0
        let r = ring.pop() ?? 0
        left[frame] = isOn ? Float32(l) / 32_768 : 0
        right[frame] = isOn ? Float32(r) / 32_768 : 0
      }
    }
  }

  // MARK: G.711 → linear PCM (ITU-T tables, same expansion as Sun's g711.c)

  static func decodeALaw(_ data: Data) -> [Int16] {
    var out = [Int16](repeating: 0, count: data.count)
    for (index, byte) in data.enumerated() {
      let value = byte ^ 0x55
      let segment = Int((value & 0x70) >> 4)
      var magnitude = Int((value & 0x0F) << 4)
      if segment == 0 {
        magnitude += 8
      } else if segment == 1 {
        magnitude += 0x108
      } else {
        magnitude = (magnitude + 0x108) << (segment - 1)
      }
      out[index] = Int16((value & 0x80) == 0 ? magnitude : -magnitude)
    }
    return out
  }

  static func decodeULaw(_ data: Data) -> [Int16] {
    var out = [Int16](repeating: 0, count: data.count)
    for (index, byte) in data.enumerated() {
      let value = ~byte
      var t = Int((value & 0x0F) << 3) + 0x84
      t <<= Int((value & 0x70) >> 4)
      out[index] = Int16((value & 0x80) != 0 ? (0x84 - t) : (t - 0x84))
    }
    return out
  }

  static func decodeL16(_ data: Data) -> [Int16] {
    var out = [Int16]()
    out.reserveCapacity(data.count / 2)
    var iterator = data.makeIterator()
    while let high = iterator.next() {
      guard let low = iterator.next() else { break }
      out.append(Int16(bitPattern: UInt16(high) << 8 | UInt16(low)))
    }
    return out
  }
}

/// Minimal lock-protected PCM16 ring. Producer: the RTSP receive task.
/// Consumer: the audio render thread. When full, the oldest samples drop.
final class PCM16RingBuffer: @unchecked Sendable {
  private var storage: [Int16]
  private var readIndex = 0
  private var count = 0
  private let lock = NSLock()

  init(capacity: Int) {
    storage = [Int16](repeating: 0, count: max(capacity, 256))
  }

  func append(_ samples: [Int16]) {
    guard !samples.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    for sample in samples {
      if count == storage.count {
        readIndex = (readIndex + 1) % storage.count
        count -= 1
      }
      storage[(readIndex + count) % storage.count] = sample
      count += 1
    }
  }

  func pop() -> Int16? {
    lock.lock()
    defer { lock.unlock() }
    guard count > 0 else { return nil }
    let value = storage[readIndex]
    readIndex = (readIndex + 1) % storage.count
    count -= 1
    return value
  }
}

/// Thread-safe hand-off between the main actor (which swaps players as pages
/// open and close) and the RTSP task (which enqueues frames from anywhere).
final class AudioBox: @unchecked Sendable {
  private let lock = NSLock()
  private var current: AudioPlayer?

  var player: AudioPlayer? {
    get { lock.lock(); defer { lock.unlock() }; return current }
    set { lock.lock(); current = newValue; lock.unlock() }
  }

  func enqueue(_ frame: PublicAudioFrame) {
    lock.lock()
    let target = current
    lock.unlock()
    target?.enqueue(frame)
  }
}
