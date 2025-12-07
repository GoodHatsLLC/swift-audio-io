# Embedding Search Integration Design

**Date:** 2025-11-09
**Status:** Approved

## Overview

Integrate the existing embedding database search functionality into the main tracks page, replacing the non-functional search field with semantic transcript search.

## Goals

- Enable users to search their track transcripts semantically using the existing embedding database
- Provide a smooth development experience with simulator fallback
- Keep UI minimal and focused
- Reuse existing track list UI components

## Architecture Overview

### Core Approach

Enhance the existing tracks page by connecting the search field to the embedding database. The implementation will be view-layer focused, keeping the existing `@Query(TracksRequest())` data loading unchanged and filtering results in SwiftUI.

### Key Components

1. **Search State Management** - Add `@State` properties in `RecorderView` that watch the search field, debounce input, and trigger embedding searches

2. **Dual Search Strategy** - Use `EmbeddingDB.search()` on physical devices, fall back to simple string matching on simulator by searching through `track.transcription?.text`

3. **Track Filtering** - Filter the existing track list based on search results, showing all tracks when search is empty

4. **Minimal UI Changes** - Reuse existing `.searchable()` modifier and track list UI with simple empty state for no results

### Benefits

- Minimal code changes - mostly additive rather than modifying existing working code
- No database schema changes needed - embedding infrastructure already exists
- Simple fallback strategy keeps development workflow smooth
- Easy to test both code paths (device vs simulator)

## Search State Management & Debouncing

### Implementation Details

Add search state to `RecorderView.swift` (which already has the `.searchable(text: $search)` modifier):

1. **Search Binding** - The existing `@State var search: String = ""` binding captures user input
2. **Debounce Timer** - Add `@State var searchTask: Task<Void, Never>?` to manage debounced search
3. **Search Results** - Add `@State var matchingTrackIds: Set<Int64> = []` to store track IDs from embedding search

### Debounce Flow

```
User types → Cancel previous searchTask →
If search is empty: clear results, show all tracks →
If search has text: Start Task with 1-second delay → Execute search → Update matchingTrackIds
```

### Search Execution

```swift
.onChange(of: search) { oldValue, newValue in
  searchTask?.cancel()

  if newValue.isEmpty {
    matchingTrackIds = []  // Show all tracks
    return
  }

  // Only search if there's actual text
  searchTask = Task {
    try? await Task.sleep(for: .seconds(1))
    guard !Task.isCancelled else { return }
    await performSearch(query: newValue)
  }
}
```

### States

- Empty search = show all tracks (matchingTrackIds is empty)
- Non-empty search = show only matching tracks (matchingTrackIds contains IDs from search)

### Cancellation Handling

When user types quickly, previous search tasks are cancelled before completion. Only the final query (after 1 second of no typing) executes the actual search.

## Dual Search Strategy (Device vs Simulator)

### Search Implementation

The `performSearch()` method checks platform capability and routes to the appropriate search strategy:

```swift
func performSearch(query: String) async {
  let useTextSearch = targetEnvironment == .simulator || embeddingDB == nil

  if useTextSearch {
    // Fallback: simple text search through transcriptions
    let results = await searchTranscriptionsLocally(query: query)
    await MainActor.run {
      matchingTrackIds = Set(results)
    }
  } else {
    // Production: embedding-based semantic search
    do {
      let results = try await embeddingDB!.search(text: query, maxResults: 100)
      await MainActor.run {
        matchingTrackIds = Set(results.map { $0.documentID })
      }
    } catch {
      // If embedding search fails, fall back to text search
      let results = await searchTranscriptionsLocally(query: query)
      await MainActor.run {
        matchingTrackIds = Set(results)
      }
    }
  }
}
```

### Simulator Fallback Strategy

For simulator-only builds, search through the existing GRDB tracks:
- Query all tracks that have transcriptions
- Filter where `transcription.text.localizedCaseInsensitiveContains(query)`
- Return matching track IDs
- Simple substring matching (not semantic, but functional for development)

### Device Strategy

On physical devices:
- Call `embeddingDB.search(text: query, maxResults: 100)`
- Extract track IDs from `SearchResult.documentID`
- Limit to 100 results to keep list manageable
- Uses semantic similarity (can find "happy" when searching "joyful")

### Why This Split

Development stays smooth on simulator with basic search, production users get semantic search power. Both paths return the same data structure (Set of track IDs), making the filtering logic identical.

## Track Filtering Logic

### Filtering Implementation

The `TrackList` view currently receives all tracks via `@Query(TracksRequest())`. Add filtering logic that respects the search results.

### In RecorderView.swift

Pass the search state down to `TrackList`:

```swift
TrackList(
  searchActive: !search.isEmpty,
  matchingTrackIds: matchingTrackIds
)
```

### In TrackList.swift

Add properties and filter the displayed tracks:

```swift
let searchActive: Bool
let matchingTrackIds: Set<Int64>

var filteredTracks: [Track] {
  if !searchActive {
    return Array(tracks)  // Show all tracks when no search
  }
  return tracks.filter { matchingTrackIds.contains($0.id) }
}
```

### List Rendering

Replace the current `tracks` iteration with `filteredTracks`:

```swift
List {
  ForEach(tracksByDay(filteredTracks), id: \.day) { section in
    Section(header: Text(section.day)) {
      ForEach(section.tracks) { track in
        TrackRow(track: track)
      }
    }
  }
}
```

### Behavior

- Empty search → `searchActive = false` → show all tracks
- Active search → `searchActive = true` → show only tracks with IDs in `matchingTrackIds`
- Existing day grouping, sorting, and UI all work unchanged

## Edge Cases & Error Handling

### Edge Cases

1. **No Embeddings Exist Yet**
   - Tracks without embeddings won't be returned by `EmbeddingDB.search()`
   - Backfill service runs in background, so early app usage may have incomplete embeddings
   - Behavior: These tracks simply won't appear in search results (acceptable - search only works for embedded content)

2. **Empty Search Results**
   - User searches but no tracks match
   - Behavior: Show "No results found" message using SwiftUI's `ContentUnavailableView`

3. **Search During Embedding**
   - User searches while backfill is still processing
   - Behavior: Only embedded tracks appear in results - partial results are fine

4. **EmbeddingDB Initialization Failure**
   - On device, ChromaDB might fail to initialize
   - Current code: `RecorderCoordinator` already handles this with optional `embeddingDB`
   - Behavior: Fall back to local text search (same as simulator)

### Fallback Guarantees

- Simulator → always text search
- Device with no EmbeddingDB → text search
- Device with EmbeddingDB error → text search
- Users always get some search functionality

### Empty State UI

In `TrackList.swift`, show ContentUnavailableView when search is active but no results:

```swift
if searchActive && filteredTracks.isEmpty {
  ContentUnavailableView(
    "No Results",
    systemImage: "magnifyingglass",
    description: Text("No tracks match your search")
  )
} else {
  List {
    // existing track list
  }
}
```

## Implementation Summary

### Files to Modify

1. **RecorderView.swift**
   - Add `@State var searchTask: Task<Void, Never>?`
   - Add `@State var matchingTrackIds: Set<Int64> = []`
   - Add `.onChange(of: search)` modifier with debounce logic
   - Implement `performSearch(query:)` method
   - Implement `searchTranscriptionsLocally(query:)` method for fallback
   - Pass `searchActive` and `matchingTrackIds` to `TrackList`

2. **TrackList.swift**
   - Add `let searchActive: Bool` property
   - Add `let matchingTrackIds: Set<Int64>` property
   - Add `filteredTracks` computed property
   - Replace `tracks` iteration with `filteredTracks`
   - Add `ContentUnavailableView` for empty search results

### No Changes Needed

- Database schema (already has embedding infrastructure)
- `EmbeddingDB` (existing search API works as-is)
- `TrackRow` (reused without modification)
- `TracksRequest` (keeps loading all tracks)

## Testing Strategy

1. **Simulator Testing**
   - Verify text search fallback works
   - Test debounce behavior
   - Test empty search clears filter
   - Test no results shows empty state

2. **Device Testing**
   - Verify embedding search works
   - Test semantic search (synonyms, related terms)
   - Test with tracks that have/haven't been embedded
   - Test error fallback to text search

## Future Enhancements (Out of Scope)

- Search result relevance scores
- Search result highlighting
- Filename search in addition to transcript search
- Search history or suggestions
- Loading indicators during search
