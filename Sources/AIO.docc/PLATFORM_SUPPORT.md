# Platform Support Documentation

This document describes the platform support for the AIO audio library and how iOS-specific features are abstracted for macOS compatibility.

## Supported Platforms

- **iOS 18.0+**: Full support with all features
- **macOS 14.0+**: Full core audio support with platform-appropriate UI adaptations

## Core Audio Engine (AIOEngine)

The audio engine is fully functional on both platforms with the following platform-specific adaptations:

### Audio Session Configuration

**iOS:**
- Full AVAudioSession category options including:
  - `.defaultToSpeaker` - Route audio to speaker by default
  - `.allowBluetoothA2DP` - Support high-quality Bluetooth audio
  - `.allowAirPlay` - Enable AirPlay streaming
  - `.allowBluetoothHFP` - Support Bluetooth headset protocols
  - `.overrideMutedMicrophoneInterruption` - Allow recording when muted

**macOS:**
- Limited AVAudioSession options:
  - `.allowBluetooth` - General Bluetooth audio support
- Other iOS-specific options are not available on macOS

**Implementation:** Platform-conditional options in `AudioEnvironmentManager.swift`

### Device Orientation

**iOS:**
- Automatic detection of device physical orientation
- Real-time updates when device is rotated
- Used for stereo microphone orientation in handheld recording
- Supports: portrait, portraitUpsideDown, landscapeLeft, landscapeRight

**macOS:**
- Fixed portrait orientation (devices don't rotate)
- Stereo microphone channels use default left/right configuration
- No orientation change notifications

**Implementation:** `PlatformDeviceInfo` protocol with iOS and macOS implementations

### Recording & Playback

Both platforms support:
- ✅ Multi-channel recording (mono, stereo, up to 32 channels)
- ✅ Sample rates from 16 kHz to 192 kHz
- ✅ Multiple file formats (WAV, CAF, AAC, FLAC)
- ✅ Real-time buffer streaming
- ✅ Audio visualization (FFT, waveform analysis)
- ✅ Input device selection
- ✅ Route change handling
- ✅ Interruption management

## Application Layer (AppLibrary)

The application UI layer has platform-specific implementations for system integration:

### Window Management

**iOS:**
- `UIWindow` and `UIWindowScene` based overlay windows
- Pass-through hit testing for transparent areas
- Scene-based window management

**macOS:**
- `NSWindow` based overlay windows
- Floating window level for overlays
- Standard macOS window management

**Implementation:** `OverlayWindow.swift` with conditional compilation

### Sharing

**iOS:**
- `UIActivityViewController` for native iOS share sheet
- Popover presentation on iPad

**macOS:**
- `NSSharingServicePicker` for native macOS sharing
- Standard macOS sharing UI

**Implementation:** `ShareAction.swift` with platform-specific share methods

### Application Lifecycle

**iOS:**
- `UIApplication.shared.perform(#selector(NSXPCConnection.suspend))`
- Graceful backgrounding before exit

**macOS:**
- `NSApplication.shared.terminate(nil)`
- Standard macOS application termination

**Implementation:** `Quit.swift` with platform-specific quit methods

### Gesture Recognition

**iOS:**
- Shake gesture detection via `UIWindow.motionEnded`
- Device motion events

**macOS (Catalyst):**
- Window geometry-based shake detection
- Tracks NSWindow frame movements

**macOS (Native):**
- No-op implementation (shake gestures not applicable)

**Implementation:** `OnShakeModifier.swift` with platform-specific implementations

## Feature Availability Matrix

| Feature | iOS | macOS | Notes |
|---------|-----|-------|-------|
| Audio Recording | ✅ | ✅ | Full support on both platforms |
| Stereo Recording | ✅ | ✅ | Orientation detection differs |
| Playback | ✅ | ✅ | Identical functionality |
| Real-time Visualization | ✅ | ✅ | FFT and waveform analysis |
| Device Orientation | ✅ | ⚠️ | macOS uses fixed portrait |
| Audio Session Options | ✅ | ⚠️ | Limited options on macOS |
| Shake Gesture | ✅ | ❌ | Not applicable on native macOS |
| Share Sheet | ✅ | ✅ | Platform-specific UI |
| Window Overlays | ✅ | ✅ | Platform-specific implementation |
| Background Recording | ✅ | ⚠️ | Different app lifecycle models |
| Bluetooth Audio | ✅ | ✅ | Limited options on macOS |

Legend:
- ✅ Full support
- ⚠️ Partial support or platform differences
- ❌ Not available

## Building for Multiple Platforms

### Package Configuration

Both `AIO/Package.swift` and `AppLibrary/Package.swift` specify platform support:

```swift
platforms: [
  .iOS(.v18),
  .macOS(.v14),
]
```

### Conditional Compilation

The codebase uses standard Swift conditional compilation:

```swift
#if canImport(UIKit) && !os(macOS)
  // iOS-specific code
#elseif os(macOS)
  // macOS-specific code
#endif
```

### Testing

- iOS tests use simulator devices
- macOS tests run natively on Mac hardware
- Both platforms share the same core audio engine tests

## Migration Guide

If you're porting an iOS-only app to macOS:

1. **Update Package.swift**: Add `.macOS(.v14)` to platforms
2. **Review UI code**: Update any UIKit-specific UI code
3. **Test audio session**: Verify recording works with macOS session options
4. **Handle orientation**: Adapt to fixed orientation on macOS
5. **Update gestures**: Replace shake gestures with keyboard shortcuts
6. **Test sharing**: Verify file sharing uses NSSharingService

## Known Limitations

### macOS
- No device orientation changes (uses fixed portrait)
- Fewer AVAudioSession category options
- No shake gesture support on native macOS
- Different background audio handling

### iOS
- App Sandbox restrictions on file access
- Different window management model

## Future Enhancements

Potential improvements for better macOS integration:

- [ ] macOS-specific menu bar integration
- [ ] Keyboard shortcuts for common actions
- [ ] Touch Bar support for recording controls
- [ ] Dock menu with recording status
- [ ] macOS native preferences window
- [ ] Multiple window support on macOS

## See Also

- [README.md](README.md) - General library documentation
- [MULTIPLATFORM.md](MULTIPLATFORM.md) - Detailed migration planning document
- [AIO/Sources/AIOEngine/Env/PlatformDeviceInfo.swift](AIO/Sources/AIOEngine/Env/PlatformDeviceInfo.swift) - Device orientation abstraction
- [AppLibrary/Sources/UI/](AppLibrary/Sources/UI/) - UI layer abstractions
