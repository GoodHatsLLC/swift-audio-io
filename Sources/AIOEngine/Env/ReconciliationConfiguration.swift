// © GoodHatsLLC

#if canImport(AVFoundation)
  import Foundation

  /// Configuration for how the engine should attempt to reconcile
  /// the desired recording state with the actual hardware state.
  ///
  /// When the user requests to start recording, the audio session may not
  /// be immediately ready (e.g., after returning from background, route changes).
  /// The engine will retry for the configured `timeout` period before giving up.
  public struct ReconciliationConfiguration: Hashable, Sendable {
    /// How long to continue attempting to reconcile before giving up.
    ///
    /// After this duration, if the desired state cannot be achieved,
    /// the engine will flip `wantsRecording` back to match the actual state.
    public let timeout: Duration

    /// How long to wait between retry attempts.
    public let retryInterval: Duration

    /// Creates a reconciliation configuration.
    ///
    /// - Parameters:
    ///   - timeout: Maximum time to attempt reconciliation. Default is 2 seconds.
    ///   - retryInterval: Time between retry attempts. Default is 100ms.
    public init(
      timeout: Duration = .seconds(2),
      retryInterval: Duration = .milliseconds(100),
    ) {
      self.timeout = timeout
      self.retryInterval = retryInterval
    }

    /// Default configuration with 2 second timeout and 100ms retry interval.
    public static let `default` = ReconciliationConfiguration()

    /// A more aggressive configuration with longer timeout for challenging audio environments.
    public static let extended = ReconciliationConfiguration(
      timeout: .seconds(5),
      retryInterval: .milliseconds(150),
    )

    /// Minimal configuration that gives up quickly.
    public static let minimal = ReconciliationConfiguration(
      timeout: .milliseconds(500),
      retryInterval: .milliseconds(50),
    )
  }
#endif
