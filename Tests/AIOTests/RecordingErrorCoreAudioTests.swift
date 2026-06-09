// © GoodHatsLLC

#if os(macOS)
  import CoreAudio
  import Testing

  @testable import AIOAudioSession

  struct RecordingErrorCoreAudioTests {
    // Each row of the plan's "Reconciliation retry investigation" table: the
    // mapped RecordingError's `isTransient` must equal the table's retry decision,
    // because that property is what actually gates the reconciliation loop.
    @Test(
      arguments: [
        (kAudioHardwareNotReadyError, true),
        (kAudioDevicePermissionsError, false),
        (kAudioHardwareUnsupportedOperationError, false),
        (kAudioDeviceUnsupportedFormatError, false),
        (kAudioHardwareBadObjectError, false),
        (kAudioHardwareBadDeviceError, false),
        (kAudioHardwareBadStreamError, false),
        (kAudioHardwareUnknownPropertyError, false),
        (kAudioHardwareBadPropertySizeError, false),
        (kAudioHardwareIllegalOperationError, false),
        (kAudioHardwareUnspecifiedError, false),
        (kAudioHardwareNotRunningError, false),
        (OSStatus(123_456), false),  // unknown / unmapped
      ],
    )
    func `startup status maps to the expected transient decision`(
      status: OSStatus,
      expectedTransient: Bool,
    ) {
      let error = RecordingError.systemAudioStartupFailure(status, operation: "create tap")
      #expect(
        error.isTransient == expectedTransient,
        "OSStatus \(status) expected isTransient=\(expectedTransient), got \(error.isTransient): \(error)",
      )
    }

    @Test
    func `not-ready maps to a transient session error`() {
      let error = RecordingError.systemAudioStartupFailure(
        kAudioHardwareNotReadyError,
        operation: "start IO",
      )
      guard case .session(.notReady) = error else {
        Issue.record("Expected .session(.notReady), got \(error)")
        return
      }
    }

    @Test
    func `permissions maps to a terminal captureSourceUnavailable`() {
      let error = RecordingError.systemAudioStartupFailure(
        kAudioDevicePermissionsError,
        operation: "create tap",
      )
      guard case .captureSourceUnavailable = error else {
        Issue.record("Expected .captureSourceUnavailable, got \(error)")
        return
      }
      #expect(!error.isTransient)
    }

    @Test
    func `unknown status maps to coreAudioFailed carrying the status`() {
      let raw = OSStatus(987_654)
      let error = RecordingError.systemAudioStartupFailure(raw, operation: "create IOProc")
      guard case .coreAudioFailed(let operation, let osStatus, _) = error else {
        Issue.record("Expected .coreAudioFailed, got \(error)")
        return
      }
      #expect(operation == "create IOProc")
      #expect(osStatus == raw)
    }
  }
#endif
