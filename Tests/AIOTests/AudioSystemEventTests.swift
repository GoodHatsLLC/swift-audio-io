// © GoodHatsLLC

import Foundation
import Testing
import Tools

@testable import AIOAudioSession
@testable import AudioIO

struct AudioSystemEventTests {
  @Test
  func `route change captures endpoints and session facts as values`() {
    let previous = AudioRouteSnapshot(
      inputs: [
        AudioPortSnapshot(
          name: "Built-in Microphone",
          uid: "built-in-input",
          type: "microphoneBuiltIn",
          channelCount: 1,
        )
      ],
      outputs: [
        AudioPortSnapshot(
          name: "Speaker",
          uid: "built-in-output",
          type: "speaker",
          channelCount: 2,
        )
      ],
    )
    let current = AudioRouteSnapshot(
      inputs: [
        AudioPortSnapshot(
          name: "USB Interface",
          uid: "usb-input",
          type: "usbAudio",
          channelCount: 2,
        )
      ],
      outputs: [
        AudioPortSnapshot(
          name: "USB Interface",
          uid: "usb-output",
          type: "usbAudio",
          channelCount: 2,
        )
      ],
    )
    let session = AudioSessionSnapshot(
      category: "playAndRecord",
      mode: "measurement",
      options: ["allowBluetoothHFP"],
      sampleRate: 48_000,
      ioBufferDuration: 0.01,
      inputNumberOfChannels: 2,
      isInputAvailable: true,
    )

    let change = AudioRouteChange(
      reason: .configurationChanged,
      previousRoute: previous,
      currentRoute: current,
      session: session,
    )

    #expect(change.isInputAvailable)
    #expect(change.userMessage.contains("Route configuration changed"))
    #expect(
      change.userMessage.contains(
        "Input: Built-in Microphone (microphoneBuiltIn, 1ch) → USB Interface (usbAudio, 2ch)",
      ),
    )
    #expect(change.userMessage.contains("mode=measurement"))
    #expect(change.userMessage.contains("2ch@48000Hz"))
    #expect(Set([AudioSystemEvent.routeChanged(change)]).contains(.routeChanged(change)))
  }

  @Test
  func `route availability falls back to captured current inputs`() {
    let unavailable = AudioRouteChange(
      reason: .deviceDisconnected,
      previousRoute: nil,
      currentRoute: AudioRouteSnapshot(inputs: [], outputs: []),
    )
    let available = AudioRouteChange(
      reason: .deviceConnected,
      previousRoute: nil,
      currentRoute: AudioRouteSnapshot(
        inputs: [
          AudioPortSnapshot(
            name: "Microphone",
            uid: "input",
            type: "input",
            channelCount: 1,
          )
        ],
        outputs: [],
      ),
    )

    #expect(unavailable.isInputAvailable == false)
    #expect(available.isInputAvailable)
  }

  @Test
  @MainActor
  func `subscriber can remove itself during dispatch`() async {
    let hub = AudioEnvironmentEventHub()
    let owner = SubscriptionOwner()
    owner.id = hub.addSubscriber { _ in
      owner.receivedCount += 1
      if let id = owner.id {
        hub.removeSubscriber(id)
      }
    }

    await hub.dispatch(.mediaServicesLost)
    await hub.dispatch(.mediaServicesReset)

    #expect(owner.receivedCount == 1)
  }

  @Test
  @MainActor
  func `media service lifecycle gates new recording attempts`() async {
    let engine = AIOEngine()

    await engine.handleAudioSystemEvent(.mediaServicesLost)
    #expect(engine.audioRecoveryState.mediaServicesAreAvailable == false)

    await engine.handleAudioSystemEvent(.mediaServicesReset)
    #expect(engine.audioRecoveryState.mediaServicesAreAvailable)
  }

  @Test
  @MainActor
  func `playback recovery failure is published through engine events`() async {
    let engine = AIOEngine()
    let subscription = engine.events.subscribe()
    let receivedError = AsyncContinuation<Void>()
    let eventWork = MainActorOwnedWork {
      for await event in subscription.events {
        if case .error = event {
          try? receivedError.yield()
          return
        }
      }
    }
    defer {
      subscription.cancel()
      eventWork.cancelNow()
    }

    engine.audioRecoveryState.pendingPlayback = PlaybackResume(
      fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-\(UUID().uuidString).caf"),
      time: 0,
      duration: 1,
      wasPlaying: true,
      pollingInterval: Duration.seconds(1),
      sampleRate: 48_000,
    )

    await engine.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))
    do {
      try await withTimeout(of: .seconds(2)) {
        await receivedError()
      }
    } catch {
      Issue.record("Expected playback recovery failure event, got \(error)")
    }
  }
}

@MainActor
private final class SubscriptionOwner {
  var id: UUID?
  var receivedCount = 0
}
