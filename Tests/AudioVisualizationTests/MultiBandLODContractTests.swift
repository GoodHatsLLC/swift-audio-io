#if canImport(AVFoundation)
  import AIOEngine
  import Testing

  @Suite("MultiBandLOD Contract Tests")
  struct MultiBandLODContractTests {

    @Test("lodBufferLength uses ceil(raw/lodRatio)")
    func testLODBufferLengthCeil() {
      let config = MultiBandLODConfiguration(
        bandCount: 3,
        lodRatio: 6,
        bufferSeconds: 1,
        sampleRate: 10
      )

      #expect(config.rawBufferLength == 10)
      #expect(config.lodBufferLength == 2)
    }

    @Test("Positive modulo wraps negative indices")
    func testPositiveModulo() {
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

    @Test("Flat buffers are band-contiguous")
    func testFlatBufferLayoutBandContiguous() {
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
        rawBufferLength: 6
      )

      #expect(snapshot.flatMinBuffer() == [1, 2, 3, 4, 5, 6])
      #expect(snapshot.flatMaxBuffer() == [11, 12, 13, 14, 15, 16])
      #expect(snapshot.flatRMSBuffer() == [21, 22, 23, 24, 25, 26])
    }
  }

#endif
