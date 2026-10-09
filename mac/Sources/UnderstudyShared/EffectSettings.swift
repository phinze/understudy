import Foundation

/// EffectSettings is effects.json: what the host draws over live video. The
/// control app writes it and the host watches it, so it's the only thing the
/// two share. Decoding never fails on a bad field: anything missing, mistyped
/// or out of range falls back to its default or is clamped, so a hand edit
/// can't knock video over.
public struct EffectSettings: Codable, Equatable, Sendable {
    public var blobs = BlobSettings()

    public init() {}

    /// Whether any effect is on. When none is, frames go through untouched.
    public var anyEnabled: Bool { blobs.enabled }

    /// ~/.local/state/understudy/effects.json, beside the agent's pid file.
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/understudy/effects.json")

    /// Reads settings from `url`. A missing file is all defaults (every
    /// effect off); unreadable JSON throws, so the host can keep what it had.
    public static func load(from url: URL = defaultURL) throws -> EffectSettings {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return EffectSettings()
        }
        return try JSONDecoder().decode(EffectSettings.self, from: data)
    }

    /// Writes settings to `url` atomically, so the host never reads half a
    /// file.
    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blobs = c.lenient(BlobSettings.self, .blobs) ?? BlobSettings()
    }
}

/// Knobs for the blob-tracking overlay: boxes around bright (or dark)
/// regions, a few of them picked at a time, with connector lines and
/// machine-vision labels.
public struct BlobSettings: Codable, Equatable, Sendable {
    public enum LabelStyle: String, Codable, CaseIterable, Sendable {
        case none
        /// Just the track ID.
        case id
        /// ID, coordinates and a made-up confidence.
        case full
    }

    public var enabled = false
    /// How many blobs to draw at once.
    public var boxCount = 6
    /// Frames between re-picking which blobs to draw (at 30fps, 45 is 1.5s).
    public var reselectFrames = 45
    /// How much each reselect interval wanders, as a fraction of it.
    public var reselectJitter = 0.4
    /// Luma cutoff, 0-1. Cells brighter than this are blob.
    public var threshold = 0.6
    /// Track dark regions instead of bright ones.
    public var invert = false
    /// Chance that each picked blob gets a connector line to another.
    public var lineProbability = 0.35
    /// Box outline width in pixels at 1080p. Connector lines are drawn at
    /// two thirds of it.
    public var lineWidth = 1.5
    /// Line and label color, as #RRGGBB.
    public var color = "#3CFF8C"
    public var labels = LabelStyle.full
    /// Seeds the picks, the line rolls and the fake confidences.
    public var seed = 0

    public static let boxCountRange = 1...32
    public static let reselectFramesRange = 1...600
    public static let reselectJitterRange = 0.0...1.0
    public static let thresholdRange = 0.0...1.0
    public static let lineProbabilityRange = 0.0...1.0
    public static let lineWidthRange = 0.5...6.0
    public static let seedRange = 0...999_999

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BlobSettings()
        enabled = c.lenient(Bool.self, .enabled) ?? d.enabled
        boxCount = (c.lenient(Int.self, .boxCount) ?? d.boxCount).clamped(to: Self.boxCountRange)
        reselectFrames = (c.lenient(Int.self, .reselectFrames) ?? d.reselectFrames)
            .clamped(to: Self.reselectFramesRange)
        reselectJitter = (c.lenient(Double.self, .reselectJitter) ?? d.reselectJitter)
            .clamped(to: Self.reselectJitterRange)
        threshold = (c.lenient(Double.self, .threshold) ?? d.threshold).clamped(to: Self.thresholdRange)
        invert = c.lenient(Bool.self, .invert) ?? d.invert
        lineProbability = (c.lenient(Double.self, .lineProbability) ?? d.lineProbability)
            .clamped(to: Self.lineProbabilityRange)
        lineWidth = (c.lenient(Double.self, .lineWidth) ?? d.lineWidth).clamped(to: Self.lineWidthRange)
        color = c.lenient(String.self, .color).flatMap { RGB(hex: $0) != nil ? $0 : nil } ?? d.color
        labels = c.lenient(LabelStyle.self, .labels) ?? d.labels
        seed = (c.lenient(Int.self, .seed) ?? d.seed).clamped(to: Self.seedRange)
    }

    /// `color` as components, falling back to the default green.
    public var rgb: RGB { RGB(hex: color) ?? RGB(hex: BlobSettings().color)! }
}

public struct RGB: Equatable, Sendable {
    public var red, green, blue: Double

    /// Parses "#RRGGBB" (the # is optional).
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        red = Double(value >> 16 & 0xFF) / 255
        green = Double(value >> 8 & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var hex: String {
        func byte(_ v: Double) -> Int { Int((v.clamped(to: 0...1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

extension KeyedDecodingContainer {
    /// The value at `key`, or nil if it's missing or the wrong type.
    fileprivate func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
