import AVFoundation
import Foundation
import os

/// Carries the single access unit handed to `AVAudioConverter`. AVAudio's
/// buffers are not `Sendable`, but the input block runs synchronously on the
/// calling thread, so this box is safe.
private final class AACInput: @unchecked Sendable {
  let buffer: AVAudioCompressedBuffer
  var fed = false

  init(_ buffer: AVAudioCompressedBuffer) { self.buffer = buffer }
}

/// Decodes the raw AAC access units that IPCamKit hands us (RFC 3640, one AU
/// per frame) into interleaved Int16 PCM.
///
/// The SDP's `config=` AudioSpecificConfig is required as the decoder's magic
/// cookie. The DVR sends AAC on channel 1, so without this the single-camera
/// view had no sound while G.711 channels worked.
final class AACDecoder: @unchecked Sendable {
  struct Output {
    let samples: [Int16]
    let sampleRate: UInt32
    let channels: Int
  }

  private let lock = NSLock()
  private let log = Logger(subsystem: "com.charith.sentinel", category: "audio")
  private var cookie: Data?
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  private var outputFormat: AVAudioFormat?
  private var sampleRate: UInt32 = 0
  private var channels = 0

  /// Called from the main actor when the SDP arrives. Passing a new cookie
  /// drops the converter so it is rebuilt against the new stream.
  func configure(extraData: Data?) {
    lock.lock()
    defer { lock.unlock() }
    guard cookie != extraData else { return }
    cookie = extraData
    converter = nil
    inputFormat = nil
    outputFormat = nil
    sampleRate = 0
    channels = 0
  }

  func decode(_ data: Data, sampleRate frameRate: UInt32, channels advertised: Int) -> Output? {
    guard !data.isEmpty else { return nil }
    lock.lock()
    defer { lock.unlock() }

    let config = cookie.flatMap(Self.parseAudioSpecificConfig)
    let rate = config?.sampleRate ?? (frameRate > 0 ? frameRate : 16_000)
    let count = config?.channels ?? (advertised > 0 ? advertised : 1)
    guard rate >= 8_000, count == 1 || count == 2 else { return nil }

    if converter == nil || sampleRate != rate || channels != count {
      guard build(rate: rate, channels: count) else { return nil }
    }
    guard let converter, let inputFormat, let outputFormat else { return nil }

    // One access unit per compressed buffer, described as a VBR packet.
    let buffer = AVAudioCompressedBuffer(
      format: inputFormat, packetCapacity: 1, maximumPacketSize: data.count)
    data.copyBytes(to: buffer.data.assumingMemoryBound(to: UInt8.self), count: data.count)
    buffer.byteLength = UInt32(data.count)
    buffer.packetCount = 1
    if let descriptions = buffer.packetDescriptions {
      descriptions[0] = AudioStreamPacketDescription(
        mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))
    }
    let input = AACInput(buffer)

    var samples = [Int16]()
    // The decoder primes with its first frames, so one call can return no data
    // while later calls return the buffered audio. Drain until it is dry.
    for _ in 0..<8 {
      guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8_192) else {
        return nil
      }
      var error: NSError?
      let status = converter.convert(to: output, error: &error) { _, outStatus in
        guard !input.fed else {
          outStatus.pointee = .noDataNow
          return nil
        }
        input.fed = true
        outStatus.pointee = .haveData
        return input.buffer
      }
      if let error {
        log.error("AAC decode failed: \(error.localizedDescription, privacy: .public)")
        return nil
      }
      if status == .error { return nil }
      if output.frameLength > 0, let planes = output.floatChannelData {
        samples.append(contentsOf: Self.interleaved(planes, frames: Int(output.frameLength), channels: count))
      }
      if status != .haveData { break }
    }

    guard !samples.isEmpty else { return nil }
    return Output(samples: samples, sampleRate: rate, channels: count)
  }

  private func build(rate: UInt32, channels count: Int) -> Bool {
    guard let cookie else { return false }

    var description = AudioStreamBasicDescription(
      mSampleRate: Float64(rate),
      mFormatID: kAudioFormatMPEG4AAC,
      mFormatFlags: 0,
      mBytesPerPacket: 0,
      mFramesPerPacket: 1_024,
      mBytesPerFrame: 0,
      mChannelsPerFrame: UInt32(count),
      mBitsPerChannel: 0,
      mReserved: 0)
    guard
      let input = AVAudioFormat(streamDescription: &description),
      let output = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(rate),
        channels: AVAudioChannelCount(count), interleaved: false),
      let converter = AVAudioConverter(from: input, to: output)
    else { return false }

    converter.magicCookie = cookie
    self.converter = converter
    self.inputFormat = input
    self.outputFormat = output
    sampleRate = rate
    channels = count
    return true
  }

  private static func interleaved(
    _ planes: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int, channels: Int
  ) -> [Int16] {
    var samples = [Int16](repeating: 0, count: frames * channels)
    for channel in 0..<channels {
      let plane = planes[channel]
      for frame in 0..<frames {
        let value = max(-1, min(1, plane[frame]))
        samples[frame * channels + channel] = Int16(value * 32_767)
      }
    }
    return samples
  }

  // MARK: - AudioSpecificConfig (ISO/IEC 14496-3)

  private struct AudioSpecificConfig {
    let sampleRate: UInt32
    let channels: Int
  }

  private static let sampleRates: [UInt32] = [
    96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050,
    16_000, 12_000, 11_025, 8_000, 7_350,
  ]

  /// Reads the object type, sample-rate index and channel configuration from
  /// the ASC. Only mono/stereo are usable by the player; other layouts fall
  /// back to what the SDP advertised.
  private static func parseAudioSpecificConfig(_ data: Data) -> AudioSpecificConfig? {
    let bytes = [UInt8](data)
    guard bytes.count >= 2 else { return nil }
    var reader = BitReader(bytes: bytes)
    let objectType = reader.read(5)
    if objectType == 31 { _ = reader.read(6) }
    let index = reader.read(4)
    let rate: UInt32?
    if index == 0xF {
      rate = UInt32(reader.read(24))
    } else {
      rate = index < sampleRates.count ? sampleRates[index] : nil
    }
    let channelConfig = reader.read(4)
    guard let rate, rate >= 8_000, channelConfig == 1 || channelConfig == 2 else { return nil }
    return AudioSpecificConfig(sampleRate: rate, channels: channelConfig)
  }

  private struct BitReader {
    let bytes: [UInt8]
    private var bit = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) -> Int {
      var value = 0
      for _ in 0..<count {
        let index = bit >> 3
        guard index < bytes.count else { return 0 }
        let shift = 7 - (bit & 7)
        value = (value << 1) | Int((bytes[index] >> shift) & 1)
        bit += 1
      }
      return value
    }
  }
}
