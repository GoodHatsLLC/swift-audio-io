// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession

  /// Enforces the requested microphone channel count at both the audio-session
  /// and input-tap boundaries.
  ///
  /// AudioIO may downmix a multichannel hardware input into a smaller processing
  /// format, but it must never manufacture extra channels by upmixing a narrower
  /// hardware signal. A stereo request backed by a mono route is transient while
  /// iOS settles a data-source change, so mismatches use `SessionError.notReady`
  /// and participate in recording reconciliation.
  package enum RecordingInputChannelContract {
    package static func validateRouteCapacity(
      requested: Int,
      maximum: Int,
    ) throws(SessionError) {
      guard requested <= maximum else {
        throw .notReady(
          details:
            "Requested \(requested) input channels, but the current route supports at most \(maximum).",
        )
      }
    }

    package static func validateCaptureFormat(
      requested: Int,
      actual: Int,
    ) throws(SessionError) {
      guard actual >= requested else {
        throw .notReady(
          details:
            "Requested \(requested) input channels, but the active capture format exposes \(actual).",
        )
      }
    }
  }
#endif
