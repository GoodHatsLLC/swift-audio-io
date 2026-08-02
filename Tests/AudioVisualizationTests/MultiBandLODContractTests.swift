// © GoodHatsLLC

#if canImport(AVFoundation)
  import AudioIO
  import AudioSignals
  import Testing

  struct MultiBandLODContractTests {
    @Test
    func `existing snapshot conformers default to the live circular timeline`() {
      let snapshot: any LODSnapshot = LegacyLODSnapshot()

      #expect(snapshot.timelineLayout == .liveCircular)
    }

    @Test
    func `static timeline availability is clamped to its total length`() {
      let snapshot = MultiBandLODSnapshot(
        bands: [BandLODData(bandIndex: 0, capacity: 5)],
        writeIndex: 5,
        lodRatio: 2,
        rawBufferLength: 12,
        timelineLayout: .staticLinear(
          availableRawSampleCount: 12,
          totalRawSampleCount: 10,
        ),
      )

      #expect(
        snapshot.timelineLayout
          == .staticLinear(
            availableRawSampleCount: 10,
            totalRawSampleCount: 10,
          ))
    }

    @Test
    func `lodBufferLength uses ceil(raw/lodRatio)`() {
      let config = MultiBandLODConfiguration(
        bandCount: 3,
        lodRatio: 6,
        bufferSeconds: 1,
        sampleRate: 10,
      )

      #expect(config.rawBufferLength == 10)
      #expect(config.lodBufferLength == 2)
    }

    @Test
    func `Positive modulo wraps negative indices`() {
      func positiveModulo(_ x: Int, _ m: Int) -> Int {
        let r = x % m
        return r < 0 ? (r + m) : r
      }

      #expect(positiveModulo(-1, 10) == 9)
      #expect(positiveModulo(-10, 10) == 0)
      #expect(positiveModulo(-11, 10) == 9)
      #expect(positiveModulo(0, 10) == 0)
      #expect(positiveModulo(10, 10) == 0)
      #expect(positiveModulo(11, 10) == 1)
    }

    @Test
    func `copyContiguousLODChannel returns band-contiguous buffers`() {
      var band0 = BandLODData(bandIndex: 0, capacity: 3)
      band0.minBuffer = [1, 2, 3]
      band0.maxBuffer = [11, 12, 13]
      band0.rmsBuffer = [21, 22, 23]

      var band1 = BandLODData(bandIndex: 1, capacity: 3)
      band1.minBuffer = [4, 5, 6]
      band1.maxBuffer = [14, 15, 16]
      band1.rmsBuffer = [24, 25, 26]

      let snapshot = MultiBandLODSnapshot(
        bands: [band0, band1],
        writeIndex: 0,
        lodRatio: 2,
        rawBufferLength: 6,
      )

      #expect(snapshot.copyContiguousLODChannel(.min) == [1, 2, 3, 4, 5, 6])
      #expect(snapshot.copyContiguousLODChannel(.max) == [11, 12, 13, 14, 15, 16])
      #expect(snapshot.copyContiguousLODChannel(.rms) == [21, 22, 23, 24, 25, 26])
    }

    @Test
    func `Checked band access returns nil for out-of-range bands`() {
      let snapshot = MultiBandLODSnapshot(
        bands: [BandLODData(bandIndex: 0, capacity: 4)],
        writeIndex: 0,
        lodRatio: 2,
        rawBufferLength: 8,
      )

      let validCount = unsafe snapshot.withMinBufferIfValid(band: 0) { $0.count }
      let invalidNegative = unsafe snapshot.withMinBufferIfValid(band: -1) { $0.count }
      let invalidUpper = unsafe snapshot.withMinBufferIfValid(band: 1) { $0.count }

      #expect(validCount == 4)
      #expect(invalidNegative == nil)
      #expect(invalidUpper == nil)
    }
  }

  private struct LegacyLODSnapshot: LODSnapshot {
    let bandCount = 0
    let writeIndex = 0
    let lodRatio = 1
    let rawBufferLength = 0
    let lodBufferLength = 0

    func withContiguousLODChannel<R>(
      band _: Int,
      channel _: LODChannel,
      _ body: (UnsafeBufferPointer<Float>) -> R,
    ) -> R {
      unsafe body(UnsafeBufferPointer(start: nil, count: 0))
    }

    func withMinBuffer<R>(band _: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      unsafe body(UnsafeBufferPointer(start: nil, count: 0))
    }

    func withMaxBuffer<R>(band _: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      unsafe body(UnsafeBufferPointer(start: nil, count: 0))
    }

    func withRMSBuffer<R>(band _: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      unsafe body(UnsafeBufferPointer(start: nil, count: 0))
    }

    func withRawBuffer<R>(band _: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      unsafe body(UnsafeBufferPointer(start: nil, count: 0))
    }
  }

#endif
