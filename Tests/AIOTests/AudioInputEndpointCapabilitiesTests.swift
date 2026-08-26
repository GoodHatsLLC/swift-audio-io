// © GoodHatsLLC

import AudioIO
import Testing

struct AudioInputEndpointCapabilitiesTests {
  @Test
  func `native rate ranges normalize their bounds and preserve unknown`() {
    let known = AudioInputEndpointCapabilities(
      inputID: "usb",
      nativeSampleRateRanges: [
        AudioSampleRateRange(minimum: .hiRes96, maximum: .cd)
      ],
    )
    let unknown = AudioInputEndpointCapabilities(inputID: "ios")

    #expect(known.supportsNativeSampleRate(.dvd) == true)
    #expect(known.supportsNativeSampleRate(.speech) == false)
    #expect(unknown.supportsNativeSampleRate(.dvd) == nil)
  }

  @Test
  func `bluetooth feature evidence keeps support separate from active state`() {
    let capabilities = BluetoothMicrophoneCapabilities(
      highQualityRecording: AudioInputFeatureCapability(
        isSupported: true,
        isEnabled: false,
      ),
      farFieldCapture: AudioInputFeatureCapability(
        isSupported: false,
        isEnabled: false,
      ),
    )

    #expect(capabilities.highQualityRecording.isSupported)
    #expect(!capabilities.highQualityRecording.isEnabled)
    #expect(!capabilities.farFieldCapture.isSupported)
  }
}
