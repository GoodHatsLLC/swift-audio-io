// © GoodHatsLLC

#if os(macOS)
  package import CoreAudio

  extension RecordingError {
    /// Maps a Core Audio HAL `OSStatus` from a system-audio **startup** operation
    /// (create tap, create aggregate device, create/start IOProc) to a
    /// `RecordingError`.
    ///
    /// This is the single source of truth for the reconciliation retry decision:
    /// retryable not-ready statuses map to `.session(.notReady)` so the existing
    /// `RecordingError.isTransient` gate drives bounded retry, and everything else
    /// maps to a terminal case whose `isTransient` is `false`. See the plan's
    /// "Reconciliation retry investigation" table.
    package static func systemAudioStartupFailure(
      _ status: OSStatus,
      operation: String,
    ) -> RecordingError {
      switch status {
      case kAudioHardwareNotReadyError:
        // Transient: HAL explicitly reports the object as not ready. Clean up and
        // retry with reconciliation backoff (handled by the .notReady gate).
        return .session(
          .notReady(details: "\(operation): Core Audio not ready (OSStatus \(status))"),
        )

      case kAudioDevicePermissionsError:
        return .captureSourceUnavailable(
          details:
            "\(operation): system-audio recording permission denied (OSStatus \(status))",
        )

      case kAudioHardwareUnsupportedOperationError, kAudioDeviceUnsupportedFormatError:
        return .captureSourceFailed(
          sourceDescription: "systemAudio",
          details: "\(operation): unsupported operation or format (OSStatus \(status))",
        )

      case kAudioHardwareBadObjectError, kAudioHardwareBadDeviceError,
        kAudioHardwareBadStreamError:
        return .captureSourceFailed(
          sourceDescription: "systemAudio",
          details:
            "\(operation): stale or invalid Core Audio object (OSStatus \(status)); refresh process selection",
        )

      case kAudioHardwareNotRunningError:
        // Not a startup readiness condition; terminal for a start attempt.
        return .captureSourceFailed(
          sourceDescription: "systemAudio",
          details: "\(operation): Core Audio not running (OSStatus \(status))",
        )

      default:
        // kAudioHardwareUnknownPropertyError, kAudioHardwareBadPropertySizeError,
        // kAudioHardwareIllegalOperationError, kAudioHardwareUnspecifiedError, and
        // any unlisted status: terminal, surfaced, never retried.
        return .coreAudioFailed(
          operation: operation,
          osStatus: status,
          details: "unmapped HAL status",
        )
      }
    }
  }
#endif
