// © GoodHatsLLC

#if canImport(AVFoundation)
  public import Foundation
  public import Tools

  /// Marker protocol shared by every error type AudioIO throws across its
  /// public API surface (``RecordingError``, ``PlaybackError``, ``SessionError``).
  ///
  /// Most call sites should catch the concrete domain enum and switch over its
  /// cases. Use `catch let error as any AudioIOError` only when type-erasing
  /// across multiple AudioIO subsystems — e.g. an aggregate error sink that
  /// reports session, playback, and recording failures uniformly.
  public protocol AudioIOError: AudioError, LocalizedError {}
#endif
