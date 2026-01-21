# ``AIO``

@Metadata {
  @TechnologyRoot
}

This document provides a comprehensive overview of the **Recorder‽** project, a Swift-based audio recording application for iOS. It serves as a central source of information for understanding the project's architecture, components, and development practices.

## Project Overview

**Recorder‽** is an advanced audio recording application that leverages a custom-built audio engine, `AIOEngine`, to provide real-time audio processing, recording, and playback capabilities. The application is built with Swift 6 and utilizes modern concurrency features.

The application's architecture is based on the **MVVM (Model-View-ViewModel)** design pattern and features a modular structure that separates the core audio engine from the application's UI and business logic.

### Key Technologies

*   **Swift 6:** The primary programming language for the application.
*   **AIOEngine:** A custom-built audio engine for recording and playback, built on top of `AVFoundation`.
*   **GRDB:** A Swift wrapper for SQLite, used for data persistence.
*   **FluidAudio:** An on-device neural speech recognition library.
*   **SwiftUI:** The framework used for building the user interface.
*   **swift-testing:** The framework used for testing.

## Topics

### Essentials

- <doc:Development>
- <doc:Architecture>
- <doc:Features>

## AIOEngine

`AIOEngine` is a Swift 6 concurrency-safe audio recording and playback engine built on AVFoundation. It provides low-level audio I/O primitives with real-time buffer streaming, leaving higher-level concerns like file management, UI, and data persistence to consuming applications.

### What AIOEngine Provides

*   **Core Audio I/O:** Real-time recording and playback with support for multiple formats, sample rates, and bit depths.
*   **Audio Session Management:** A thin wrapper around `AVAudioSession` for hardware monitoring and configuration.
*   **Interruption Handling:** Graceful handling of audio session disruptions like phone calls or route changes.
*   **Real-time Visualization:** FFT-based spectrum analysis and waveform amplitude tracking.
*   **Error Management:** A robust error handling system with an observable error queue.
*   **Concurrency Primitives:** Reusable utilities for concurrent programming.

### Design Philosophy

*   **Primitives Over Frameworks:** Provides low-level, composable building blocks.
*   **Explicit Over Implicit:** Configuration is explicit, with no global state or singletons.
*   **Concurrency-First:** Built for Swift 6 strict concurrency.
*   **Real-time Friendly:** Lock-free data structures and non-isolated callbacks for audio thread.
*   **Testable:** Pure functions, protocol-based abstractions, and dependency injection.

## Recorder‽ Application

The **Recorder‽** application is a demo app that showcases the capabilities of the `AIOEngine`. It's a full-featured audio recording application with features like:

*   Real-time visualization
*   Automatic transcription
*   Sound classification
*   Semantic search

### Architecture

The application follows the **MVVM (Model-View-ViewModel)** design pattern and is structured into several modules:

*   **AppTarget:** The main application logic, including the database, services, and UI components.
*   **UI:** Reusable UI components.
*   **ExtensionLib:** Support for widgets and Live Activities.

### Core Dependencies

*   **AIOEngine:** The custom-built audio engine.
*   **GRDB:** For SQLite database management.
*   **FluidAudio:** For on-device speech recognition.
*   **AsyncAlgorithms:** For concurrency utilities.
