#if !os(macOS) || targetEnvironment(macCatalyst)
  import AVFoundation
  import ObjCExceptionCatcher
  import SystemLog
  import os
  private let tapSetupLog = SystemLog.make()

  extension AIOEngine {
    struct TapConversionArtifacts {
      let converter: AVAudioConverter
      let inputFormat: AVAudioFormat
      let convertedBuffer: AVAudioPCMBuffer
    }

    func makeTapConversionArtifacts(
      inputFormat: AVAudioFormat,
      processingFormat: AVAudioFormat,
      tapBufferSize: AVAudioFrameCount
    ) throws(AIOError) -> TapConversionArtifacts {
      guard let converter = AVAudioConverter(from: inputFormat, to: processingFormat) else {
        throw AIOError.formatConversionFailed
      }
      let tapFrameRatio = processingFormat.sampleRate / inputFormat.sampleRate
      let maxTapFrames = max(
        AVAudioFrameCount(ceil(Double(tapBufferSize) * tapFrameRatio)),
        1
      )
      guard
        let convertedBuffer = AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: maxTapFrames
        )
      else {
        throw AIOError.formatConversionFailed
      }
      return TapConversionArtifacts(
        converter: converter,
        inputFormat: inputFormat,
        convertedBuffer: convertedBuffer
      )
    }

    func installTapCatchingObjCException(
      bus: Int,
      bufferSize: AVAudioFrameCount,
      processingFormat: AVAudioFormat,
      installContext: String
    ) throws(AIOError) -> AVAudioFormat {
      let inputFormat = unsafe engine.inputNode.outputFormat(forBus: 0)
      guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
        throw AIOError.invalidRecordingConfiguration(
          details:
            "Tap format invalid before install during \(installContext) (channels: \(inputFormat.channelCount), sampleRate: \(inputFormat.sampleRate))"
        )
      }

      let tapHandler = makeTapHandler(processingFormat: processingFormat)
      var installException: NSException?
      let tapInstalled = unsafe AIORunCatchingObjCException(
        {
          unsafe engine.inputNode.installTap(
            onBus: bus,
            bufferSize: bufferSize,
            format: nil,
            block: tapHandler
          )
        }, &installException)
      guard tapInstalled else {
        throw AIOError.invalidRecordingConfiguration(
          details:
            "installTap raised NSException during \(installContext): \(installException?.description ?? "unknown")"
        )
      }

      unsafe engine.prepare()
      let postInstallFormat = unsafe engine.inputNode.outputFormat(forBus: 0)
      guard postInstallFormat.channelCount > 0, postInstallFormat.sampleRate > 0 else {
        throw AIOError.invalidRecordingConfiguration(
          details:
            "Tap format invalid after install during \(installContext) (channels: \(postInstallFormat.channelCount), sampleRate: \(postInstallFormat.sampleRate))"
        )
      }
      return postInstallFormat
    }

    func makeAdjustedTapConversionArtifactsIfNeeded(
      initialArtifacts: TapConversionArtifacts,
      actualTapFormat: AVAudioFormat,
      processingFormat: AVAudioFormat,
      tapBufferSize: AVAudioFrameCount,
      logContext: String
    ) throws(AIOError) -> TapConversionArtifacts {
      guard
        actualTapFormat.channelCount != initialArtifacts.inputFormat.channelCount
          || actualTapFormat.sampleRate != initialArtifacts.inputFormat.sampleRate
      else {
        return initialArtifacts
      }

      tapSetupLog.warning(
        "Tap format changed during \(logContext, privacy: .public): expected \(initialArtifacts.inputFormat, privacy: .public), got \(actualTapFormat, privacy: .public)"
      )
      return try makeTapConversionArtifacts(
        inputFormat: actualTapFormat,
        processingFormat: processingFormat,
        tapBufferSize: tapBufferSize
      )
    }
  }
#endif
