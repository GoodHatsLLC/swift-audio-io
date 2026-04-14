// © GoodHatsLLC

import Foundation

/// Pure dB ↔ amplitude ↔ slider math for output level UI.
///
/// Slider 0 is a hard mute (amplitude 0), slider 1 is unity gain (0 dB).
/// Between the two endpoints, the slider is linear in dB space: slider 0.5
/// at the default `minDb = -60` maps to `-30 dB`.
///
/// All functions are safe against NaN / ±infinity — they clamp to 0 or 1.
public enum AudioLevel {
  public static let defaultMinDb: Double = -60

  /// Convert a 0…1 slider value to a linear amplitude suitable for
  /// `AVAudioMixerNode.outputVolume`. Slider 0 returns `0` (hard mute);
  /// slider 1 returns `1` (0 dB).
  public static func amplitude(
    fromSlider slider: Double,
    minDb: Double = defaultMinDb,
  ) -> Float {
    let clamped = max(0, min(1, slider))
    guard clamped > 0 else { return 0 }
    let db = minDb + (-minDb) * clamped
    return amplitude(fromDb: db)
  }

  /// Inverse of `amplitude(fromSlider:)`. Amplitude ≤ 0 maps to slider 0.
  public static func slider(
    fromAmplitude amplitude: Float,
    minDb: Double = defaultMinDb,
  ) -> Double {
    guard amplitude > 0 else { return 0 }
    let dbValue = db(fromAmplitude: amplitude)
    let clamped = max(minDb, min(0, dbValue))
    return (clamped - minDb) / (-minDb)
  }

  /// Amplitude → decibels. Returns `-.infinity` for non-positive amplitude.
  public static func db(fromAmplitude amplitude: Float) -> Double {
    guard amplitude > 0 else { return -.infinity }
    return 20 * log10(Double(amplitude))
  }

  /// Decibels → amplitude. Returns `0` for non-finite input.
  public static func amplitude(fromDb db: Double) -> Float {
    guard db.isFinite else { return 0 }
    return Float(pow(10, db / 20))
  }
}
