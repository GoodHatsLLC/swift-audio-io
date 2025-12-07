# Multiplatform Migration Plan: iOS → macOS Native Support

**Status:** Planning Document
**Target Platforms:** iOS 18+, macOS 14+
**Estimated Effort:** 10-15 weeks
**Last Updated:** 2025-11-13

---

## Executive Summary

This document outlines a comprehensive migration strategy to enable native macOS support for the audio recording library currently designed exclusively for iOS. The codebase demonstrates good architectural foundations with conditional compilation patterns already in place (e.g., `PlatformColor` abstraction in SystemLog), but requires substantial work in three critical areas:

1. **Audio Session Management** - iOS-specific AVAudioSession configuration options
2. **UI Layer Abstraction** - UIKit dependencies (windows, view controllers, app lifecycle)
3. **Device Capabilities** - iOS concepts without macOS equivalents (device orientation, haptics)

The migration is **feasible and well-scoped**, with ~70% of the core audio engine already platform-agnostic. The primary challenges lie in the UI/AppLibrary layer, which is 100% iOS-dependent.

---

## Table of Contents

1. [Current State Analysis](#current-state-analysis)
2. [Platform Abstraction Strategy](#platform-abstraction-strategy)
3. [Migration Roadmap](#migration-roadmap)
4. [Detailed Implementation Plan](#detailed-implementation-plan)
5. [File-by-File Impact Analysis](#file-by-file-impact-analysis)
6. [Testing Strategy](#testing-strategy)
7. [Risk Assessment](#risk-assessment)
8. [Appendices](#appendices)

---

## Current State Analysis

### 1.1 Package Configuration

#### **AIO/Package.swift** (Core Audio Engine)
```swift
platforms: [
  .iOS(.v18),
  .macCatalyst(.v18),  // ⚠️ Catalyst is iOS-on-Mac, not native macOS
]
```
**Status:** ✅ Partially ready - AVFoundation dependencies are cross-platform
**Required Change:** Add `.macOS(.v14)` target

#### **AppLibrary/Package.swift** (UI & App Layer)
```swift
platforms: [
  .iOS(.v26)  // ⚠️ not a typo. ios26  was recently released. in 2026. 
]
```
**Status:** 🔴 iOS-only, requires major refactoring
**Required Change:** Add `.macOS(.v14)`, fix version to `.v18`, add platform-specific feature flags

### 1.2 Framework Dependencies

| Framework | iOS | macOS | Usage | Files Affected | Migration Strategy |
|-----------|-----|-------|-------|----------------|-------------------|
| **AVFoundation** | ✅ | ✅ | Audio I/O, session management | 13 files | Minor conditional changes for session options |
| **UIKit** | ✅ | ❌ | Windows, view controllers, device info | 13 files | Abstract to AppKit equivalents |
| **AppKit** | ❌ | ✅ | N/A (not yet used) | 0 files | Add for macOS window/app management |
| **MessageUI** | ✅ | ❌ | Email composition | MailView.swift | Remove or replace with platform-specific solution |
| **CoreHaptics** | ✅ | ❌ | Haptic feedback | Haptics.swift | Gracefully disable on macOS |
| **ActivityKit** | ✅ | ❌ | Live Activities | RecordingActivityManager.swift | Already has conditional compilation (✅) |
| **GRDB** | ✅ | ✅ | Database | Multiple | No changes needed (✅) |

### 1.3 Critical Platform Dependencies

#### **Device Orientation** (`AudioEnvironmentManager.swift:356-391`)
```swift
#if canImport(UIKit)
  import UIKit

  UIDevice.current.beginGeneratingDeviceOrientationNotifications()
  let stream = NotificationCenter.default.notifications(
    named: UIDevice.orientationDidChangeNotification)
```

**Problem:** macOS has no device orientation concept
**Impact:** Affects stereo microphone orientation for handheld recording
**Solution:** Abstract to platform-specific orientation provider:
- iOS: Use UIDevice orientation (existing)
- macOS: Use screen orientation or default to `.portrait`

#### **Audio Session Options** (`AudioEnvironmentManager.swift:415-424`)
```swift
try self.env.session.setCategory(
  .playAndRecord,
  mode: .default,
  options: [
    .defaultToSpeaker,              // ❌ iOS-specific
    .allowBluetoothA2DP,            // ❌ iOS-specific
    .allowAirPlay,                  // ❌ iOS-specific
    .allowBluetoothHFP,             // ❌ iOS-specific
    .overrideMutedMicrophoneInterruption,  // ❌ iOS-specific
  ]
)
```

**Problem:** Many AVAudioSession.CategoryOptions are iOS-only
**Impact:** Session configuration will fail on macOS
**Solution:** Use conditional compilation for platform-appropriate options

#### **Window Management** (`OverlayWindow.swift:27-40`)
```swift
if let windowScene = (UIApplication.shared.connectedScenes.first as? UIWindowScene),
  properties.window == nil
{
  let window = PassThroughWindow(windowScene: windowScene)
  let rootViewController = UIHostingController(rootView: ...)
  window.rootViewController = rootViewController
}
```

**Problem:** Uses UIApplication, UIWindowScene, UIWindow, UIHostingController (all UIKit)
**Impact:** Core UI presentation infrastructure incompatible with macOS
**Solution:** Create platform-specific window management layer using protocols

---

## Platform Abstraction Strategy

### 2.1 Architectural Principles

1. **Prefer Protocol Abstraction Over Conditional Compilation**
   - Create platform-agnostic protocols for capabilities (device info, window management)
   - Provide platform-specific implementations in separate files
   - Use conditional compilation only at the implementation boundary

2. **Follow Existing Patterns**
   - The codebase already demonstrates good patterns (e.g., `PlatformColor` in `SystemLog.swift:975-985`)
   - Extend this approach to other platform-specific types

3. **Feature Availability Over Feature Parity**
   - Some iOS features (haptics, Live Activities) are acceptable to disable on macOS
   - Document platform-specific capabilities clearly
   - Gracefully degrade rather than crash

### 2.2 Abstraction Layers

#### **Layer 1: Platform Types** (Foundation)

Create type aliases for platform-specific UI primitives:

```swift
// Sources/AppLibrary/Sources/UI/PlatformTypes.swift

#if canImport(UIKit)
  import UIKit
  public typealias PlatformColor = UIColor
  public typealias PlatformViewController = UIViewController
  public typealias PlatformWindow = UIWindow
  public typealias PlatformApplication = UIApplication
  public typealias PlatformHostingController<Content: View> = UIHostingController<Content>
#elseif canImport(AppKit)
  import AppKit
  public typealias PlatformColor = NSColor
  public typealias PlatformViewController = NSViewController
  public typealias PlatformWindow = NSWindow
  public typealias PlatformApplication = NSApplication
  public typealias PlatformHostingController<Content: View> = NSHostingController<Content>
#endif
```

#### **Layer 2: Capability Protocols** (Abstraction)

Define platform-agnostic interfaces:

```swift
// Sources/AIO/Sources/AIOEngine/Env/PlatformDevice.swift

public protocol PlatformDeviceInfo: Sendable {
  var orientation: AVAudioSession.StereoOrientation { get async }
  func observeOrientationChanges() -> AsyncStream<AVAudioSession.StereoOrientation>
}

// iOS Implementation
#if canImport(UIKit)
public actor IOSDeviceInfo: PlatformDeviceInfo {
  public var orientation: AVAudioSession.StereoOrientation {
    // Use UIDevice.current.orientation
  }

  public func observeOrientationChanges() -> AsyncStream<AVAudioSession.StereoOrientation> {
    // Subscribe to UIDevice.orientationDidChangeNotification
  }
}
#endif

// macOS Implementation
#if os(macOS)
public actor MacOSDeviceInfo: PlatformDeviceInfo {
  public var orientation: AVAudioSession.StereoOrientation {
    // Return .portrait (macOS default)
  }

  public func observeOrientationChanges() -> AsyncStream<AVAudioSession.StereoOrientation> {
    // Return empty stream or observe screen rotation
  }
}
#endif
```

#### **Layer 3: Audio Session Configuration** (Platform-Specific)

```swift
// Sources/AIO/Sources/AIOEngine/Env/AudioSessionConfiguration.swift

extension AVAudioSession {
  func configurePlatformOptions() throws {
    #if os(iOS)
      try setCategory(
        .playAndRecord,
        mode: .default,
        options: [
          .defaultToSpeaker,
          .allowBluetoothA2DP,
          .allowAirPlay,
          .allowBluetoothHFP,
          .overrideMutedMicrophoneInterruption,
        ]
      )
    #elseif os(macOS)
      try setCategory(
        .playAndRecord,
        mode: .default,
        options: []  // Fewer options available on macOS
      )
    #endif

    // Common configuration across platforms
    try setAllowHapticsAndSystemSoundsDuringRecording(true)
    try setPrefersNoInterruptionsFromSystemAlerts(true)
    try setPrefersInterruptionOnRouteDisconnect(false)
  }
}
```

### 2.3 UI Abstraction Strategy

#### **Window Management**

Replace direct UIWindow manipulation with a protocol-based system:

```swift
// Sources/AppLibrary/Sources/UI/PlatformWindowManager.swift

public protocol PlatformWindowManager: AnyObject {
  associatedtype WindowType
  associatedtype ViewControllerType

  func createOverlayWindow<Content: View>(
    content: Content,
    properties: UniversalOverlayProperties
  ) -> WindowType

  func showWindow(_ window: WindowType)
  func hideWindow(_ window: WindowType)
}

// Implementations in separate files:
// - PlatformWindowManager+iOS.swift (UIKit)
// - PlatformWindowManager+macOS.swift (AppKit)
```

#### **Share/Export Actions**

```swift
// Sources/AppLibrary/Sources/AppTarget/Utilities/PlatformShareAction.swift

public struct PlatformShareAction {
  @MainActor
  public static func share(items: [Any], from sourceView: View?) {
    #if os(iOS)
      // Use UIActivityViewController
      let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
      // Present using UIApplication.shared...
    #elseif os(macOS)
      // Use NSSharingService
      guard let urls = items as? [URL] else { return }
      let picker = NSSharingServicePicker(items: urls)
      picker.show(relativeTo: .zero, of: sourceView, preferredEdge: .minY)
    #endif
  }
}
```

---

## Migration Roadmap

### Phase 1: Foundation (Weeks 1-2)
**Goal:** Establish build infrastructure and core abstractions

- [ ] **Update Package.swift files**
  - AIO: Add `.macOS(.v14)` platform target
  - AppLibrary: Fix iOS version to `.v18`, add `.macOS(.v14)`
  - Add platform-specific Swift settings/defines

- [ ] **Create platform abstraction layer**
  - `PlatformTypes.swift` - Type aliases for UI primitives
  - `PlatformDevice.swift` - Device info protocol + implementations
  - `AudioSessionConfiguration.swift` - Platform-specific session options

- [ ] **Update build scripts**
  - Modify `bin/build.sh` to support macOS target
  - Modify `bin/test.sh` to run macOS tests
  - Add `bin/build-mac.sh` for convenience

- [ ] **Xcode workspace updates**
  - Add macOS app target to `Recorder.xcworkspace`
  - Create `Recorder-macOS.entitlements`
  - Create macOS `Info.plist`

**Deliverable:** Codebase compiles for macOS (with features disabled)

### Phase 2: Audio Layer (Weeks 3-5)
**Goal:** Make audio engine fully functional on macOS

- [ ] **Abstract device orientation** (`AudioEnvironmentManager.swift`)
  - Replace direct UIDevice usage with PlatformDeviceInfo protocol
  - Implement macOS-specific orientation provider
  - Test stereo recording orientation handling

- [ ] **Platform-specific audio session configuration**
  - Conditionally compile session options
  - Test microphone input on macOS
  - Verify audio routing (built-in mic, external devices, Bluetooth)

- [ ] **Microphone permissions**
  - Add macOS microphone usage description
  - Test permission request flow on macOS
  - Document permission differences between platforms

- [ ] **Test core recording functionality**
  - Mono recording on macOS
  - Stereo recording on macOS (if hardware supports)
  - Sample rate changes
  - Input device switching

**Deliverable:** Audio recording works on macOS with all engine features

### Phase 3: UI Abstraction (Weeks 6-9)
**Goal:** Make UI layer work on both platforms

- [ ] **Window management** (`OverlayWindow.swift`)
  - Create PlatformWindowManager protocol
  - Implement iOS version (refactor existing code)
  - Implement macOS version using NSWindow
  - Test overlay windows on both platforms

- [ ] **Share functionality** (`ShareAction.swift`)
  - Abstract to PlatformShareAction
  - Implement using UIActivityViewController (iOS)
  - Implement using NSSharingService (macOS)
  - Test file sharing on both platforms

- [ ] **App lifecycle** (`Quit.swift`)
  - Abstract app termination
  - Use UIApplication (iOS) vs NSApplication (macOS)
  - Test graceful shutdown on both platforms

- [ ] **Haptic feedback** (`Haptics.swift`)
  - Already uses CoreHaptics (iOS-only)
  - Add platform check, gracefully no-op on macOS
  - Document as iOS-only feature

- [ ] **Email composition** (`MailView.swift`)
  - **Option A:** Remove feature (simplest)
  - **Option B:** Use mailto: URLs (cross-platform)
  - **Option C:** Platform-specific implementations
  - Decision needed: Consult with product team

**Deliverable:** Full UI functional on both iOS and macOS

### Phase 4: Platform-Specific Features (Weeks 10-12)
**Goal:** Add macOS-native enhancements

- [ ] **macOS app menu**
  - File menu (New, Open, Save, etc.)
  - Edit menu (if applicable)
  - View menu (zoom, full screen)
  - Window menu (minimize, zoom)
  - Help menu

- [ ] **macOS preferences window**
  - Replace iOS settings sheet with native preferences
  - Use NSPreferencePane or SwiftUI SettingsLink

- [ ] **Keyboard shortcuts**
  - ⌘N - New recording
  - ⌘S - Save recording
  - Space - Play/pause
  - ⌘, - Preferences
  - Document all shortcuts

- [ ] **Dock integration**
  - Custom dock menu
  - Badge for recording status
  - Progress indication

- [ ] **Touch Bar support** (if desired)
  - Recording controls in Touch Bar
  - Waveform visualization

**Deliverable:** macOS app feels native to the platform

### Phase 5: Testing & Polish (Weeks 13-15)
**Goal:** Production-ready multiplatform release

- [ ] **Cross-platform testing matrix**
  - iOS 18+ (iPhone, iPad)
  - macOS 14+ (Intel, Apple Silicon)
  - All audio configurations (mono, stereo, various sample rates)
  - All input devices (built-in, USB, Bluetooth)

- [ ] **Performance benchmarking**
  - Recording latency (iOS vs macOS)
  - CPU usage during recording
  - Memory usage patterns
  - Battery impact (iOS)

- [ ] **UI/UX polish**
  - Consistent spacing and layout
  - Platform-appropriate controls
  - Accessibility (VoiceOver, Voice Control)
  - Dark mode support

- [ ] **Documentation updates**
  - Update README with platform requirements
  - Document platform-specific features
  - Create platform comparison matrix
  - Update API documentation

- [ ] **Release preparation**
  - App Store metadata (iOS)
  - Mac App Store metadata (macOS)
  - Screenshots for both platforms
  - Privacy manifest updates

**Deliverable:** Ship-ready multiplatform application

---

## Detailed Implementation Plan

### 4.1 Package.swift Updates

#### **AIO/Package.swift**
```swift
// BEFORE
platforms: [
  .iOS(.v18),
  .macCatalyst(.v18),
]

// AFTER
platforms: [
  .iOS(.v18),
  .macOS(.v14),
  // Optional: Keep macCatalyst if needed
  // .macCatalyst(.v18),
]
```

#### **AppLibrary/Package.swift**
```swift
// BEFORE
platforms: [
  .iOS(.v26)  // ❌ Typo
]

// AFTER
platforms: [
  .iOS(.v18),
  .macOS(.v14),
]

// Update target swift settings
swiftSettings: [
  .define("LIVE_ACTIVITY", .when(platforms: [.iOS])),
  .define("HAPTICS_AVAILABLE", .when(platforms: [.iOS])),
  .define("MESSAGE_UI_AVAILABLE", .when(platforms: [.iOS])),
  .swiftLanguageMode(.v6),
]
```

### 4.2 Audio Session Configuration Changes

**File:** `AIO/Sources/AIOEngine/Env/AudioEnvironmentManager.swift`

```swift
// CURRENT (lines 415-424)
try self.env.session.setCategory(
  .playAndRecord,
  mode: .default,
  options: [
    .defaultToSpeaker,
    .allowBluetoothA2DP,
    .allowAirPlay,
    .allowBluetoothHFP,
    .overrideMutedMicrophoneInterruption,
  ]
)

// PROPOSED CHANGE
#if os(iOS)
  let sessionOptions: AVAudioSession.CategoryOptions = [
    .defaultToSpeaker,
    .allowBluetoothA2DP,
    .allowAirPlay,
    .allowBluetoothHFP,
    .overrideMutedMicrophoneInterruption,
  ]
#elseif os(macOS)
  // macOS has more limited session options
  let sessionOptions: AVAudioSession.CategoryOptions = [
    .allowBluetooth,  // Broader Bluetooth support on macOS
  ]
#endif

try self.env.session.setCategory(
  .playAndRecord,
  mode: .default,
  options: sessionOptions
)
```

### 4.3 Device Orientation Abstraction

**Create:** `AIO/Sources/AIOEngine/Env/PlatformDeviceInfo.swift`

```swift
import AVFAudio
import Foundation

/// Platform-agnostic device information provider
public protocol PlatformDeviceInfo: Sendable {
  /// Current stereo orientation for audio capture
  var currentOrientation: AVAudioSession.StereoOrientation { get async }

  /// Async stream of orientation changes
  func orientationChanges() -> AsyncStream<AVAudioSession.StereoOrientation>
}

// MARK: - iOS Implementation

#if canImport(UIKit)
  import UIKit

  public actor IOSDeviceInfo: PlatformDeviceInfo {
    private var _currentOrientation: AVAudioSession.StereoOrientation = .portrait

    public init() {
      UIDevice.current.beginGeneratingDeviceOrientationNotifications()
      _currentOrientation = Self.mapOrientation(UIDevice.current.orientation)
    }

    public var currentOrientation: AVAudioSession.StereoOrientation {
      _currentOrientation
    }

    public func orientationChanges() -> AsyncStream<AVAudioSession.StereoOrientation> {
      AsyncStream { continuation in
        let task = Task { @MainActor in
          let notifications = NotificationCenter.default.notifications(
            named: UIDevice.orientationDidChangeNotification)

          for await notification in notifications {
            let device = (notification.object as? UIDevice) ?? UIDevice.current
            if let mapped = Self.mapOrientation(device.orientation) {
              await self.update(orientation: mapped)
              continuation.yield(mapped)
            }
          }
        }

        continuation.onTermination = { _ in
          task.cancel()
        }
      }
    }

    private func update(orientation: AVAudioSession.StereoOrientation) {
      _currentOrientation = orientation
    }

    private static func mapOrientation(
      _ orientation: UIDeviceOrientation
    ) -> AVAudioSession.StereoOrientation? {
      switch orientation {
      case .portrait: .portrait
      case .portraitUpsideDown: .portraitUpsideDown
      case .landscapeLeft: .landscapeLeft
      case .landscapeRight: .landscapeRight
      case .faceUp, .faceDown, .unknown: nil
      @unknown default: nil
      }
    }
  }
#endif

// MARK: - macOS Implementation

#if os(macOS)
  public actor MacOSDeviceInfo: PlatformDeviceInfo {
    // macOS devices don't have physical orientation
    // Default to portrait for consistency
    public var currentOrientation: AVAudioSession.StereoOrientation {
      .portrait
    }

    public func orientationChanges() -> AsyncStream<AVAudioSession.StereoOrientation> {
      // Return empty stream - macOS doesn't change orientation
      AsyncStream { continuation in
        continuation.finish()
      }
    }
  }
#endif

// MARK: - Factory

extension PlatformDeviceInfo {
  public static func create() -> any PlatformDeviceInfo {
    #if canImport(UIKit)
      return IOSDeviceInfo()
    #elseif os(macOS)
      return MacOSDeviceInfo()
    #endif
  }
}
```

**Modify:** `AudioEnvironmentManager.swift:356-392`

```swift
// REPLACE existing subscribeToOrientation method
private func subscribeToOrientation(
  _ onChange: @MainActor @escaping (AVAudioSession.StereoOrientation) -> Void
) async {
  let deviceInfo = PlatformDeviceInfo.create()

  // Set initial orientation
  let initial = await deviceInfo.currentOrientation
  await onChange(initial)

  // Subscribe to changes
  for await orientation in deviceInfo.orientationChanges() {
    await onChange(orientation)
  }
}
```

### 4.4 Window Management Abstraction

**Create:** `AppLibrary/Sources/UI/PlatformWindowManager.swift`

```swift
import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

// MARK: - Protocol

public protocol OverlayWindowProvider {
  func createOverlayWindow<Content: View>(
    content: @escaping () -> Content,
    properties: UniversalOverlayProperties
  )
}

// MARK: - iOS Implementation

#if canImport(UIKit)
  public struct IOSOverlayWindowProvider: OverlayWindowProvider {
    public func createOverlayWindow<Content: View>(
      content: @escaping () -> Content,
      properties: UniversalOverlayProperties
    ) {
      guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
        properties.window == nil
      else { return }

      let window = PassThroughWindow(windowScene: windowScene)
      window.isHidden = false
      window.isUserInteractionEnabled = true

      let rootViewController = UIHostingController(
        rootView: UniversalOverlayViews().environment(properties))
      rootViewController.view.backgroundColor = .clear
      window.rootViewController = rootViewController

      properties.window = window
    }
  }

  private class PassThroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      guard let hitView = super.hitTest(point, with: event),
        let rootView = rootViewController?.view
      else { return nil }

      if #available(iOS 18, *) {
        for subview in rootView.subviews.reversed() {
          let pointInSubView = subview.convert(point, from: rootView)
          if subview.hitTest(pointInSubView, with: event) != nil {
            return hitView
          }
        }
        return nil
      } else {
        return hitView == rootView ? nil : hitView
      }
    }
  }
#endif

// MARK: - macOS Implementation

#if os(macOS)
  public struct MacOSOverlayWindowProvider: OverlayWindowProvider {
    public func createOverlayWindow<Content: View>(
      content: @escaping () -> Content,
      properties: UniversalOverlayProperties
    ) {
      guard properties.window == nil else { return }

      let window = PassThroughNSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )

      window.isOpaque = false
      window.backgroundColor = .clear
      window.level = .floating
      window.ignoresMouseEvents = false

      let hostingController = NSHostingController(
        rootView: UniversalOverlayViews().environment(properties))
      window.contentViewController = hostingController

      properties.window = window
      window.orderFrontRegardless()
    }
  }

  private class PassThroughNSWindow: NSWindow {
    // Allow mouse events to pass through transparent areas
    override func mouseDown(with event: NSEvent) {
      // Implement hit testing logic similar to iOS PassThroughWindow
      super.mouseDown(with: event)
    }
  }
#endif

// MARK: - Factory

extension OverlayWindowProvider {
  public static func create() -> OverlayWindowProvider {
    #if canImport(UIKit)
      return IOSOverlayWindowProvider()
    #elseif os(macOS)
      return MacOSOverlayWindowProvider()
    #endif
  }
}
```

**Modify:** `AppLibrary/Sources/UI/OverlayWindow.swift`

```swift
// Update OverlayWindowRoot.body
public var body: some View {
  content
    .environment(properties)
    .onAppear {
      let provider = OverlayWindowProvider.create()
      provider.createOverlayWindow(
        content: { UniversalOverlayViews().environment(properties) },
        properties: properties
      )
    }
}

// Update UniversalOverlayProperties
@Observable
class UniversalOverlayProperties {
  #if canImport(UIKit)
    var window: UIWindow?
  #elseif canImport(AppKit)
    var window: NSWindow?
  #endif

  var views: [OverlayView] = []

  struct OverlayView: Identifiable {
    var id: String = UUID().uuidString
    var view: AnyView
  }
}
```

---

## File-by-File Impact Analysis

### 5.1 No Changes Required (✅ Cross-Platform)

| File | Reason |
|------|--------|
| All database files (GRDB) | Cross-platform by design |
| `FileManager+Documents.swift` | Uses standard FileManager APIs |
| `DatabaseManager.swift` | Platform-agnostic SQLite operations |
| `SystemLog.swift` | Already abstracts UIColor/NSColor |
| Most of `AIOEngine/` core | Uses only AVFoundation (cross-platform) |
| `Sources/AIOEngine/Async/` | Swift concurrency is cross-platform |
| `Sources/AIOEngine/Utils/` | Pure Swift utilities |

### 5.2 Minor Changes Required (🟡 Conditional Compilation)

| File | Changes Needed | Estimated Effort |
|------|----------------|------------------|
| `AudioEnvironmentManager.swift` | Conditional audio session options (lines 415-424) | 2 hours |
| `Haptics.swift` | Add `#if os(iOS)` wrapper | 1 hour |
| `RecordingActivityManager.swift` | Already has fallback; test on macOS | 1 hour |
| `OnShakeModifier.swift` | Add native macOS gesture detection | 4 hours |

### 5.3 Major Changes Required (🔴 Full Abstraction)

| File | Changes Needed | Estimated Effort |
|------|----------------|------------------|
| `AudioEnvironmentManager.swift` | Abstract device orientation (lines 356-391) | 8 hours |
| `OverlayWindow.swift` | Platform window manager protocol | 16 hours |
| `ShareAction.swift` | Platform-specific share implementations | 8 hours |
| `MailView.swift` | Remove or abstract email UI | 4 hours |
| `Quit.swift` | Abstract app termination | 2 hours |

### 5.4 Files Requiring New macOS Versions

| New File | Purpose | Estimated Effort |
|----------|---------|------------------|
| `PlatformDeviceInfo.swift` | Device orientation abstraction | 6 hours |
| `PlatformWindowManager.swift` | Window management abstraction | 12 hours |
| `PlatformShareAction.swift` | Share UI abstraction | 6 hours |
| `PlatformTypes.swift` | Type aliases (Color, ViewController, etc.) | 2 hours |
| `AudioSessionConfiguration.swift` | Platform-specific session setup | 4 hours |

**Total Estimated Development Time:** ~76 hours (approximately 10 working days for core implementation)

---

## Testing Strategy

### 6.1 Test Matrix

| Test Category | iOS | macOS | Priority |
|---------------|-----|-------|----------|
| Audio recording (mono) | ✅ | ✅ | P0 |
| Audio recording (stereo) | ✅ | ✅ | P0 |
| Sample rate changes | ✅ | ✅ | P0 |
| Input device switching | ✅ | ✅ | P0 |
| Bluetooth audio | ✅ | ✅ | P1 |
| Background recording | ✅ | ⚠️ Different model | P1 |
| Microphone permissions | ✅ | ✅ | P0 |
| File saving/loading | ✅ | ✅ | P0 |
| Database operations | ✅ | ✅ | P0 |
| UI responsiveness | ✅ | ✅ | P1 |
| Dark mode | ✅ | ✅ | P1 |
| Accessibility | ✅ | ✅ | P2 |
| Haptic feedback | ✅ | N/A | P2 |
| Live Activities | ✅ | N/A | P2 |

### 6.2 Platform-Specific Test Plans

#### **iOS Testing**
- [ ] iPhone SE (smallest screen)
- [ ] iPhone 15 Pro (standard)
- [ ] iPhone 15 Pro Max (largest screen)
- [ ] iPad Air (tablet UI)
- [ ] iPad Pro 12.9" (large tablet)
- [ ] All orientations (portrait, landscape left/right)
- [ ] Device shake gesture
- [ ] Haptic feedback
- [ ] Live Activities / Dynamic Island
- [ ] Background audio recording
- [ ] CarPlay integration (if applicable)

#### **macOS Testing**
- [ ] Intel Mac (Rosetta compatibility)
- [ ] Apple Silicon Mac (native)
- [ ] Built-in microphone
- [ ] USB audio interface
- [ ] Bluetooth headset
- [ ] Menu bar functionality
- [ ] Keyboard shortcuts
- [ ] Window management (minimize, full screen, multiple windows)
- [ ] System Settings integration
- [ ] Dock menu
- [ ] Touch Bar (if available)

### 6.3 Regression Testing

Add automated tests to catch platform-specific issues:

```swift
// Tests/AIOTests/PlatformTests.swift

import XCTest
@testable import AIOEngine

final class PlatformAudioSessionTests: XCTestCase {
  func testAudioSessionConfigurationDoesNotCrash() async throws {
    let session = AVAudioSession.sharedInstance()

    // This should not crash on any platform
    try await session.configurePlatformOptions()

    XCTAssertEqual(session.category, .playAndRecord)
  }

  #if os(iOS)
  func testIOSSpecificOptions() throws {
    let session = AVAudioSession.sharedInstance()
    XCTAssertTrue(session.categoryOptions.contains(.defaultToSpeaker))
  }
  #endif

  #if os(macOS)
  func testMacOSLimitedOptions() throws {
    let session = AVAudioSession.sharedInstance()
    // macOS should have minimal options
    XCTAssertTrue(session.categoryOptions.isEmpty ||
                  session.categoryOptions.count <= 2)
  }
  #endif
}

final class PlatformDeviceInfoTests: XCTestCase {
  func testDeviceInfoCreation() async {
    let deviceInfo = PlatformDeviceInfo.create()
    let orientation = await deviceInfo.currentOrientation

    // Should always return a valid orientation
    XCTAssertNotNil(orientation)
  }

  #if os(macOS)
  func testMacOSDefaultOrientation() async {
    let deviceInfo = MacOSDeviceInfo()
    let orientation = await deviceInfo.currentOrientation

    // macOS should always return portrait
    XCTAssertEqual(orientation, .portrait)
  }
  #endif
}
```

### 6.4 Performance Benchmarks

Track performance metrics across platforms:

```swift
// Tests/AIOTests/PerformanceTests.swift

import XCTest
@testable import AIOEngine

final class CrossPlatformPerformanceTests: XCTestCase {
  func testRecordingStartupLatency() async throws {
    let engine = try AIOEngine(/* ... */)

    measure {
      try? await engine.startRecording()
    }

    // Acceptable latency: < 100ms on both platforms
  }

  func testAudioProcessingCPUUsage() async throws {
    // Measure CPU usage during active recording
    // iOS target: < 10% CPU on iPhone 15
    // macOS target: < 5% CPU on M1 Mac
  }
}
```

---

## Risk Assessment

### 7.1 High-Risk Areas

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| **Audio session configuration incompatibility** | App crashes on macOS | Medium | Test early with platform-specific options; use try/catch |
| **Window management complexity** | UI doesn't render correctly | Medium | Create abstraction layer early; test frequently |
| **Performance degradation** | Higher CPU/battery usage | Low | Benchmark throughout; no architectural changes to audio pipeline |
| **Permission model differences** | Microphone access fails on macOS | Low | Test permissions early; document differences clearly |

### 7.2 Medium-Risk Areas

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| **Device orientation fallback** | Stereo recording issues on macOS | Medium | Default to portrait; allow manual orientation override |
| **Background recording differences** | macOS app suspends unexpectedly | Medium | Test App Nap behavior; request background execution if needed |
| **Bluetooth audio routing** | Different behavior on macOS | Low | Test with multiple Bluetooth devices; may need platform-specific logic |

### 7.3 Low-Risk Areas

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| **Database compatibility** | GRDB is cross-platform | Very Low | Minimal testing needed |
| **File system operations** | FileManager is consistent | Very Low | Existing code should work |
| **Swift concurrency** | async/await works identically | Very Low | No special handling needed |

### 7.4 Risk Mitigation Strategy

1. **Prototype Early**: Build a minimal macOS version in Phase 1 to validate architectural decisions
2. **Test Continuously**: Run automated tests on both platforms with every commit
3. **Document Platform Differences**: Maintain a living document of platform-specific behaviors
4. **User Feedback Loop**: Release beta versions to gather real-world usage data
5. **Rollback Plan**: Keep iOS and macOS code paths independent to allow disabling macOS if critical issues arise

---

## Appendices

### A. Build Script Updates

#### **bin/build-mac.sh** (New File)
```bash
#!/bin/bash
set -e

echo "Building for macOS..."

# Build AIO package
swift build \
  --package-path ./AIO \
  --configuration release \
  --arch arm64 --arch x86_64

# Build AppLibrary package
swift build \
  --package-path ./AppLibrary \
  --configuration release \
  --arch arm64 --arch x86_64

# Build macOS app (if workspace exists)
if [ -f "Recorder.xcworkspace" ]; then
  xcodebuild \
    -workspace Recorder.xcworkspace \
    -scheme Recorder-macOS \
    -configuration Release \
    -derivedDataPath ./build \
    build
fi

echo "✅ macOS build complete"
```

#### **bin/test-mac.sh** (New File)
```bash
#!/bin/bash
set -e

echo "Running macOS tests..."

# Run AIO tests
swift test \
  --package-path ./AIO \
  --filter AIOTests \
  --enable-code-coverage

# Run AppLibrary tests (if they exist)
swift test \
  --package-path ./AppLibrary \
  --enable-code-coverage

echo "✅ macOS tests complete"
```

### B. Entitlements Files

#### **Recorder-macOS.entitlements** (New File)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- Microphone access -->
  <key>com.apple.security.device.audio-input</key>
  <true/>

  <!-- File access (if needed for saving recordings) -->
  <key>com.apple.security.files.user-selected.read-write</key>
  <true/>

  <!-- iCloud (if syncing recordings) -->
  <key>com.apple.developer.icloud-container-identifiers</key>
  <array>
    <string>iCloud.$(CFBundleIdentifier)</string>
  </array>
  <key>com.apple.developer.ubiquity-container-identifiers</key>
  <array>
    <string>iCloud.$(CFBundleIdentifier)</string>
  </array>

  <!-- Network (if needed for cloud features) -->
  <key>com.apple.security.network.client</key>
  <true/>

  <!-- Hardened runtime -->
  <key>com.apple.security.app-sandbox</key>
  <true/>
</dict>
</plist>
```

#### **Info.plist (macOS)** Additions
```xml
<!-- Add to macOS Info.plist -->
<key>NSMicrophoneUsageDescription</key>
<string>This app needs access to the microphone to record audio.</string>

<key>LSMinimumSystemVersion</key>
<string>14.0</string>

<key>LSApplicationCategoryType</key>
<string>public.app-category.productivity</string>
```

### C. Platform Comparison Matrix

| Feature | iOS | macOS | Notes |
|---------|-----|-------|-------|
| **Audio Recording** | ✅ Full | ✅ Full | Core functionality identical |
| **Stereo Recording** | ✅ Device-dependent | ✅ Device-dependent | Both support if hardware allows |
| **Sample Rates** | ✅ 8kHz - 192kHz | ✅ 8kHz - 192kHz | Same AVFoundation limits |
| **Device Orientation** | ✅ Automatic | ⚠️ Manual/Fixed | iOS has accelerometer |
| **Background Recording** | ✅ Background mode | ⚠️ App Nap handling | Different models |
| **Haptic Feedback** | ✅ Available | ❌ Not available | iOS-only hardware |
| **Live Activities** | ✅ iOS 16.2+ | ❌ Not available | iOS-only feature |
| **Email Sharing** | ✅ MFMailCompose | ⚠️ mailto: URL | Different implementations |
| **Share Sheet** | ✅ UIActivity | ✅ NSSharingService | Different APIs |
| **Window Management** | ✅ UIKit | ✅ AppKit | Platform-specific |
| **Keyboard Shortcuts** | ⚠️ Limited | ✅ Full support | macOS advantage |
| **Menu Bar** | ❌ N/A | ✅ Standard | macOS advantage |
| **Touch/Trackpad** | ✅ Touch | ✅ Trackpad | Different input methods |
| **File System** | ⚠️ Sandboxed | ⚠️ Sandboxed | Both use App Sandbox |

### D. Reference Links

- [AVFoundation Programming Guide](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/)
- [macOS Audio Session Best Practices](https://developer.apple.com/documentation/avfaudio/avaudiosession)
- [Cross-Platform SwiftUI Techniques](https://developer.apple.com/documentation/swiftui)
- [App Sandbox Design Guide (macOS)](https://developer.apple.com/library/archive/documentation/Security/Conceptual/AppSandboxDesignGuide/)

### E. Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| TBD | Target macOS 14+ | Aligns with iOS 18 feature parity; Sonoma required for latest SwiftUI features |
| TBD | Use protocol-based abstraction | More maintainable than conditional compilation everywhere |
| TBD | Disable haptics on macOS | No equivalent hardware; graceful degradation acceptable |
| TBD | Keep Live Activities iOS-only | Platform-specific feature with no macOS equivalent |
| TBD | Email feature decision needed | Three options: remove, mailto: URLs, or platform-specific |

---

## Conclusion

This migration plan provides a comprehensive roadmap for enabling native macOS support while maintaining full iOS functionality. The architecture is sound, with most audio engine code already platform-agnostic. The primary work lies in abstracting UI layer dependencies and handling platform-specific capabilities.

**Key Success Factors:**
1. Early prototyping to validate architectural decisions
2. Incremental migration by layer (foundation → audio → UI → platform-specific)
3. Comprehensive testing on both platforms throughout development
4. Clear documentation of platform differences and limitations

**Estimated Timeline:** 10-15 weeks for full implementation and testing
**Risk Level:** Medium - manageable with proper abstraction and testing
**ROI:** High - expands potential user base to macOS developers and desktop users

---

**Next Steps:**
1. Review and approve this plan with the team
2. Create tracking issues for each phase
3. Set up macOS CI/CD pipeline
4. Begin Phase 1: Foundation work

---

*Document Version: 1.0*
*Last Updated: 2025-11-13*
*Author: AI Planning Assistant*
*Status: Ready for Review*
