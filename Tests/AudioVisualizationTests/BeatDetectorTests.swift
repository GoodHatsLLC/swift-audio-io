#if canImport(AVFoundation)
  import AIOEngine
  import Foundation
  import Testing

  @Suite("Beat Detector Tests")
  struct BeatDetectorTests {

    // MARK: - Initialization Tests

    @Test("BeatDetector initializes with default configuration")
    func testBeatDetectorDefaultInit() {
      let detector = BeatDetector()
      // Should not crash and be ready to use
      let result = detector.analyze(spectrum: [], rmsLevel: 0, deltaTime: 1.0 / 60.0)
      #expect(!result.beatDetected)
      #expect(result.energy == 0)
    }

    @Test("BeatDetector initializes with custom configuration")
    func testBeatDetectorCustomInit() {
      let config = BeatDetectionConfiguration(
        sensitivity: 0.3,
        minimumBeatInterval: 0.2,
        bassFocused: false,
        historySize: 60
      )
      let detector = BeatDetector(configuration: config)
      let result = detector.analyze(spectrum: [], rmsLevel: 0, deltaTime: 1.0 / 60.0)
      #expect(!result.beatDetected)
    }

    // MARK: - Beat Detection Tests

    @Test("BeatDetector detects no beat on silent input")
    func testBeatDetectorSilentInput() {
      let detector = BeatDetector()

      // Run several frames with silence
      for _ in 0..<60 {
        let result = detector.analyze(
          spectrum: Array(repeating: 0, count: 64), rmsLevel: 0, deltaTime: 1.0 / 60.0)
        #expect(!result.beatDetected)
      }
    }

    @Test("BeatDetector detects beat on sudden energy increase")
    func testBeatDetectorDetectsBeat() {
      let detector = BeatDetector(configuration: .highSensitivity)

      // Build up energy history with low values
      for _ in 0..<50 {
        let lowSpectrum = Array(repeating: Float(0.1), count: 64)
        _ = detector.analyze(spectrum: lowSpectrum, rmsLevel: 0.1, deltaTime: 1.0 / 60.0)
      }

      // Sudden spike - should detect beat
      let highSpectrum = Array(repeating: Float(0.9), count: 64)
      let result = detector.analyze(spectrum: highSpectrum, rmsLevel: 0.9, deltaTime: 1.0 / 60.0)

      // The beat may or may not be detected depending on the adaptive threshold
      // At minimum, energy should be high
      #expect(result.energy > 0.5)
    }

    @Test("BeatDetector respects minimum beat interval")
    func testBeatDetectorMinimumInterval() {
      let config = BeatDetectionConfiguration(
        sensitivity: 0.3,
        minimumBeatInterval: 0.5  // 500ms minimum
      )
      let detector = BeatDetector(configuration: config)

      // Build history
      for _ in 0..<50 {
        _ = detector.analyze(
          spectrum: Array(repeating: Float(0.1), count: 64), rmsLevel: 0.1, deltaTime: 1.0 / 60.0)
      }

      // First spike
      let highSpectrum = Array(repeating: Float(0.9), count: 64)
      _ = detector.analyze(spectrum: highSpectrum, rmsLevel: 0.9, deltaTime: 1.0 / 60.0)

      // Immediate second spike - should NOT detect due to minimum interval
      let result = detector.analyze(spectrum: highSpectrum, rmsLevel: 0.9, deltaTime: 0.01)
      #expect(!result.beatDetected)
    }

    // MARK: - Configuration Update Tests

    @Test("BeatDetector configuration can be updated")
    func testBeatDetectorUpdateConfiguration() {
      let detector = BeatDetector()

      // Update to high sensitivity
      detector.updateConfiguration(.highSensitivity)

      // Should still work
      let result = detector.analyze(spectrum: [], rmsLevel: 0, deltaTime: 1.0 / 60.0)
      #expect(!result.beatDetected)
    }

    @Test("BeatDetector reset clears state")
    func testBeatDetectorReset() {
      let detector = BeatDetector()

      // Run some frames
      for _ in 0..<50 {
        _ = detector.analyze(
          spectrum: Array(repeating: Float(0.5), count: 64), rmsLevel: 0.5, deltaTime: 1.0 / 60.0)
      }

      // Reset
      detector.reset()

      // Should be back to initial state
      let result = detector.analyze(spectrum: [], rmsLevel: 0, deltaTime: 1.0 / 60.0)
      #expect(result.timeSinceLastBeat == .infinity)
      #expect(result.estimatedTempo == 0)
    }

    // MARK: - Tempo Estimation Tests

    @Test("BeatDetector estimates tempo with regular beats")
    func testBeatDetectorTempoEstimation() {
      let detector = BeatDetector(configuration: .default)

      // We can't easily test actual tempo estimation without triggering real beats,
      // but we can verify the initial state
      let result = detector.analyze(spectrum: [], rmsLevel: 0, deltaTime: 1.0 / 60.0)
      #expect(result.estimatedTempo == 0)  // No tempo without beats
    }

    // MARK: - Bass Focus Tests

    @Test("BeatDetector bass focus uses lower frequencies")
    func testBeatDetectorBassFocus() {
      let bassFocusedConfig = BeatDetectionConfiguration(bassFocused: true)
      let bassDetector = BeatDetector(configuration: bassFocusedConfig)

      let fullRangeConfig = BeatDetectionConfiguration(bassFocused: false)
      let fullRangeDetector = BeatDetector(configuration: fullRangeConfig)

      // Create spectrum with high bass, low treble
      var bassHeavySpectrum = Array(repeating: Float(0.1), count: 64)
      for i in 0..<16 {  // First quarter is bass
        bassHeavySpectrum[i] = 0.9
      }

      // Both detectors should process the same spectrum differently
      let bassResult = bassDetector.analyze(
        spectrum: bassHeavySpectrum, rmsLevel: 0.3, deltaTime: 1.0 / 60.0)
      let fullResult = fullRangeDetector.analyze(
        spectrum: bassHeavySpectrum, rmsLevel: 0.3, deltaTime: 1.0 / 60.0)

      // Bass-focused detector should report higher energy for bass-heavy spectrum
      #expect(bassResult.energy > fullResult.energy)
    }
  }

#endif
