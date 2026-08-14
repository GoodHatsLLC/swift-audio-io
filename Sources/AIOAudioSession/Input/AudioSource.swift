// © GoodHatsLLC

#if canImport(AVFoundation)

  #if os(iOS)
    public import AVFAudio
    public import Tools

    public struct AudioSource: Hashable, Sendable, Identifiable, CustomStringConvertible, Comparable
    {
      public enum PreferenceError: AudioError {
        case setPreferredPolarPatternFailed(sourceID: String, pattern: String, error: ErrorContext)

        public var description: String {
          switch self {
          case .setPreferredPolarPatternFailed(let sourceID, let pattern, let error):
            "Failed to set preferred polar pattern '\(pattern)' for source \(sourceID): \(error)"
          }
        }
      }

      /// AVFoundation escape hatch. Consumers should obtain `AudioSource` values
      /// through ``AudioInputConfigurationCapabilities/sourceOptions`` rather
      /// than construct them; this accessor exists for AudioIO implementation
      /// code that must drop down to the underlying AVAudioSession objects.
      @_spi(AVFoundation)
      public let avAudio: AVAudioSessionDataSourceDescription

      @_spi(AVFoundation)
      public init(avAudio: AVAudioSessionDataSourceDescription) {
        self.avAudio = avAudio
      }

      public var id: String {
        avAudio.dataSourceID.stringValue
      }

      public var name: String {
        avAudio.dataSourceName
      }

      public var supportedPolarPatterns: [PolarPattern] {
        (avAudio.supportedPolarPatterns ?? []).map(PolarPattern.init(avAudio:))
      }

      public var description: String {
        [
          avAudio.location.map(\.rawValue) ?? "",
          avAudio.orientation.map(\.rawValue) ?? "",
          avAudio.supportedPolarPatterns.map {
            "(\($0.map(\.rawValue).joined(separator: ", ")))"
          }
            ?? "",
        ].joined(separator: " ")
      }

      /// Selects the source's polar pattern, skipping the write when the same
      /// pattern is already preferred. See ``AudioSessionPreferenceWrite`` for
      /// why an unconditional write is not free.
      public func set(preferredPolarPattern: PolarPattern) throws(PreferenceError) {
        do {
          try AudioSessionPreferenceWrite.perform(
            AVAudioSession.PolarPattern?.some(preferredPolarPattern.avAudio),
            whenNot: avAudio.preferredPolarPattern,
          ) { _ in try avAudio.setPreferredPolarPattern(preferredPolarPattern.avAudio) }
        } catch {
          throw .setPreferredPolarPatternFailed(
            sourceID: id,
            pattern: preferredPolarPattern.avAudio.rawValue,
            error: ErrorContext(error),
          )
        }
      }

      public static func < (lhs: AudioSource, rhs: AudioSource) -> Bool {
        lhs.name < rhs.name
      }

      public var hasStereo: Bool {
        (avAudio.supportedPolarPatterns ?? []).contains {
          $0 == .stereo
        }
      }
    }

    extension AudioSource {
      public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.avAudio.dataSourceID == rhs.avAudio.dataSourceID
      }

      public func hash(into hasher: inout Hasher) {
        hasher.combine(avAudio.dataSourceID)
      }
    }

    public struct PolarPattern: Hashable, Sendable, Identifiable {
      /// AVFoundation escape hatch. Consumers should use the named static
      /// members (`.omnidirectional`, `.cardioid`, `.subcardioid`, `.stereo`)
      /// rather than construct values directly.
      @_spi(AVFoundation)
      public let avAudio: AVAudioSession.PolarPattern

      @_spi(AVFoundation)
      public init(avAudio: AVAudioSession.PolarPattern) {
        self.avAudio = avAudio
      }

      public var id: String {
        avAudio.rawValue
      }

      public var name: String {
        avAudio.rawValue
      }

      public static let omnidirectional: PolarPattern = .init(avAudio: .omnidirectional)
      public static let cardioid: PolarPattern = .init(avAudio: .cardioid)
      public static let subcardioid: PolarPattern = .init(avAudio: .subcardioid)
      /// If you select a data source with AVAudioSessionPolarPatternStereo, then you must call setPreferredInputOrientation:error: on your Audio Session so that left and right are presented from the correct directions.
      public static let stereo: PolarPattern = .init(avAudio: .stereo)
    }
  #endif
#endif
