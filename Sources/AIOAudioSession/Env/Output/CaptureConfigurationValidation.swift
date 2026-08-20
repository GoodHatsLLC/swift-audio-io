// © GoodHatsLLC

/// A way in which a capture configuration cannot be written as described.
///
/// Every case is decidable from the configuration alone — no audio session, no
/// route, no activation. That is the point: a caller can offer a combination in
/// a picker, or reject it, before anything touches the microphone.
public enum CaptureConfigurationIssue: Hashable, Sendable, CustomStringConvertible {
  /// The capture sample rate is one the format's encoder cannot write.
  ///
  /// The AAC family is the common case: it tops out at 48 kHz, so a 96 kHz or
  /// 192 kHz capture cannot be encoded to `m4a` or `aac` at all.
  case unsupportedSampleRate(
    SampleRate,
    fileFormat: FileFormat,
    supported: [SampleRate],
  )

  /// The capture channel count exceeds what the format can carry.
  case unsupportedChannelCount(
    Int,
    fileFormat: FileFormat,
    maximum: Int,
  )

  /// A bit depth was supplied that this format's writer does not use.
  ///
  /// When `supported` is empty the format has no sample width to choose at all
  /// — see ``FileFormat/usesBitDepth`` — and the only valid value is `nil`.
  case unsupportedBitDepth(
    BitDepth,
    fileFormat: FileFormat,
    supported: [BitDepth],
  )

  /// No bit depth was supplied for a format whose writer needs one.
  case missingBitDepth(fileFormat: FileFormat, supported: [BitDepth])

  public var description: String {
    switch self {
    case .unsupportedSampleRate(let sampleRate, let fileFormat, let supported):
      let list = supported.map(\.description).joined(separator: ", ")
      return
        "\(fileFormat) cannot encode \(sampleRate)."
        + (list.isEmpty ? "" : " Supported: \(list).")
    case .unsupportedChannelCount(let channelCount, let fileFormat, let maximum):
      return "\(fileFormat) supports at most \(maximum) channels; \(channelCount) requested."
    case .unsupportedBitDepth(let bitDepth, let fileFormat, let supported):
      guard !supported.isEmpty else {
        return
          "\(fileFormat) has no selectable bit depth — it is a lossy format whose writer "
          + "ignores one — but \(bitDepth) was supplied. Use nil."
      }
      let list = supported.map(\.description).joined(separator: ", ")
      return "\(fileFormat) does not support \(bitDepth). Supported: \(list)."
    case .missingBitDepth(let fileFormat, let supported):
      let list = supported.map(\.description).joined(separator: ", ")
      return "\(fileFormat) requires a bit depth. Supported: \(list)."
    }
  }
}

/// The result of checking a capture configuration for coherence.
public struct CaptureConfigurationValidation: Hashable, Sendable, CustomStringConvertible {
  public init(issues: [CaptureConfigurationIssue]) {
    self.issues = issues
  }

  public let issues: [CaptureConfigurationIssue]

  public var isValid: Bool { issues.isEmpty }

  public static let valid = CaptureConfigurationValidation(issues: [])

  public var description: String {
    guard !issues.isEmpty else { return "valid" }
    return issues.map(\.description).joined(separator: "\n")
  }
}

extension OutputConfiguration {
  /// Validates this output encoding against the format the capture will
  /// deliver, without touching an audio session.
  ///
  /// Input and output are chosen independently — a 96 kHz microphone request
  /// and an `m4a` output are each individually reasonable — so this is where
  /// the combination gets checked. Call it before activation, not after a
  /// writer fails to open.
  public func validate(
    against inputFormat: InputConfiguration,
  ) -> CaptureConfigurationValidation {
    var issues = validateOutputOnly().issues

    if !fileFormat.supports(sampleRate: inputFormat.sampleRate) {
      issues.append(
        .unsupportedSampleRate(
          inputFormat.sampleRate,
          fileFormat: fileFormat,
          supported: fileFormat.compatibleCommonSampleRates,
        ),
      )
    }

    if !fileFormat.supportsRecordingChannelCount(inputFormat.channels.count) {
      issues.append(
        .unsupportedChannelCount(
          inputFormat.channels.count,
          fileFormat: fileFormat,
          maximum: fileFormat.maximumRecordingChannelCount,
        ),
      )
    }

    return CaptureConfigurationValidation(issues: issues)
  }

  /// Validates everything decidable before a sample rate exists: the output
  /// encoding plus the channel count.
  ///
  /// This is ``validate(against:)`` minus the sample-rate check, for
  /// ``RecordingSampleRate/hardware`` requests — their rate is resolved (and
  /// clamped to an encodable value) at recording bring-up, so no rate issue is
  /// decidable, or possible, ahead of time.
  public func validate(
    againstChannels channels: ChannelCount,
  ) -> CaptureConfigurationValidation {
    var issues = validateOutputOnly().issues

    if !fileFormat.supportsRecordingChannelCount(channels.count) {
      issues.append(
        .unsupportedChannelCount(
          channels.count,
          fileFormat: fileFormat,
          maximum: fileFormat.maximumRecordingChannelCount,
        ),
      )
    }

    return CaptureConfigurationValidation(issues: issues)
  }

  /// The checks that need no capture format: whether the bit depth is one this
  /// format's writer uses.
  func validateOutputOnly() -> CaptureConfigurationValidation {
    let supported = fileFormat.supportedBitDepths
    switch bitDepth {
    case .some(let bitDepth) where !supported.contains(bitDepth):
      return CaptureConfigurationValidation(
        issues: [.unsupportedBitDepth(bitDepth, fileFormat: fileFormat, supported: supported)],
      )
    case .none where fileFormat.usesBitDepth:
      return CaptureConfigurationValidation(
        issues: [.missingBitDepth(fileFormat: fileFormat, supported: supported)],
      )
    default:
      return .valid
    }
  }
}

extension FileFormat {
  /// The bit depth a caller should start from for this format: `nil` when the
  /// format has none to choose, and otherwise the lowest supported one.
  ///
  /// Useful for reconciling a stored selection after the format changes.
  public var defaultBitDepth: BitDepth? {
    supportedBitDepths.first
  }
}
