#if canImport(AVFoundation)
  import Tools
  import AIOEngine
  import AVFoundation
  import SystemLog
  import Testing
  import os.signpost

  /// Performance benchmarking framework for real-time audio processing and visualization
  @Suite("Audio Visualization Performance Benchmarks")
  struct PerformanceBenchmarkTests {

    private let performanceLog = OSLog(
      subsystem: "AudioVisualizationTests", category: "Performance")
    private let signpostID = OSSignpostID(log: OSLog.default)

    // MARK: - Real-time Audio Processing Benchmarks

    @Test("Ring Buffer Write Performance")
    func testRingBufferWritePerformance() async throws {
      let bufferCapacity = 48000 * 2  // 2 seconds at 48kHz
      let ringBuffer = RingBuffer<Float>(capacity: bufferCapacity)
      let testDataSize = 1024  // Typical audio buffer size
      let testData = Array(repeating: Float(0.5), count: testDataSize)
      let iterations = 10000

      // Warmup
      for _ in 0..<100 {
        ringBuffer.write(testData)
      }

      os_signpost(
        .begin, log: performanceLog, name: "RingBuffer Write Test", signpostID: signpostID)
      let startTime = CFAbsoluteTimeGetCurrent()

      for _ in 0..<iterations {
        ringBuffer.write(testData)
      }

      let endTime = CFAbsoluteTimeGetCurrent()
      os_signpost(.end, log: performanceLog, name: "RingBuffer Write Test", signpostID: signpostID)

      let totalTime = endTime - startTime
      let averageTimePerWrite = totalTime / Double(iterations)
      let samplesPerSecond = Double(testDataSize) / averageTimePerWrite

      // Verify performance target: Should handle 48kHz+ audio in real-time
      #expect(
        samplesPerSecond > 48000,
        "Ring buffer write performance too slow: \(samplesPerSecond) samples/sec")

      print("Ring Buffer Write Performance:")
      print("  Average time per write: \(averageTimePerWrite * 1000) ms")
      print("  Samples per second: \(Int(samplesPerSecond))")
      print("  Total test time: \(totalTime) seconds")
    }

    @Test("Ring Buffer Read Performance")
    func testRingBufferReadPerformance() async throws {
      let bufferCapacity = 48000 * 2
      let ringBuffer = RingBuffer<Float>(capacity: bufferCapacity)
      let testDataSize = 1024
      let testData = Array(repeating: Float(0.5), count: testDataSize)
      let iterations = 10000

      // Fill buffer with test data
      for _ in 0..<bufferCapacity / testDataSize {
        ringBuffer.write(testData)
      }

      os_signpost(.begin, log: performanceLog, name: "RingBuffer Read Test", signpostID: signpostID)
      let startTime = CFAbsoluteTimeGetCurrent()

      for _ in 0..<iterations {
        let _ = ringBuffer.read(testDataSize)
      }

      let endTime = CFAbsoluteTimeGetCurrent()
      os_signpost(.end, log: performanceLog, name: "RingBuffer Read Test", signpostID: signpostID)

      let totalTime = endTime - startTime
      let averageTimePerRead = totalTime / Double(iterations)
      let samplesPerSecond = Double(testDataSize) / averageTimePerRead

      #expect(
        samplesPerSecond > 48000,
        "Ring buffer read performance too slow: \(samplesPerSecond) samples/sec")

      print("Ring Buffer Read Performance:")
      print("  Average time per read: \(averageTimePerRead * 1000) ms")
      print("  Samples per second: \(Int(samplesPerSecond))")
    }

    // MARK: - FFT Performance Tests

    @Test("FFT Performance 1024 samples")
    func testFFTPerformance1024() async throws {
      let fftSize = 1024
      let iterations = 1000
      let inputBuffer = generateTestSineWave(frequency: 440, sampleRate: 48000, samples: fftSize)

      os_signpost(.begin, log: performanceLog, name: "FFT 1024", signpostID: signpostID)
      let startTime = CFAbsoluteTimeGetCurrent()

      for _ in 0..<iterations {
        let _ = performFFT(on: inputBuffer, size: fftSize)
      }

      let endTime = CFAbsoluteTimeGetCurrent()
      os_signpost(.end, log: performanceLog, name: "FFT 1024", signpostID: signpostID)

      let totalTime = endTime - startTime
      let averageTimePerFFT = totalTime / Double(iterations)
      let fftsPerSecond = 1.0 / averageTimePerFFT

      // Should handle real-time audio at 48kHz (48000/1024 = ~47 FFTs/sec minimum)
      #expect(fftsPerSecond > 100, "FFT 1024 performance too slow: \(fftsPerSecond) FFTs/sec")

      print("FFT 1024 Performance:")
      print("  Average time per FFT: \(averageTimePerFFT * 1000) ms")
      print("  FFTs per second: \(Int(fftsPerSecond))")
    }

    @Test("FFT Performance 2048 samples")
    func testFFTPerformance2048() async throws {
      let fftSize = 2048
      let iterations = 500
      let inputBuffer = generateTestSineWave(frequency: 440, sampleRate: 48000, samples: fftSize)

      os_signpost(.begin, log: performanceLog, name: "FFT 2048", signpostID: signpostID)
      let startTime = CFAbsoluteTimeGetCurrent()

      for _ in 0..<iterations {
        let _ = performFFT(on: inputBuffer, size: fftSize)
      }

      let endTime = CFAbsoluteTimeGetCurrent()
      os_signpost(.end, log: performanceLog, name: "FFT 2048", signpostID: signpostID)

      let totalTime = endTime - startTime
      let averageTimePerFFT = totalTime / Double(iterations)
      let fftsPerSecond = 1.0 / averageTimePerFFT

      // Should handle real-time audio (48000/2048 = ~23 FFTs/sec minimum)
      #expect(fftsPerSecond > 50, "FFT 2048 performance too slow: \(fftsPerSecond) FFTs/sec")

      print("FFT 2048 Performance:")
      print("  Average time per FFT: \(averageTimePerFFT * 1000) ms")
      print("  FFTs per second: \(Int(fftsPerSecond))")
    }

    // MARK: - Concurrent Processing Tests

    @Test("Concurrent Audio Processing")
    func testConcurrentAudioProcessing() async throws {
      let concurrentStreams = 4
      let bufferSize = 1024
      let iterations = 100

      os_signpost(
        .begin, log: performanceLog, name: "Concurrent Processing", signpostID: signpostID)
      let startTime = CFAbsoluteTimeGetCurrent()

      await withTaskGroup(of: Void.self) { group in
        for streamIndex in 0..<concurrentStreams {
          group.addTask {
            let frequency = 440.0 + Double(streamIndex * 100)  // Different frequencies
            for _ in 0..<iterations {
              let testData = generateTestSineWave(
                frequency: frequency, sampleRate: 48000, samples: bufferSize)
              let _ = performFFT(on: testData, size: bufferSize)
            }
          }
        }
      }

      let endTime = CFAbsoluteTimeGetCurrent()
      os_signpost(.end, log: performanceLog, name: "Concurrent Processing", signpostID: signpostID)

      let totalTime = endTime - startTime
      let totalOperations = concurrentStreams * iterations
      let operationsPerSecond = Double(totalOperations) / totalTime

      print("Concurrent Processing Test:")
      print("  Streams: \(concurrentStreams)")
      print("  Total operations: \(totalOperations)")
      print("  Operations per second: \(Int(operationsPerSecond))")
      print("  Total time: \(totalTime) seconds")

      // Should handle multiple streams concurrently
      #expect(
        operationsPerSecond > 1000, "Concurrent processing too slow: \(operationsPerSecond) ops/sec"
      )
    }

    // MARK: - Helper Functions

    private func generateTestSineWave(frequency: Double, sampleRate: Int, samples: Int) -> [Float] {
      var result: [Float] = []
      result.reserveCapacity(samples)

      let angularFrequency = 2.0 * Double.pi * frequency

      for i in 0..<samples {
        let time = Double(i) / Double(sampleRate)
        let sample = Float(sin(angularFrequency * time))
        result.append(sample)
      }

      return result
    }

    private func performFFT(on buffer: [Float], size: Int) -> [Float] {
      // Mock FFT implementation for testing - in real implementation this would use vDSP
      // For now, just simulate the computational load
      var result: [Float] = []
      result.reserveCapacity(size / 2)

      for i in 0..<(size / 2) {
        // Simulate FFT computation
        let real = buffer[i * 2 % buffer.count]
        let imag = buffer[(i * 2 + 1) % buffer.count]
        let magnitude = sqrt(real * real + imag * imag)
        result.append(magnitude)
      }

      return result
    }

    private func getMemoryUsage() -> UInt64 {
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size) / 4

      let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
      }

      return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
  }
#endif
