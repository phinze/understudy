import CoreGraphics
import CoreText
import Foundation
import UnderstudyShared

/// BlobTracker draws the TouchDesigner-style blob-tracking look: boxes
/// around bright regions, a few picked at a time and re-picked every so
/// often, with connector lines and little machine-vision labels.
///
/// Each frame shrinks to a 160x90 gray grid, thresholds it and finds
/// connected regions. Regions are matched to the previous frame's by
/// nearest center so they keep an ID while they drift, which is what lets a
/// pick survive between reselects.
final class BlobTracker: Effect {
    static let columns = 160
    static let rows = 90
    /// Regions smaller than this many grid cells are noise.
    private static let minArea = 6
    /// Regions bigger than this are background (a bright wall, a window),
    /// and a box around half the frame reads as a bug, not a tracker.
    private static let maxArea = columns * rows * 15 / 100
    /// How far (in grid cells) a region's center may move between frames and
    /// still be the same track.
    private static let matchDistance = 10.0

    private struct Blob {
        var minX, minY, maxX, maxY: Int
        var area: Int
        var centerX, centerY: Double
    }

    private struct Track {
        let id: Int
        var blob: Blob
        /// A made-up confidence that wobbles a little each frame.
        var confidence: Double
    }

    private var settings = BlobSettings()
    private var rng = SplitMix64(seed: 0)
    private var gray = [UInt8](repeating: 0, count: columns * rows)
    private var labels = [Int32](repeating: 0, count: columns * rows)
    private var stack: [Int] = []

    private var tracks: [Track] = []
    private var nextID = 1
    private var picked: [Int] = []
    private var links: [(Int, Int)] = []
    private var framesUntilReselect = 0
    private var font: CTFont?
    private var fontHeight = 0

    func configure(_ settings: EffectSettings) {
        let next = settings.blobs
        let reseed = next.seed != self.settings.seed || !self.settings.enabled
        self.settings = next
        if reseed {
            rng = SplitMix64(seed: UInt64(next.seed))
            framesUntilReselect = 0
        }
        // A smaller count or a new interval should show right away.
        if picked.count > next.boxCount || framesUntilReselect > next.reselectFrames {
            framesUntilReselect = 0
        }
    }

    func render(_ frame: EffectFrame) {
        downsample(frame)
        track(findBlobs())

        framesUntilReselect -= 1
        let alive = Set(tracks.map(\.id))
        picked.removeAll { !alive.contains($0) }
        if framesUntilReselect <= 0 {
            reselect()
        } else if picked.count < settings.boxCount {
            // A picked blob vanished; fill its slot without waiting.
            topUp()
        }
        links.removeAll { !alive.contains($0.0) || !alive.contains($0.1) }

        draw(frame)
    }

    // MARK: analysis

    /// Averages a 4x4 spread of pixels from each grid cell into BT.601 luma.
    private func downsample(_ frame: EffectFrame) {
        let cellW = frame.width / Self.columns
        let cellH = frame.height / Self.rows
        let stepX = max(cellW / 4, 1)
        let stepY = max(cellH / 4, 1)
        for row in 0..<Self.rows {
            for column in 0..<Self.columns {
                var total = 0
                var count = 0
                var y = row * cellH + stepY / 2
                while y < (row + 1) * cellH {
                    var p = frame.pixels + y * frame.bytesPerRow + (column * cellW + stepX / 2) * 4
                    var x = column * cellW + stepX / 2
                    while x < (column + 1) * cellW {
                        total += Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29
                        count += 1
                        x += stepX
                        p += stepX * 4
                    }
                    y += stepY
                }
                gray[row * Self.columns + column] = UInt8(count > 0 ? (total / count) >> 8 : 0)
            }
        }
    }

    /// Thresholds the grid and flood-fills 4-connected regions.
    private func findBlobs() -> [Blob] {
        let cut = UInt8((settings.threshold * 255).rounded())
        let invert = settings.invert
        for i in 0..<gray.count {
            labels[i] = (invert ? gray[i] < cut : gray[i] >= cut) ? -1 : 0
        }

        var blobs: [Blob] = []
        for start in 0..<labels.count where labels[start] == -1 {
            let label = Int32(blobs.count + 1)
            var blob = Blob(minX: .max, minY: .max, maxX: 0, maxY: 0, area: 0, centerX: 0, centerY: 0)
            var sumX = 0
            var sumY = 0
            labels[start] = label
            stack.append(start)
            while let i = stack.popLast() {
                let x = i % Self.columns
                let y = i / Self.columns
                blob.minX = min(blob.minX, x)
                blob.maxX = max(blob.maxX, x)
                blob.minY = min(blob.minY, y)
                blob.maxY = max(blob.maxY, y)
                blob.area += 1
                sumX += x
                sumY += y
                for (n, ok) in [(i - 1, x > 0), (i + 1, x < Self.columns - 1), (i - Self.columns, y > 0), (i + Self.columns, y < Self.rows - 1)]
                where ok && labels[n] == -1 {
                    labels[n] = label
                    stack.append(n)
                }
            }
            guard blob.area >= Self.minArea, blob.area <= Self.maxArea else { continue }
            blob.centerX = Double(sumX) / Double(blob.area)
            blob.centerY = Double(sumY) / Double(blob.area)
            blobs.append(blob)
        }
        return blobs
    }

    /// Greedily pairs this frame's blobs with existing tracks by nearest
    /// center. Unmatched blobs start new tracks; unmatched tracks end.
    private func track(_ blobs: [Blob]) {
        var pairs: [(distance: Double, track: Int, blob: Int)] = []
        for (t, track) in tracks.enumerated() {
            for (b, blob) in blobs.enumerated() {
                let d = hypot(track.blob.centerX - blob.centerX, track.blob.centerY - blob.centerY)
                if d <= Self.matchDistance { pairs.append((d, t, b)) }
            }
        }
        pairs.sort { $0.distance < $1.distance }

        var usedTracks = Set<Int>()
        var usedBlobs = Set<Int>()
        var next: [Track] = []
        for pair in pairs where !usedTracks.contains(pair.track) && !usedBlobs.contains(pair.blob) {
            usedTracks.insert(pair.track)
            usedBlobs.insert(pair.blob)
            var track = tracks[pair.track]
            track.blob = blobs[pair.blob]
            track.confidence = (track.confidence + rng.nextDouble(in: -0.015...0.015)).clamped(to: 0.5...0.99)
            next.append(track)
        }
        for (b, blob) in blobs.enumerated() where !usedBlobs.contains(b) {
            next.append(Track(id: nextID, blob: blob, confidence: rng.nextDouble(in: 0.62...0.97)))
            nextID = nextID % 9999 + 1
        }
        tracks = next
    }

    private func reselect() {
        var ids = tracks.map(\.id)
        rng.shuffle(&ids)
        picked = Array(ids.prefix(settings.boxCount))
        links = []
        for (i, id) in picked.enumerated().dropFirst() where rng.nextDouble(in: 0...1) < settings.lineProbability {
            links.append((picked[Int.random(in: 0..<i, using: &rng)], id))
        }
        let interval = Double(settings.reselectFrames)
        let jitter = interval * settings.reselectJitter
        framesUntilReselect = max(1, Int((interval + rng.nextDouble(in: -jitter...jitter)).rounded()))
    }

    private func topUp() {
        var candidates = tracks.map(\.id).filter { !picked.contains($0) }
        rng.shuffle(&candidates)
        for id in candidates.prefix(settings.boxCount - picked.count) {
            if let other = picked.randomElement(using: &rng), rng.nextDouble(in: 0...1) < settings.lineProbability {
                links.append((other, id))
            }
            picked.append(id)
        }
    }

    // MARK: drawing

    private func draw(_ frame: EffectFrame) {
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ctx = frame.context
        let scaleX = Double(frame.width) / Double(Self.columns)
        let scaleY = Double(frame.height) / Double(Self.rows)
        let unit = Double(frame.height) / 1080
        let rgb = settings.rgb
        let color = CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)

        // Grid space is top down; CG is bottom up.
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: x * scaleX, y: Double(frame.height) - y * scaleY)
        }
        func center(_ t: Track) -> CGPoint { point(t.blob.centerX + 0.5, t.blob.centerY + 0.5) }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)

        // Dashes scale with the line, or thick connectors turn to dots.
        let linkWidth = settings.lineWidth * 2 / 3 * unit
        ctx.setLineWidth(linkWidth)
        ctx.setLineDash(phase: 0, lengths: [4 * max(linkWidth, unit), 3 * max(linkWidth, unit)])
        for (a, b) in links {
            guard let ta = byID[a], let tb = byID[b] else { continue }
            ctx.move(to: center(ta))
            ctx.addLine(to: center(tb))
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        ctx.setLineWidth(settings.lineWidth * unit)
        for id in picked {
            guard let t = byID[id] else { continue }
            let b = t.blob
            let topLeft = point(Double(b.minX), Double(b.minY))
            let bottomRight = point(Double(b.maxX + 1), Double(b.maxY + 1))
            ctx.stroke(
                CGRect(
                    x: topLeft.x, y: bottomRight.y, width: bottomRight.x - topLeft.x,
                    height: topLeft.y - bottomRight.y))
            let c = center(t)
            let tick = 4 * unit
            ctx.move(to: CGPoint(x: c.x - tick, y: c.y))
            ctx.addLine(to: CGPoint(x: c.x + tick, y: c.y))
            ctx.move(to: CGPoint(x: c.x, y: c.y - tick))
            ctx.addLine(to: CGPoint(x: c.x, y: c.y + tick))
            ctx.strokePath()

            guard settings.labels != .none else { continue }
            var lines = [String(format: "ID %04d", t.id)]
            if settings.labels == .full {
                lines.append(String(format: "X %4d Y %4d", Int(c.x), frame.height - Int(c.y)))
                lines.append(String(format: "CONF %.2f", t.confidence))
            }
            drawLabel(lines, at: CGPoint(x: topLeft.x + 2 * unit, y: topLeft.y + 3 * unit), unit: unit, frame: frame)
        }
    }

    /// Draws `lines` stacked upward from `origin`, the first line on top, so
    /// the label sits just above its box.
    private func drawLabel(_ lines: [String], at origin: CGPoint, unit: Double, frame: EffectFrame) {
        if font == nil || fontHeight != frame.height {
            font = CTFontCreateWithName("Menlo" as CFString, 12 * unit, nil)
            fontHeight = frame.height
        }
        guard let font else { return }
        let rgb = settings.rgb
        let attrs = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1),
        ] as CFDictionary
        let leading = 14 * unit
        // Boxes at the top of the frame get their label inside instead.
        var origin = origin
        let height = Double(lines.count) * leading
        if origin.y + height > Double(frame.height) {
            origin.y -= height + 6 * unit
        }
        // Boxes at the right edge get theirs pulled left.
        let width = Double(lines.map(\.count).max() ?? 0) * 7.3 * unit
        origin.x = min(origin.x, Double(frame.width) - width - 2 * unit)
        let ctx = frame.context
        ctx.textMatrix = .identity
        for (i, text) in lines.reversed().enumerated() {
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs))
            ctx.textPosition = CGPoint(x: origin.x, y: origin.y + Double(i) * leading)
            CTLineDraw(line, ctx)
        }
    }
}

/// A small seedable generator, so a seed always draws the same picks.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &self)
    }

    mutating func shuffle<T>(_ array: inout [T]) {
        array.shuffle(using: &self)
    }
}
