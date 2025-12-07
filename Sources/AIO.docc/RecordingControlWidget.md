# Recording Control Widget

iOS 18+ Control Center widget for toggling audio recording.

## Setup Instructions

### Adding the Widget Target to Xcode

1. Open `Recorder‽.xcodeproj` in Xcode
2. Select the project in the navigator
3. Click the "+" button at the bottom of the targets list
4. Choose "Widget Extension" template
5. Configure the extension:
   - **Product Name**: RecordingControlWidget
   - **Bundle Identifier**: ghl.rec.RecordingControlWidget (or your app's bundle ID + .RecordingControlWidget)
   - **Team**: Select your development team
   - **Language**: Swift
   - **Include Configuration Intent**: No (not needed for Control widgets)

6. When prompted "Activate scheme?", click **Activate**

7. Configure the target settings:
   - **Deployment Target**: iOS 18.0 or later
   - **Signing & Capabilities**:
     - Enable "App Groups" capability
     - Add the app group: `group.99FKXWHBZ8.ghl.rec`

8. Replace the generated files with the ones in this directory:
   - `RecordingControlWidget.swift`
   - `RecordingControlWidgetBundle.swift`
   - `Info.plist`
   - `RecordingControlWidget.entitlements`

9. Add dependency to AppTarget framework:
   - Select the RecordingControlWidget target
   - Go to "Build Phases" → "Link Binary With Libraries"
   - Click "+" and add `AppTarget` framework

### Files Overview

- **RecordingControlWidget.swift**: Main Control widget implementation using iOS 18 ControlWidget API
- **RecordingControlWidgetBundle.swift**: Widget bundle entry point
- **RecordingControlWidget.entitlements**: App Groups configuration for shared state
- **Info.plist**: Extension configuration

### How It Works

The Control widget communicates with the main app through:

1. **App Groups**: Shared UserDefaults container (`group.99FKXWHBZ8.ghl.rec`)
2. **RecordingStateManager**: Singleton that manages recording state across processes
3. **AppIntents**: Toggle action using `SetValueIntent` for Control Center integration

When the user toggles the Control widget:
1. Widget calls `ToggleRecordingIntent`
2. Intent updates shared UserDefaults
3. Main app observes changes via `RecordingStateManager`
4. App starts/stops recording automatically
5. Widget reloads to reflect new state

### Testing

1. Build and run the app on a physical device running iOS 18+
2. Open Control Center (swipe down from top-right on iPhone with notch)
3. Tap "Edit" (plus icon in top-right)
4. Find "Recording Toggle" in the list of available controls
5. Tap the green "+" button to add it
6. Exit Control Center and open it again
7. Tap the "Recording Toggle" to start/stop recording

### Requirements

- iOS 18.0 or later
- Xcode 16.0 or later
- Physical device (widgets don't work properly in Simulator)

### Architecture

```
┌─────────────────────────────────────────┐
│     Control Center Widget               │
│  ┌───────────────────────────────────┐  │
│  │  RecordingControlWidget           │  │
│  │  (ControlWidget)                  │  │
│  └─────────────┬─────────────────────┘  │
│                │                         │
│                │ ToggleRecordingIntent   │
│                │                         │
└────────────────┼─────────────────────────┘
                 │
                 ↓
┌─────────────────────────────────────────┐
│    App Group UserDefaults               │
│    group.99FKXWHBZ8.ghl.rec             │
│                                          │
│    Key: com.ghl.rec.recordingState      │
│    Value: Bool                          │
└─────────────────────────────────────────┘
                 ↑
                 │
                 │ Observes
                 │
┌────────────────┼─────────────────────────┐
│                │                         │
│    ┌───────────▼─────────────────┐      │
│    │  RecordingStateManager      │      │
│    │  (Singleton, Observable)    │      │
│    └─────────────┬───────────────┘      │
│                  │                       │
│                  │ Updates               │
│                  ↓                       │
│    ┌─────────────────────────────────┐  │
│    │       RecorderView              │  │
│    │       (Main App UI)             │  │
│    │                                 │  │
│    │  • Starts/stops recording      │  │
│    │  • Manages AIOEngine           │  │
│    │  • Shows recording sheet       │  │
│    └─────────────────────────────────┘  │
│                                          │
│          Main App                        │
└─────────────────────────────────────────┘
```

### Troubleshooting

**Widget doesn't appear in Control Center**
- Ensure deployment target is iOS 18.0 or later
- Check that App Groups capability is properly configured
- Rebuild and reinstall the app

**Recording doesn't start/stop from widget**
- Verify App Group identifier matches in all entitlements files
- Check that RecordingStateManager is properly observing UserDefaults changes
- Ensure the main app is running or recently active

**Build errors about missing modules**
- Make sure AppTarget framework is linked in Build Phases
- Clean build folder (Cmd+Shift+K) and rebuild
