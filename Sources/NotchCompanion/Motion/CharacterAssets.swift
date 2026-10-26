import AppKit
import ImageIO
import NotchCore

/// The 12 storyboard poses exported from Figma (Page 2 → Emotion sheet).
enum Pose: String, CaseIterable, Sendable {
    case idlePeek = "p01_idle_peek"
    case lookAround = "p02_look_around"
    case blink = "p03_blink"
    case curious = "p04_curious"
    case notice = "p05_notice"
    case callAttention = "p06_call_attention"
    case point = "p07_point"
    case serious = "p08_serious"
    case thinking = "p09_thinking"
    case happy = "p10_happy"
    case playful = "p11_playful"
    case retreat = "p12_retreat"

    /// The authored key pose for each emotion.
    static func key(for emotion: Emotion) -> Pose {
        switch emotion {
        case .anxiety: .callAttention
        case .envy: .playful
        case .embarrassment: .point
        case .ennui: .thinking
        case .disgust: .blink
        case .fear: .notice
        case .joy: .happy
        case .anger: .serious
        case .sadness: .retreat
        case .neutral: .lookAround
        }
    }
}

// MARK: - rig.json

struct RigSpec: Decodable {
    var canvas: [Double]
    var scale: Double
    var poses: [String: PoseSpec]

    var canvasSize: CGSize { CGSize(width: canvas[0], height: canvas[1]) }
}

struct PoseSpec: Decodable {
    var body: String
    var eyes: [EyeSpec]
    var hand: PartSpec?
    var fx: PartSpec?
    var bounds: [Double]
}

struct EyeSpec: Decodable {
    /// cx, cy, rx, ry, angle (degrees), canvas units.
    var ellipse: [Double]
    var pupil: PupilSpec
    var lid: [Int]
}

struct PupilSpec: Decodable {
    var image: String
    var frame: [Double]
    var center: [Double]
    var radius: Double
}

struct PartSpec: Decodable {
    var image: String
    /// x0, y0, x1, y1 in canvas units.
    var frame: [Double]
    var pivot: [Double]
}

extension Array where Element == Double {
    var rect: CGRect { CGRect(x: self[0], y: self[1], width: self[2] - self[0], height: self[3] - self[1]) }
    var point: CGPoint { CGPoint(x: self[0], y: self[1]) }
}

/// Loads and caches the character's decoded images. Everything is decoded
/// once at launch, so nothing is decoded per frame.
final class CharacterAssets {
    static let shared = CharacterAssets()

    let directory: URL?
    let spec: RigSpec?
    private var images: [String: CGImage] = [:]

    init(directory: URL? = AssetLocator.characterDirectory) {
        self.directory = directory
        if let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("rig.json")) {
            spec = try? JSONDecoder().decode(RigSpec.self, from: data)
        } else {
            spec = nil
        }
    }

    var isAvailable: Bool { spec != nil }
    var canvasSize: CGSize { spec?.canvasSize ?? CGSize(width: 300, height: 116) }

    func pose(_ pose: Pose) -> PoseSpec? { spec?.poses[pose.rawValue] }

    func image(_ relativePath: String) -> CGImage? {
        if let cached = images[relativePath] { return cached }
        guard let directory,
              let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(relativePath) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        images[relativePath] = image
        return image
    }

    /// Optional pre-rendered clip that replaces the rig for an emotion
    /// (HEVC-with-alpha .mov). Lets better assets drop in without code changes.
    func clip(for emotion: Emotion) -> URL? {
        guard let url = directory?.appendingPathComponent("clips/\(emotion.rawValue).mov"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func preload() {
        guard let spec else { return }
        for pose in spec.poses.values {
            _ = image(pose.body)
            pose.eyes.forEach { _ = image($0.pupil.image) }
            if let hand = pose.hand { _ = image(hand.image) }
            if let fx = pose.fx { _ = image(fx.image) }
        }
    }
}

/// Finds the character assets: inside the app bundle when installed, or the
/// repository's Resources folder during development.
enum AssetLocator {
    static var characterDirectory: URL? {
        let fm = FileManager.default
        func valid(_ url: URL) -> Bool { fm.fileExists(atPath: url.appendingPathComponent("rig.json").path) }

        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Character"), valid(bundled) {
            return bundled
        }
        if let env = ProcessInfo.processInfo.environment["NOTCH_ASSETS"] {
            let url = URL(fileURLWithPath: env)
            if valid(url) { return url }
        }
        var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = url.appendingPathComponent("Resources/Character")
            if valid(candidate) { return candidate }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
