// © GoodHatsLLC

#if canImport(AVFoundation)
  import AVFoundation

  struct TapConfiguration: Hashable {
    private static func normalizedBufferSize(
      sampleRate: Double,
      tapReadSeconds: Double,
    ) -> AVAudioFrameCount {
      let minFrames = 256
      let maxFrames = 8192

      guard sampleRate.isFinite, sampleRate > 0, tapReadSeconds.isFinite, tapReadSeconds > 0 else {
        return AVAudioFrameCount(1024)
      }

      let desired = tapReadSeconds * sampleRate
      guard desired.isFinite else { return AVAudioFrameCount(1024) }

      let desiredFrames = min(max(Int(desired.rounded()), minFrames), maxFrames)

      let lower = 1 << (Int.bitWidth - 1 - desiredFrames.leadingZeroBitCount)
      let upper = min(lower << 1, maxFrames)
      let chosen = (desiredFrames - lower) < (upper - desiredFrames) ? lower : upper

      return AVAudioFrameCount(chosen)
    }

    init(
      bus: Int,
      channelCount _: Int,
      inputFormat: AVAudioFormat,  // inputNode.outputFormat(forBus: 0)
      outputFormat: AVAudioFormat,
      tapReadSeconds: Double,
    ) {
      self = TapConfiguration(
        bus: bus,
        inputFormat: inputFormat,
        outputFormat: outputFormat,
        bufferSize: Self.normalizedBufferSize(
          sampleRate: inputFormat.sampleRate,
          tapReadSeconds: tapReadSeconds,
        ),
      )
    }

    init(
      bus: Int,
      inputFormat: AVAudioFormat,
      outputFormat: AVAudioFormat,
      bufferSize: AVAudioFrameCount,
    ) {
      self.bus = bus
      // convert the inputFormat to a sendable representation
      self.inputFormat = inputFormat.formatDescription
      self.outputFormat = outputFormat.formatDescription
      self.bufferSize = bufferSize
    }

    let bus: Int
    let inputFormat: CMFormatDescription
    let outputFormat: CMFormatDescription
    let bufferSize: AVAudioFrameCount

    var inputAVAudioFormat: AVAudioFormat {
      AVAudioFormat(cmAudioFormatDescription: inputFormat)
    }

    var outputAVAudioFormat: AVAudioFormat {
      AVAudioFormat(cmAudioFormatDescription: outputFormat)
    }
  }
#endif
