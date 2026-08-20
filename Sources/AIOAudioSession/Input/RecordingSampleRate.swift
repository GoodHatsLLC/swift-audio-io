// © GoodHatsLLC

/// The sample-rate intent for a recording.
///
/// On iOS the hardware sample rate cannot be forced by an app:
/// `setPreferredSampleRate` is a hint the active route is free to ignore, and
/// modern routes mostly do (built-in mics are pinned at 48 kHz, Bluetooth HFP
/// mics at 8–16 kHz, AirPods at 24 kHz). This type makes that reality
/// expressible: ``hardware`` adopts whatever the route actually runs, and
/// ``exact(_:)`` names a delivery target that AudioIO satisfies by conversion
/// when the route differs.
///
/// Codable shape: a keyed container holding exactly one of
/// `{ "hardware": true }` or `{ "exact": { "hz": <Double> } }` (the nested
/// value is ``SampleRate``'s own documented shape). This is a public,
/// persistence-relevant contract.
public enum RecordingSampleRate: Hashable, Sendable, CustomStringConvertible {
  /// Adopt the rate the active route is actually running when capture starts.
  ///
  /// Zero-resample: the pipeline and file inherit the hardware rate observed
  /// at bring-up. "Hardware" means *the hardware at start* — a route change
  /// mid-recording keeps the file at the rate resolved at start and converts,
  /// exactly like an ``exact(_:)`` recording. If the output encoder cannot
  /// write the observed rate (the AAC family above 48 kHz), the nearest
  /// encodable rate is used instead and the substitution is visible in the
  /// recording's ``ResolvedCaptureFormat``.
  case hardware

  /// Deliver exactly this rate.
  ///
  /// AudioIO resamples from the hardware rate when the route runs elsewhere,
  /// so the file always carries this rate regardless of the route.
  case exact(SampleRate)

  /// The exact target, or `nil` for ``hardware``.
  public var exact: SampleRate? {
    switch self {
    case .hardware: nil
    case .exact(let sampleRate): sampleRate
    }
  }

  public var description: String {
    switch self {
    case .hardware: "hardware"
    case .exact(let sampleRate): sampleRate.description
    }
  }
}

extension RecordingSampleRate: Codable {
  private enum CodingKeys: String, CodingKey {
    case hardware
    case exact
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let sampleRate = try container.decodeIfPresent(SampleRate.self, forKey: .exact) {
      self = .exact(sampleRate)
    } else if try container.decodeIfPresent(Bool.self, forKey: .hardware) == true {
      self = .hardware
    } else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription:
            "Expected either {\"hardware\": true} or {\"exact\": {\"hz\": …}}.",
        ),
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .hardware:
      try container.encode(true, forKey: .hardware)
    case .exact(let sampleRate):
      try container.encode(sampleRate, forKey: .exact)
    }
  }
}

#if canImport(AVFoundation)
  /// Request-side capture format: a sample-rate *intent* plus a channel count.
  ///
  /// ``InputConfiguration`` remains the resolved/applied shape — an exact rate
  /// observed or produced by the platform. A `CaptureFormat` is what a caller
  /// *asks for*; it resolves to an `InputConfiguration` at recording bring-up
  /// via ``resolved(hardwareSampleRate:)``.
  public struct CaptureFormat: Hashable, Sendable, CustomStringConvertible {
    public var sampleRate: RecordingSampleRate
    public var channels: ChannelCount

    public init(sampleRate: RecordingSampleRate, channels: ChannelCount) {
      self.sampleRate = sampleRate
      self.channels = channels
    }

    /// Wraps an exact configuration as an ``RecordingSampleRate/exact(_:)``
    /// request.
    public init(_ configuration: InputConfiguration) {
      self.init(
        sampleRate: .exact(configuration.sampleRate),
        channels: configuration.channels,
      )
    }

    /// The already-exact configuration, or `nil` while the rate is
    /// ``RecordingSampleRate/hardware`` and no route has been observed.
    public var exactConfiguration: InputConfiguration? {
      exactSampleRate.map { InputConfiguration(sampleRate: $0, channels: channels) }
    }

    /// The exact requested rate, or `nil` for ``RecordingSampleRate/hardware``.
    public var exactSampleRate: SampleRate? {
      sampleRate.exact
    }

    /// Resolves this request against an observed hardware rate.
    ///
    /// ``RecordingSampleRate/exact(_:)`` requests resolve to themselves — the
    /// hardware rate is irrelevant to what the caller asked for. Encoder
    /// admissibility (the AAC ceiling) is applied by the recording
    /// configuration, which knows the output format; this is intent → exact
    /// only.
    public func resolved(hardwareSampleRate: SampleRate) -> InputConfiguration {
      InputConfiguration(
        sampleRate: sampleRate.exact ?? hardwareSampleRate,
        channels: channels,
      )
    }

    public var description: String {
      "\(channels) \(sampleRate)"
    }
  }

  /// How a recording's capture-format request was satisfied against live
  /// hardware.
  ///
  /// The start-time counterpart of `AudioQualityChange`: it reports what the
  /// route was actually running when the tap was installed (``hardware``) and
  /// what the pipeline converts to and the file is written at
  /// (``processing``) — making an always-on resample, or a low-bandwidth
  /// Bluetooth mic feeding a high-rate file, visible instead of silent.
  public struct ResolvedCaptureFormat: Hashable, Sendable, CustomStringConvertible {
    /// What the route was running when capture was installed.
    public let hardware: InputConfiguration
    /// What the pipeline converts to and the file is written at.
    public let processing: InputConfiguration

    public init(hardware: InputConfiguration, processing: InputConfiguration) {
      self.hardware = hardware
      self.processing = processing
    }

    /// Whether an `AVAudioConverter` sits between hardware and file.
    public var isResampling: Bool {
      hardware.sampleRate != processing.sampleRate
    }

    /// An honest ceiling on captured audio bandwidth.
    ///
    /// A 48 kHz file fed by a 16 kHz Bluetooth HFP mic reports 16 kHz here —
    /// the container rate says nothing about captured bandwidth, this does.
    /// Drive quality badges off this value, not the file's rate.
    public var effectiveSampleRate: SampleRate {
      min(hardware.sampleRate, processing.sampleRate)
    }

    public var description: String {
      isResampling
        ? "\(processing) (converted from \(hardware))"
        : "\(processing) (hardware native)"
    }
  }
#endif
