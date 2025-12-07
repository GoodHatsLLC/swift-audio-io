/// A protocol for objects that can receive and process buffers of audio data.
public protocol BufferReceiver<T>: AnyObject, Sendable {
  associatedtype T
  /// Processes a buffer of audio data.
  ///
  /// This method is called on a real-time audio thread. Implementations should be fast and non-blocking.
  ///
  /// - Parameter data: A buffer pointer to the audio data.
  nonisolated func processBuffer(_ data: UnsafeBufferPointer<T>)
  /// Called when the buffer task is ending.
  ///
  /// This method is called when the audio engine is stopping, and no more buffers will be received.
  /// Use this method to clean up any resources.
  nonisolated func endBufferTask()
}

/// A protocol for objects that can emit buffers of audio data to receivers.
public protocol BufferEmitter<T>: AnyObject, Sendable {
  associatedtype T
  /// Attaches a buffer receiver to the emitter.
  ///
  /// - Parameter receiver: The buffer receiver to attach.
  func attachBufferReceiver(_ receiver: some BufferReceiver<T>) async
  /// Detaches all buffer receivers from the emitter.
  func detachBufferReceivers() async
}
