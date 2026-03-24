// © GoodHatsLLC

import Foundation

@MainActor
final class AudioEnvironmentEventHub {
  typealias RouteChangeHandler = @Sendable @MainActor (AudioRouteChangeEvent) async -> Void
  typealias InterruptionHandler =
    @Sendable @MainActor (AudioInterruptionType, AudioInterruptionOptions?) async -> Void
  typealias VoidHandler = @Sendable @MainActor () async -> Void

  var onRouteChange: RouteChangeHandler?
  var onInterruption: InterruptionHandler?
  var onMediaServicesLost: VoidHandler?
  var onMediaServicesReset: VoidHandler?

  private var routeChangeSubscribers: [UUID: RouteChangeHandler] = [:]
  private var interruptionSubscribers: [UUID: InterruptionHandler] = [:]
  private var mediaServicesLostSubscribers: [UUID: VoidHandler] = [:]
  private var mediaServicesResetSubscribers: [UUID: VoidHandler] = [:]

  @discardableResult
  func addRouteChangeSubscriber(_ handler: @escaping RouteChangeHandler) -> UUID {
    let id = UUID()
    routeChangeSubscribers[id] = handler
    return id
  }

  @discardableResult
  func addInterruptionSubscriber(_ handler: @escaping InterruptionHandler) -> UUID {
    let id = UUID()
    interruptionSubscribers[id] = handler
    return id
  }

  @discardableResult
  func addMediaServicesLostSubscriber(_ handler: @escaping VoidHandler) -> UUID {
    let id = UUID()
    mediaServicesLostSubscribers[id] = handler
    return id
  }

  @discardableResult
  func addMediaServicesResetSubscriber(_ handler: @escaping VoidHandler) -> UUID {
    let id = UUID()
    mediaServicesResetSubscribers[id] = handler
    return id
  }

  func removeSubscriber(_ id: UUID) {
    routeChangeSubscribers.removeValue(forKey: id)
    interruptionSubscribers.removeValue(forKey: id)
    mediaServicesLostSubscribers.removeValue(forKey: id)
    mediaServicesResetSubscribers.removeValue(forKey: id)
  }

  func dispatchInterruption(
    type: AudioInterruptionType,
    options: AudioInterruptionOptions?,
  ) async {
    await onInterruption?(type, options)
    for subscriber in interruptionSubscribers.values {
      await subscriber(type, options)
    }
  }

  func dispatchRouteChange(_ event: AudioRouteChangeEvent) async {
    await onRouteChange?(event)
    for subscriber in routeChangeSubscribers.values {
      await subscriber(event)
    }
  }

  func dispatchMediaServicesLost() async {
    await onMediaServicesLost?()
    for subscriber in mediaServicesLostSubscribers.values {
      await subscriber()
    }
  }

  func dispatchMediaServicesReset() async {
    await onMediaServicesReset?()
    for subscriber in mediaServicesResetSubscribers.values {
      await subscriber()
    }
  }
}
