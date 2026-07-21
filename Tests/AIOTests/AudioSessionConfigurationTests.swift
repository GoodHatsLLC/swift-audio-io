// © GoodHatsLLC

import Testing

#if os(iOS)
  import AVFAudio
#endif

@testable import AIOAudioSession

struct AudioSessionConfigurationTests {
  @Test
  func `recording configuration derives measurement mode from its input`() {
    let standard = AudioSessionConfiguration.recordingConfiguration(useMeasurement: false)
    let measurement = AudioSessionConfiguration.recordingConfiguration(useMeasurement: true)

    #expect(standard.mode == .default)
    #expect(measurement.mode == .measurement)
    #expect(AudioSessionConfiguration.recordingConfiguration.mode == .default)
  }
}
