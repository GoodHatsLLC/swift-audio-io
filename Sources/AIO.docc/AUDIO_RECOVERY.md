# Audio File Recovery System

## Overview

The audio recorder app includes a crash recovery system that can detect and recover recordings that were interrupted due to app crashes or unexpected terminations. This document explains how the recovery system works and how to extend it to support additional audio file formats.

## How It Works

### 1. Recording State Tracking

When a recording starts, the app writes a record to the `active_recordings` database table **before** creating the audio file. This record includes:
- Filename
- File format (e.g., "adts", "caf", "wav")
- Temporary file path
- Start timestamp

When a recording completes successfully, the record is removed from the `active_recordings` table.

### 2. Crash Detection

On app startup, the `RecoveryService` checks the `active_recordings` table:
- If the table is empty, no crash occurred
- If records exist, they represent recordings that were interrupted

### 3. File Recovery

For each interrupted recording, the recovery service:
1. Checks if the temporary file still exists
2. Validates the file format is recoverable
3. Attempts to open and validate the audio file
4. Either saves the recovered file or deletes corrupted data

## Architecture

### Components

#### 1. DatabaseManager (`AppLibrary/Sources/AppTarget/Database/DatabaseManager.swift`)
- Manages the `active_recordings` table
- Methods: `markRecordingStarted()`, `markRecordingCompleted()`, `getActiveRecordings()`

#### 2. ActiveRecording Model (`AppLibrary/Sources/AppTarget/Database/ActiveRecording.swift`)
- Database model representing an in-progress recording
- Fields: `id`, `filename`, `fileFormat`, `tempURL`, `startedAt`

#### 3. RecordingStateTracker (`AppLibrary/Sources/AppTarget/Services/RecordingStateTracker.swift`)
- Actor that manages recording lifecycle state
- Communicates between AIOEngine and DatabaseManager
- Methods: `markRecordingStarted()`, `markRecordingCompleted()`, `markRecordingInterrupted()`

#### 4. RecoveryService (`AppLibrary/Sources/AppTarget/Services/RecoveryService.swift`)
- Performs crash detection and file recovery on app startup
- Validates file recoverability based on format
- Main method: `performStartupRecovery()`

#### 5. AIOEngine Callbacks (`AIO/Sources/AIOEngine/AIOEngine.swift`)
- `onRecordingStarted`: Called when recording file is about to be created
- `onRecordingCompleted`: Called when recording stops successfully
- `onRecordingFailed`: Called when recording is interrupted

### Flow Diagram

```
User starts recording
    ↓
AIOEngine.warm() generates temp file URL
    ↓
onRecordingStarted callback fires
    ↓
RecordingStateTracker.markRecordingStarted()
    ↓
DatabaseManager writes to active_recordings table
    ↓
AVAudioFile is created and recording proceeds
    ↓
[App crashes or recording completes normally]
    ↓
If crash: active_recordings table still has entry
If success: onRecordingCompleted → entry removed
    ↓
On next app startup:
    ↓
RecoveryService.performStartupRecovery()
    ↓
Checks active_recordings table for orphaned entries
    ↓
Attempts to recover files based on format capabilities
```

## Currently Supported Formats

### ADTS (AAC) - ✅ Fully Recoverable

**Why it's recoverable:**
- ADTS (Audio Data Transport Stream) is a streaming format
- Each AAC frame is self-contained with its own header
- Files can be played even if never properly closed
- AVAudioFile can read partial ADTS files

**Implementation:**
```swift
case .adts, .aac:
  return true  // Streaming format, fully recoverable
```

**Minimum viable recording:** 1 second of audio

### WAV / AIFF - 🔶 Best-Effort Recoverable

**Why it’s only best-effort:**
- WAV/AIFF are chunk-based container formats that can be left with incorrect size fields after a crash.
- The underlying audio data can still be intact, but readers may reject the file if the header sizes are inconsistent.

**Implementation:**
- The recovery flow attempts to open via `AVAudioFile(forReading:)`.
- If open fails, RecoveryService performs a lightweight header-size repair (via `AudioFileRecoveryKit`) and retries:
  - WAV: RIFF chunk size + `data` chunk size (little-endian)
  - AIFF: FORM chunk size + `SSND` chunk size (big-endian)

### CAF (Core Audio Format) - 🔶 Best-Effort Recoverable

**Implementation:**
- CAF is attempted via `AVAudioFile(forReading:)` (no header repair yet).

### FLAC / MP3 / M4A - 🔶 Best-Effort Import (When Readable)

**Notes:**
- These formats are attempted when encountered in the temp directory or `active_recordings`.
- If the container wasn’t finalized correctly (especially M4A), `AVAudioFile` may not be able to open it.

## Extending to Other Formats

### Format Recovery Requirements

For a format to be recoverable, it must meet one or more of these criteria:

1. **Streaming format**: Frames are self-contained (like ADTS)
2. **Fixed headers**: Header is written at file creation (may need repair)
3. **Chunk-based**: Data is organized in independent chunks
4. **Readable by AVAudioFile**: Can be opened even if incomplete

### Format-Specific Recovery Strategies

#### CAF (Core Audio Format) - 🔶 Potentially Recoverable

**Format characteristics:**
- Chunk-based format (similar to WAV/RIFF)
- Header describes audio format and data layout
- Audio data is in sequential chunks
- File size fields in header may be incorrect for interrupted files

**Recovery strategy:**
```swift
case "caf":
  // 1. Read the file with AVAudioFile
  // 2. Check if audio data chunks exist
  // 3. Potentially repair the header size fields
  // 4. Verify minimum duration threshold
  return true  // With header repair
```

**Implementation steps:**
1. Update `canRecoverFormat()` to return `true` for CAF
2. Add CAF-specific validation in `validateAudioFile()`
3. Consider implementing header repair (advanced)

**Challenges:**
- AVAudioFile may reject CAF files with incorrect size metadata
- May require manual header repair before AVAudioFile can open it

#### WAV (Waveform Audio File Format) - 🔶 Potentially Recoverable

**Format characteristics:**
- RIFF chunk-based format
- Header contains file size in RIFF chunk
- Data chunk contains actual audio samples
- Linear PCM data is sequential and doesn't require closing

**Recovery strategy:**
```swift
case "wav":
  // Similar to CAF - chunk-based with size metadata
  // May need header repair to fix RIFF and data chunk sizes
  return true  // With header repair
```

**Implementation approach:**
1. Check if AVAudioFile can open the partial file
2. If not, implement header repair:
   - Read actual file size
   - Update RIFF chunk size (bytes 4-7)
   - Update data chunk size
   - Rewrite header
3. Validate with AVAudioFile

**Code example for header repair:**
```swift
func repairWAVHeader(at url: URL) throws {
  let fileHandle = try FileHandle(forUpdating: url)
  defer { try? fileHandle.close() }

  // Get actual file size
  let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! UInt64

  // Calculate RIFF chunk size (file size - 8)
  let riffSize = UInt32(fileSize - 8)

  // Seek to byte 4 and write RIFF chunk size (little-endian)
  fileHandle.seek(toFileOffset: 4)
  var riffSizeLE = riffSize.littleEndian
  fileHandle.write(Data(bytes: &riffSizeLE, count: 4))

  // Find and update data chunk size (requires parsing)
  // ... (implementation depends on WAV structure)
}
```

#### M4A (MPEG-4 Audio) - ❌ Not Recoverable (Non-streaming)

**Format characteristics:**
- Container format with complex metadata
- Requires proper finalization to write file tables
- Audio data references require complete atom structure
- AVAudioFile typically cannot open incomplete M4A files

**Why not recoverable:**
- M4A uses ISO Base Media File Format (similar to MP4)
- Critical metadata (moov atom) is typically written at file end
- Without moov atom, file structure is incomplete
- Would require complex atom reconstruction

**Recommendation:** Use ADTS for AAC if recovery is needed

#### FLAC - 🔶 Potentially Recoverable

**Format characteristics:**
- Streamable format with independent frames
- Metadata blocks at start of file
- Audio frames are self-contained
- Some parsers can handle incomplete files

**Recovery strategy:**
```swift
case "flac":
  // FLAC frames are independent
  // May be recoverable if AVAudioFile can parse partial streams
  return true  // Test required
```

**Implementation steps:**
1. Test if AVAudioFile can open incomplete FLAC files
2. If yes, add to recoverable formats
3. Set minimum duration threshold (e.g., 1 second)

### Adding a New Recoverable Format

To add recovery support for a new format:

#### Step 1: Update `canRecoverFormat()` in RecoveryService

```swift
private func canRecoverFormat(_ format: String) -> Bool {
  switch format.lowercased() {
  case "adts", "aac":
    return true

  case "caf", "wav", "aif", "aiff", "m4a", "flac", "mp3":
    return true

  default:
    return false
  }
}
```

#### Step 2: Add Format-Specific Validation (Optional)

If the format needs special validation logic:

```swift
private func validateAudioFile(_ url: URL, format: String) async -> Bool {
  // Special handling for your format
  if format.lowercased() == "your_format" {
    return await validateYourFormat(url)
  }

  // Default validation
  do {
    let audioFile = try AVAudioFile(forReading: url)
    // ... existing validation
  } catch {
    return false
  }
}

private func validateYourFormat(_ url: URL) async -> Bool {
  // Custom validation logic
  // e.g., check file headers, validate frame structure
  return true
}
```

#### Step 3: Implement Header Repair (Advanced)

For formats that require header repair (CAF, WAV):

```swift
private func repairHeaderIfNeeded(_ url: URL, format: String) throws {
  switch format.lowercased() {
  case "caf":
    try repairCAFHeader(url)
  case "wav":
    try repairWAVHeader(url)
  default:
    break
  }
}

private func repairCAFHeader(_ url: URL) throws {
  // Implementation specific to CAF format
  // Update chunk sizes, file length metadata, etc.
}
```

#### Step 4: Update Recovery Flow

Modify `recoverRecording()` to call repair before validation:

```swift
private func recoverRecording(_ recording: ActiveRecording) async {
  // ... existing code ...

  // Attempt header repair if needed
  do {
    try repairHeaderIfNeeded(tempURL, format: recording.fileFormat)
  } catch {
    syslog.warning("Header repair failed: \(error)")
  }

  // Validate the file can be opened
  let isValid = await validateAudioFile(tempURL, format: recording.fileFormat)

  // ... rest of recovery logic ...
}
```

#### Step 5: Test the Recovery

1. Start a recording in the new format
2. Force-quit the app mid-recording (iOS: swipe up in app switcher)
3. Relaunch the app
4. Check logs for recovery messages
5. Verify the recovered file appears in the library with "Recovered -" prefix

### Format Recoverability Matrix

| Format | Recoverability | Reason | Implementation Effort |
|--------|---------------|--------|---------------------|
| ADTS/AAC | ✅ Yes | Streaming format | Already implemented |
| WAV | 🔶 Best-effort | Chunk-based; header size repair | Medium |
| AIFF | 🔶 Best-effort | Chunk-based; header size repair | Medium |
| CAF | 🔶 Best-effort | Chunk-based; open-only for now | Low-Medium |
| FLAC | 🔶 Best-effort | Frame-based; open-only | Low |
| MP3 | 🔶 Best-effort | Frame-based; open-only | Low |
| M4A | 🔶 Best-effort | Works if finalized; otherwise fails | Low |

## Configuration

### Minimum Recording Duration

The recovery service validates that recovered files meet a minimum duration threshold:

```swift
// In validateAudioFile()
if format.lowercased() == "adts" || format.lowercased() == "aac" {
  let durationSeconds = Double(frameLength) / sampleRate
  return durationSeconds >= 1.0  // Minimum 1 second
}
```

Adjust this threshold per format in the validation logic.

### Cleanup Behavior

The recovery service has two behaviors for interrupted recordings:

1. **Recoverable files**: Saved to documents directory with "Recovered -" prefix
2. **Corrupted files**: Deleted from temp directory

To change the behavior, modify `cleanupFailedRecording()`.

## Testing Recovery

### Manual Testing

1. Start a recording
2. Force quit the app:
   - iOS: Swipe up in app switcher during recording
   - Simulator: Cmd+Q
3. Relaunch app
4. Check logs for recovery messages
5. Verify recovered file appears in library

### Simulating Different Scenarios

**Successful recovery:**
```
1. Record for 5+ seconds in ADTS format
2. Force quit
3. Relaunch → file should be recovered
```

**Too short to recover:**
```
1. Record for <1 second in ADTS format
2. Force quit
3. Relaunch → file should be deleted
```

**Unsupported format:**
```
1. Change default format to M4A (in OutputConfigurationManager)
2. Record for 5+ seconds
3. Force quit
4. Relaunch → file should be deleted with warning
```

### Log Messages

Look for these log messages in Console.app (filter for "Recorder"):

```
🔍 Checking for interrupted recordings...
✅ No interrupted recordings found

OR

🚨 Found 1 interrupted recording(s)
🔧 Attempting to recover: UUID.aac (adts)
✅ File is valid and recoverable, saving to library
✅ Successfully recovered recording as track ID 42

OR

⚠️ Format 'm4a' is not currently recoverable, deleting partial file
🗑️ Deleted corrupted file at /path/to/file.m4a
```

## Troubleshooting

### File not recovered after crash

**Check:**
1. Was `active_recordings` table entry created? (Check database)
2. Does the temp file still exist? (May have been cleaned by iOS)
3. Is the format listed as recoverable?
4. Does the file pass validation?

**Debug:**
```swift
// Add logging to performStartupRecovery()
syslog.info("Active recordings: \(activeRecordings)")
syslog.info("File exists: \(FileManager.default.fileExists(atPath: tempURL.path))")
```

### Recovered file won't play

**Possible causes:**
1. File is too short (< minimum duration)
2. Audio data is corrupted
3. Header repair needed but not implemented

**Solution:**
- Check file duration in validation
- Implement header repair for the format
- Adjust minimum duration threshold

### Database migration fails

**Error:** "Table 'active_recordings' already exists"

**Solution:**
- The migration system is idempotent
- Check migration name in `DatabaseManager.swift` is unique
- If testing, delete app and reinstall

## Best Practices

1. **Always use ADTS for critical recordings** - It's the most reliable recoverable format
2. **Test recovery** for each format you add support for
3. **Set appropriate minimum durations** - Very short clips may not be worth recovering
4. **Monitor temp directory size** - Call `cleanupAllTempFiles()` periodically if needed
5. **Log recovery operations** - Help users understand what happened

## Future Enhancements

Potential improvements to the recovery system:

1. **User notification** - Show alert when recovered files are found
2. **Preview before saving** - Let users preview and choose whether to keep
3. **Partial transcription** - Attempt transcription on recovered files
4. **Automatic format repair** - Implement CAF/WAV header repair
5. **Recovery statistics** - Track recovery success rates
6. **Scheduled cleanup** - Automatic temp file cleanup after N days

## References

- [ADTS Specification](https://wiki.multimedia.cx/index.php/ADTS)
- [CAF Specification](https://developer.apple.com/library/archive/documentation/MusicAudio/Reference/CAFSpec/)
- [WAV/RIFF Specification](http://soundfile.sapp.org/doc/WaveFormat/)
- [AVAudioFile Documentation](https://developer.apple.com/documentation/avfaudio/avaudiofile)
