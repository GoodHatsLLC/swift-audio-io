// © GoodHatsLLC

import AudioIO
import Testing

struct AudioChannelConfigurationAvailabilityTests {
  @Test
  func `unresolved capability exposes no channel counts`() {
    let availability = AudioChannelConfigurationAvailability.unresolved

    #expect(availability.availableChannelCounts.isEmpty)
  }

  @Test
  func `fixed capability exposes its sole channel count`() {
    let availability = AudioChannelConfigurationAvailability.fixed(.mono)

    #expect(availability.availableChannelCounts == [.mono])
  }

  @Test
  func `configurable capability exposes every channel choice`() {
    let availability = AudioChannelConfigurationAvailability.configurable([.stereo, .mono])

    #expect(availability.availableChannelCounts == [.mono, .stereo])
  }
}
