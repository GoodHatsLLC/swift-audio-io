// © GoodHatsLLC

import Foundation
import Testing

@testable import AIOEngine

struct OutputConfigurationManagerTests {
  @MainActor
  private func makeIsolatedDefaults() throws -> UserDefaults {
    let suiteName = "aio.tests.output-config.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  @Test
  @MainActor
  func `default configuration is ADTS high`() throws {
    let env = AudioEnvironment()
    let errors = MockErrorManager()
    let manager = try OutputConfigurationManager(
      env: env,
      errorManager: errors,
      defaults: makeIsolatedDefaults(),
    )

    #expect(manager.outputFormat == .adts)
    #expect(manager.bitDepth == .pcmFloat32)
    #expect(manager.encodingQuality == .high)

    let config = try #require(manager.outputConfiguration)
    #expect(config.fileFormat == .adts)
    #expect(config.bitDepth == .pcmFloat32)
    #expect(config.quality == .high)
  }

  @Test
  @MainActor
  func `switching to flac aligns bit depth and forces maximum quality`() throws {
    let env = AudioEnvironment()
    let errors = MockErrorManager()
    let manager = try OutputConfigurationManager(
      env: env,
      errorManager: errors,
      defaults: makeIsolatedDefaults(),
    )

    // Start from a bit depth FLAC does not support.
    manager.bitDepth = .pcmFloat32
    manager.outputFormat = .flac

    // FLAC supports 16/24 only; the manager should align to the first supported.
    #expect(manager.bitDepth == .pcmInt16)

    // FLAC doesn't require quality -> only maximum is available and selected.
    #expect(manager.availableEncodingQualities == [.maximum])
    #expect(manager.encodingQuality == .maximum)

    let config = try #require(manager.outputConfiguration)
    #expect(config.fileFormat == .flac)
    #expect(config.bitDepth == .pcmInt16)
    #expect(config.quality == .maximum)
  }

  @Test
  @MainActor
  func `switching to wav keeps bit depth and forces maximum quality`() throws {
    let env = AudioEnvironment()
    let errors = MockErrorManager()
    let manager = try OutputConfigurationManager(
      env: env,
      errorManager: errors,
      defaults: makeIsolatedDefaults(),
    )

    manager.bitDepth = .pcmInt24
    manager.outputFormat = .wav

    // WAV supports all bit depths.
    #expect(manager.bitDepth == .pcmInt24)

    // WAV doesn't require quality -> maximum.
    #expect(manager.availableEncodingQualities == [.maximum])
    #expect(manager.encodingQuality == .maximum)

    let config = try #require(manager.outputConfiguration)
    #expect(config.fileFormat == .wav)
    #expect(config.bitDepth == .pcmInt24)
    #expect(config.quality == .maximum)
  }

  @Test
  @MainActor
  func `remembers previous output configuration across instances`() throws {
    let defaults = try makeIsolatedDefaults()

    let env = AudioEnvironment()
    let errors = MockErrorManager()

    do {
      let manager = OutputConfigurationManager(env: env, errorManager: errors, defaults: defaults)
      manager.outputFormat = .wav
      manager.bitDepth = .pcmInt24
      manager.encodingQuality = .maximum
      _ = try #require(manager.outputConfiguration)
    }

    do {
      let manager = OutputConfigurationManager(env: env, errorManager: errors, defaults: defaults)
      #expect(manager.outputFormat == .wav)
      #expect(manager.bitDepth == .pcmInt24)
      #expect(manager.encodingQuality == .maximum)
    }
  }
}
