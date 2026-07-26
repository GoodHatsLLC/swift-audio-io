// © GoodHatsLLC

// `URL` appears in the public surface below, so the import must be public too.
public import Foundation

/// The outcome of a recording-file rotation.
public struct RecordingRotation: Sendable, Hashable {
  /// The file that was just completed.
  public let completedURL: URL

  /// Cumulative persisted-frame position, measured from the start of this
  /// capture, at which `completedURL` ends and the next file begins.
  ///
  /// Consecutive rotations produce a strictly increasing sequence, so a
  /// consumer can reconstruct each file's exact frame length as the difference
  /// between adjacent boundaries. The value is sampled where the split is
  /// decided, so it accounts for frames still awaiting drain into
  /// `completedURL`.
  ///
  /// The position counts frames the capture path presented to the writer. Those
  /// are the frames the writer persists unless its ring buffer overflowed, so a
  /// boundary difference can exceed a file's decoded frame count by exactly the
  /// frames that capture dropped. A drop is a fault, reported through the
  /// engine's error path; the boundary deliberately keeps tracking the capture
  /// timeline rather than silently absorbing the gap.
  public let boundaryFramePosition: Int64

  public init(completedURL: URL, boundaryFramePosition: Int64) {
    self.completedURL = completedURL
    self.boundaryFramePosition = boundaryFramePosition
  }
}

/// The outcome of stopping a recording.
public struct RecordingCompletion: Sendable, Hashable {
  /// The final file of this capture.
  public let completedURL: URL

  /// Cumulative persisted-frame position at which `completedURL` ends —
  /// therefore also the total frame count of the whole capture, across every
  /// rotation.
  ///
  /// Carries the same measurement and the same overflow caveat as
  /// ``RecordingRotation/boundaryFramePosition``. Because it closes the
  /// sequence, a consumer can assert that its assembled segment lengths sum to
  /// this value.
  public let boundaryFramePosition: Int64

  public init(completedURL: URL, boundaryFramePosition: Int64) {
    self.completedURL = completedURL
    self.boundaryFramePosition = boundaryFramePosition
  }
}
