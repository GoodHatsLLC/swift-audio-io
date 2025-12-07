# Embedding Backfill Design

**Date:** 2025-11-09
**Status:** Approved

## Overview

Add a backfill task to populate ChromaDB embeddings for existing tracks that have completed transcriptions but no embeddings. Include retry logic that distinguishes between transient failures (which should retry) and permanent failures (which should not).

## Background

Currently, the app creates two SQLite databases:
- **GRDB** - Primary tracking of recordings, transcriptions, classifications
- **ChromaDB** - Vector embeddings for transcript text search

Embeddings are created as a follow-up task after transcription completes, but:
- No backfill exists for embeddings (only for transcriptions/classifications/waveforms)
- No retry logic exists for failed embedding tasks
- No tracking exists to prevent infinite retries of permanently failed embeddings

## Goals

1. Backfill embeddings for all completed transcriptions without embeddings
2. Retry transient failures (network errors, resource issues) with limits
3. Skip permanent failures (invalid input, unsupported platform)
4. Track retry attempts to prevent infinite loops

## Database Schema Changes

### New Columns in `transcriptions` Table

```sql
ALTER TABLE transcriptions ADD COLUMN embeddingStatus TEXT;
ALTER TABLE transcriptions ADD COLUMN embeddingAttempts INTEGER DEFAULT 0;
ALTER TABLE transcriptions ADD COLUMN lastEmbeddingAttempt DATETIME;
ALTER TABLE transcriptions ADD COLUMN embeddingErrorMessage TEXT;
```

**Field Definitions:**

- `embeddingStatus`: Tracks embedding lifecycle
  - `NULL` - Unknown/legacy state, needs checking
  - `'pending'` - Has completed transcription, needs embedding
  - `'completed'` - Successfully embedded in ChromaDB
  - `'failed_permanent'` - Hit retry limit or non-retryable error

- `embeddingAttempts`: Counter for retry attempts (0-3)

- `lastEmbeddingAttempt`: Timestamp of last attempt (for 30min cooldown)

- `embeddingErrorMessage`: Last error message for debugging

**Migration Strategy:**

- Existing records default to `NULL` status
- Backfill will identify and process these legacy records
- New transcriptions set `embeddingStatus = 'pending'` on completion

## Backfill Logic

### Query for Transcriptions Needing Embeddings

```sql
SELECT * FROM transcriptions
WHERE status = 'completed'
  AND text IS NOT NULL
  AND (
    embeddingStatus IS NULL
    OR embeddingStatus = 'pending'
    OR (
      embeddingStatus != 'failed_permanent'
      AND embeddingAttempts < 3
      AND (lastEmbeddingAttempt IS NULL
           OR lastEmbeddingAttempt < datetime('now', '-30 minutes'))
    )
  )
```

**This captures:**
- Completed transcriptions with actual text
- Legacy records (NULL status) never embedded
- Pending embeddings
- Failed embeddings under retry limit that passed cooldown

### New Method in BackfillService

```swift
func backfillEmbeddings() async throws -> Int {
  let transcriptions = try await database.transcriptionsNeedingEmbedding()
  let tasks = transcriptions.map { transcription in
    ProcessingQueue.embeddingTask(
      trackId: transcription.trackId,
      embeddingDB: embeddingDB,
      database: database,
      priority: .low
    )
  }
  await processingQueue.enqueueTasks(tasks)
  return tasks.count
}
```

### Integration Point

Update `BackfillService.startBackfill()` to include:
```swift
let embeddingCount = try await backfillEmbeddings()
```

All embedding tasks created with `.low` priority.

## Error Handling & Retry Logic

### Retry Parameters

- **Max attempts:** 3
- **Cooldown period:** 30 minutes between attempts
- **Error classification:** Distinguish retryable vs permanent failures

### Error Classification

**Non-retryable errors → `failed_permanent`:**
- `EmbeddingDB.Failure.simulator` - Embeddings not supported on simulator
- `EmbeddingDB.Failure.unstarted` - EmbeddingDB not initialized
- Empty or invalid text
- Any validation error indicating bad input

**Retryable errors → increment attempts:**
- ChromaDB connection failures
- Model loading failures
- Out of memory errors
- Generic network/IO errors

### Task Execution Flow

**Before execution:**
```swift
try await database.incrementEmbeddingAttempt(trackId: trackId)
```

**On success:**
```swift
try await database.markEmbeddingCompleted(trackId: trackId)
// Sets embeddingStatus = 'completed', clears embeddingErrorMessage
```

**On error:**
```swift
try await database.handleEmbeddingError(trackId: trackId, error: error)
// Classifies error, updates status/counter/message, logs error
```

**Retry decision logic:**
```swift
if isNonRetryableError(error) {
  embeddingStatus = 'failed_permanent'
} else if embeddingAttempts >= 3 {
  embeddingStatus = 'failed_permanent'
} else {
  embeddingStatus = 'pending' // Will retry after cooldown
}
```

## Integration with New Recordings

### TranscriptionService Changes

When `completeTranscription()` saves a successful transcription:

```swift
transcription.status = .completed
transcription.text = text
transcription.completedAt = Date()
// NEW: Initialize embedding tracking
transcription.embeddingStatus = "pending"
transcription.embeddingAttempts = 0
transcription.lastEmbeddingAttempt = nil
transcription.embeddingErrorMessage = nil
```

### BackgroundProcessor Embedding Task Changes

**Current:**
```swift
if let text = try await database.transcription(for: trackId)?.text {
  try await embeddingDB.addText(text, forDocument: "\(trackId)")
}
```

**New:**
```swift
// Track attempt
try await database.incrementEmbeddingAttempt(trackId: trackId)

do {
  if let text = try await database.transcription(for: trackId)?.text {
    try await embeddingDB.addText(text, forDocument: "\(trackId)")
    try await database.markEmbeddingCompleted(trackId: trackId)
  }
} catch {
  try await database.handleEmbeddingError(trackId: trackId, error: error)
  throw error
}
```

## Implementation Files

### Files to Modify

1. **DatabaseManager.swift**
   - Add migration for 4 new columns
   - Add helper methods:
     - `transcriptionsNeedingEmbedding() async throws -> [Transcription]`
     - `incrementEmbeddingAttempt(trackId:) async throws`
     - `markEmbeddingCompleted(trackId:) async throws`
     - `handleEmbeddingError(trackId:error:) async throws`

2. **Transcription.swift**
   - Add 4 new properties to model
   - Update database mapping

3. **BackfillService.swift**
   - Add `backfillEmbeddings()` method
   - Update `startBackfill()` to call it

4. **BackgroundProcessor.swift**
   - Update `embeddingTask()` with tracking and error handling

5. **TranscriptionService.swift**
   - Update `completeTranscription()` to initialize embedding fields

## Testing Considerations

- Verify backfill finds legacy (NULL status) records
- Verify retry limit enforcement (stops at 3 attempts)
- Verify cooldown period (won't retry within 30 minutes)
- Verify non-retryable errors marked as `failed_permanent`
- Verify successful embedding updates status to `completed`
- Verify new recordings initialize embedding fields correctly
- Test error message storage in `embeddingErrorMessage`

## Success Criteria

1. All completed transcriptions eventually get embeddings (or fail permanently)
2. Transient failures retry up to 3 times with 30min cooldown
3. Permanent failures don't retry indefinitely
4. Error messages are logged and stored for debugging
5. GRDB serves as source of truth for embedding state (no ChromaDB queries needed)
