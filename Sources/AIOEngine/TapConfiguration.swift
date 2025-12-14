#if canImport(AVFoundation)
  import AVFoundation

  struct TapConfiguration: Hashable, Sendable {

    init(
      bus: Int,
      channelCount: Int,
      inputFormat: AVAudioFormat,  // inputNode.inputFormat(forBus: 0)
      outputFormat: AVAudioFormat,
      tapReadSeconds: Double
    ) {
      self = TapConfiguration(
        bus: bus,
        inputFormat: inputFormat,
        outputFormat: outputFormat,
        bufferSize: AVAudioFrameCount(
          tapReadSeconds * inputFormat.sampleRate
            * Double(channelCount)
        )
      )
    }

    init(
      bus: Int,
      inputFormat: AVAudioFormat,
      outputFormat: AVAudioFormat,
      bufferSize: AVAudioFrameCount
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
