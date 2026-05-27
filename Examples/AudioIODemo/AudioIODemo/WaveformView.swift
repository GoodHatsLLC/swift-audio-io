// A minimal multi-band LOD waveform view.
//
// The visualization engine maintains a per-band ring buffer of three channels
// (min sample, max sample, peak sample) at a downsampled ratio. This view
// reads the most-recent snapshot once per frame via withCurrentLODSnapshotRef,
// which is non-blocking and zero-copy (the snapshot ref is frame-scoped).
//
// Realistic renderers would feed the snapshot into a Metal shader; this
// SwiftUI Canvas implementation is for clarity, not throughput.

import AudioIO
import SwiftUI

struct WaveformView: View {
  let visualization: AudioVisualizationEngine

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
      Canvas { context, size in
        draw(in: context, size: size)
      }
    }
  }

  private func draw(in context: GraphicsContext, size: CGSize) {
    visualization.withCurrentLODSnapshotRef { snapshot in
      guard snapshot.bandCount > 0 else { return }
      let band = 0  // draw the lowest band; real renderers would draw all bands

      _ = snapshot.withMinBufferIfValid(band: band) { minSamples in
        _ = snapshot.withMaxBufferIfValid(band: band) { maxSamples in
          let frameCount = min(minSamples.count, maxSamples.count)
          guard frameCount > 0 else { return }

          let columnWidth = size.width / CGFloat(frameCount)
          let midY = size.height / 2
          let amplitude = size.height / 2

          var path = Path()
          for i in 0..<frameCount {
            let x = CGFloat(i) * columnWidth
            let lo = midY - CGFloat(maxSamples[i]) * amplitude
            let hi = midY - CGFloat(minSamples[i]) * amplitude
            path.move(to: CGPoint(x: x, y: lo))
            path.addLine(to: CGPoint(x: x, y: hi))
          }
          context.stroke(path, with: .color(.accentColor), lineWidth: 1)
        }
      }
    }
  }
}
