// © GoodHatsLLC

import Testing

@testable import Tools

@Suite("AudioLevel")
struct AudioLevelTests {

  // MARK: - Boundary values

  @Test("slider 0 maps to amplitude 0 (hard mute)")
  func sliderZeroIsMute() {
    #expect(AudioLevel.amplitude(fromSlider: 0) == 0)
  }

  @Test("slider 1 maps to amplitude 1 (0 dB)")
  func sliderOneIsUnity() {
    let amp = AudioLevel.amplitude(fromSlider: 1)
    #expect(abs(amp - 1.0) < 1e-6)
  }

  @Test("amplitude 0 maps to slider 0")
  func zeroAmplitudeIsSliderZero() {
    #expect(AudioLevel.slider(fromAmplitude: 0) == 0)
  }

  @Test("amplitude 1 maps to slider 1")
  func unityAmplitudeIsSliderOne() {
    let slider = AudioLevel.slider(fromAmplitude: 1.0)
    #expect(abs(slider - 1.0) < 1e-6)
  }

  // MARK: - Midpoint (linear in dB)

  @Test("slider 0.5 at default minDb = -60 → -30 dB → ≈ 0.0316 amplitude")
  func sliderMidpointIsMinusThirtyDb() {
    let amp = AudioLevel.amplitude(fromSlider: 0.5)
    // 10^(-30/20) = 0.03162277…
    #expect(abs(Double(amp) - 0.03162277660168379) < 1e-6)
  }

  // MARK: - Round-trip

  @Test(
    "round trip slider → amplitude → slider is identity",
    arguments: [0.01, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]
  )
  func roundTrip(slider: Double) {
    let amp = AudioLevel.amplitude(fromSlider: slider)
    let back = AudioLevel.slider(fromAmplitude: amp)
    #expect(abs(back - slider) < 1e-6)
  }

  // MARK: - Clamping

  @Test("slider below 0 clamps to 0")
  func sliderClampLow() {
    #expect(AudioLevel.amplitude(fromSlider: -0.1) == 0)
  }

  @Test("slider above 1 clamps to 1")
  func sliderClampHigh() {
    let amp = AudioLevel.amplitude(fromSlider: 1.5)
    #expect(abs(amp - 1.0) < 1e-6)
  }

  @Test("negative amplitude clamps to slider 0")
  func negativeAmplitudeClamps() {
    #expect(AudioLevel.slider(fromAmplitude: -0.5) == 0)
  }

  // MARK: - Custom minDb parameter

  @Test("slider 0.5 at minDb -40 → -20 dB → 0.1 amplitude")
  func customMinDbMidpoint() {
    let amp = AudioLevel.amplitude(fromSlider: 0.5, minDb: -40)
    // 10^(-20/20) = 0.1
    #expect(abs(Double(amp) - 0.1) < 1e-6)
  }

  @Test("round trip preserves custom minDb")
  func customMinDbRoundTrip() {
    let original = 0.6
    let amp = AudioLevel.amplitude(fromSlider: original, minDb: -40)
    let back = AudioLevel.slider(fromAmplitude: amp, minDb: -40)
    #expect(abs(back - original) < 1e-6)
  }

  // MARK: - NaN / infinity resistance

  @Test("db(fromAmplitude: 0) is -infinity")
  func zeroAmplitudeIsMinusInfinity() {
    #expect(AudioLevel.db(fromAmplitude: 0) == -.infinity)
  }

  @Test("amplitude(fromDb: -infinity) is 0")
  func minusInfinityDbIsZero() {
    #expect(AudioLevel.amplitude(fromDb: -.infinity) == 0)
  }

  @Test("amplitude(fromDb: 0) is 1.0")
  func zeroDbIsUnity() {
    let amp = AudioLevel.amplitude(fromDb: 0)
    #expect(abs(amp - 1.0) < 1e-6)
  }

  @Test("amplitude(fromDb: -6) is ≈ 0.501")
  func minusSixDb() {
    let amp = AudioLevel.amplitude(fromDb: -6)
    #expect(abs(Double(amp) - 0.5011872336272722) < 1e-6)
  }
}
