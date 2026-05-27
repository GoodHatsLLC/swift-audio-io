// AudioIODemo — a minimum-viable sample app for the AudioIO Swift package.
//
// What this demonstrates:
// - Subscribing to the unified AIOEngine.events stream BEFORE driving the engine.
// - Recording with a typed-throws start/stop using the canonical entry points.
// - Live multi-band LOD waveform rendering via subscriber-demand registration.
// - Playback of the most recent recording.
// - Microphone permission flow on both iOS and macOS.
//
// What this intentionally does NOT demonstrate:
// - Recording-list persistence, app capabilities beyond the microphone, audio
//   session category negotiation, segmented recording, or visualization beyond
//   the multi-band LOD. The library supports all of these; the sample stays
//   small so the canonical idioms are easy to read.

import SwiftUI

@main
struct AudioIODemoApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    #if os(macOS)
      .windowResizability(.contentSize)
    #endif
  }
}
