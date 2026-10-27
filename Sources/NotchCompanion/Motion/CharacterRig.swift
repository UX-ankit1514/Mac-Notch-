import AVFoundation
import AppKit
import NotchCore
import QuartzCore

/// Curves from the motion system: strong ease-out for entrances and exits,
/// strong ease-in-out for on-screen movement. Never ease-in.
enum Curve {
    static let out = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    static let inOut = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
    static let ease = CAMediaTimingFunction(name: .default)
}

extension CALayer {
    /// Animates from what's on screen now to `value` and commits it as the
    /// model value, so interrupting retargets smoothly instead of jumping.
    ///
    /// Mid-animation, "on screen" is the presentation value. Otherwise it's
    /// the model value: the presentation layer lags a frame behind a value
    /// set just before (an entry's start position, a freshly shown pose), and
    /// animating from it would silently skip that motion.
    func animate(_ keyPath: String, to value: Any, duration: CFTimeInterval,
                 delay: CFTimeInterval = 0, curve: CAMediaTimingFunction = Curve.out) {
        let inFlight = animation(forKey: keyPath) != nil
        let from = (inFlight ? presentation()?.value(forKeyPath: keyPath) : nil) ?? self.value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        guard duration > 0 else { removeAnimation(forKey: keyPath); return }
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = value
        a.duration = duration
        a.timingFunction = curve
        if delay > 0 {
            a.beginTime = convertTime(CACurrentMediaTime(), from: nil) + delay
            a.fillMode = .backwards
        }
        add(a, forKey: keyPath)
    }

    /// Additive keyframes layered over the model value; ends back at rest.
    func pulse(_ keyPath: String, _ values: [Double], duration: CFTimeInterval,
               delay: CFTimeInterval = 0, curve: CAMediaTimingFunction = Curve.inOut) {
        guard values.count > 1, duration > 0 else { return }
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.isAdditive = true
        a.duration = duration
        a.timingFunctions = Array(repeating: curve, count: values.count - 1)
        if delay > 0 { a.beginTime = convertTime(CACurrentMediaTime(), from: nil) + delay }
        add(a, forKey: "pulse.\(keyPath).\(UUID().uuidString)")
    }

    func removePulses() {
        for key in animationKeys() ?? [] where key.hasPrefix("pulse.") { removeAnimation(forKey: key) }
    }
}

/// One pose's layers. Coordinates arrive in canvas units with a top-left
/// origin (the asset pipeline's convention) and are flipped here once.
final class PoseRig {
    let root = CALayer()
    var eyes: [EyeRig] = []
    var hand: CALayer?
    var fx: CALayer?
    let pose: Pose

    init?(pose: Pose, assets: CharacterAssets) {
        guard let spec = assets.pose(pose), let body = assets.image(spec.body) else { return nil }
        self.pose = pose
        let canvas = assets.canvasSize
        let flip = { (r: CGRect) in CGRect(x: r.minX, y: canvas.height - r.maxY, width: r.width, height: r.height) }
        let flipPoint = { (p: CGPoint) in CGPoint(x: p.x, y: canvas.height - p.y) }

        root.frame = CGRect(origin: .zero, size: canvas)
        let bodyLayer = Self.imageLayer(body, frame: root.bounds)
        root.addSublayer(bodyLayer)

        for eye in spec.eyes {
            guard let pupil = assets.image(eye.pupil.image) else { continue }
            let e = eye.ellipse
            let box = flip(CGRect(x: e[0] - e[2], y: e[1] - e[3], width: 2 * e[2], height: 2 * e[3]))
            let rig = EyeRig(frame: box, angleDegrees: -e[4], pupil: pupil,
                             pupilFrame: flip(eye.pupil.frame.rect),
                             pupilRadius: eye.pupil.radius,
                             lid: NSColor(srgbRed: CGFloat(eye.lid[0]) / 255, green: CGFloat(eye.lid[1]) / 255,
                                          blue: CGFloat(eye.lid[2]) / 255, alpha: 1))
            root.addSublayer(rig.container)
            eyes.append(rig)
        }

        for (keyPath, part) in [("hand", spec.hand), ("fx", spec.fx)] {
            guard let part, let image = assets.image(part.image) else { continue }
            let frame = flip(part.frame.rect)
            let pivot = flipPoint(part.pivot.point)
            let layer = Self.imageLayer(image, frame: frame)
            layer.anchorPoint = CGPoint(x: (pivot.x - frame.minX) / frame.width, y: (pivot.y - frame.minY) / frame.height)
            layer.position = pivot
            root.addSublayer(layer)
            if keyPath == "hand" { hand = layer } else { fx = layer }
        }
    }

    static func imageLayer(_ image: CGImage, frame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        layer.contentsScale = 2
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = .linear
        layer.frame = frame
        return layer
    }
}

/// An eye: the pupil moves inside the eye-white ellipse and a skin-toned lid
/// slides down over it to blink. The ellipse mask keeps both inside the eye.
final class EyeRig {
    let container = CALayer()
    let pupil: CALayer
    let lid = CALayer()
    private let travel: CGFloat
    private let reach: CGSize

    init(frame: CGRect, angleDegrees: Double, pupil image: CGImage, pupilFrame: CGRect,
         pupilRadius: Double, lid color: NSColor) {
        container.frame = frame
        let bounds = container.bounds

        let mask = CAShapeLayer()
        var rotate = CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
            .rotated(by: angleDegrees * .pi / 180)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        mask.path = CGPath(ellipseIn: bounds, transform: &rotate)
        container.mask = mask

        pupil = PoseRig.imageLayer(image, frame: pupilFrame.offsetBy(dx: -frame.minX, dy: -frame.minY))
        container.addSublayer(pupil)

        // Lid: a skin shape whose lower edge curves down like a real lid, with a lash line.
        let w = bounds.width, h = bounds.height
        let bulge = h * 0.18
        let edge = CGMutablePath()
        edge.move(to: CGPoint(x: 0, y: 0))
        edge.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w / 2, y: -2 * bulge))
        let skin = CGMutablePath()
        skin.addPath(edge)
        skin.addLine(to: CGPoint(x: w, y: 3 * h))
        skin.addLine(to: CGPoint(x: 0, y: 3 * h))
        skin.closeSubpath()

        let skinLayer = CAShapeLayer()
        skinLayer.path = skin
        skinLayer.fillColor = color.cgColor
        let lash = CAShapeLayer()
        lash.path = edge
        lash.strokeColor = NSColor(srgbRed: 0.36, green: 0.2, blue: 0.15, alpha: 1).cgColor
        lash.fillColor = nil
        lash.lineWidth = max(0.8, h * 0.06)
        lash.lineCap = .round
        lid.frame = bounds
        lid.addSublayer(skinLayer)
        lid.addSublayer(lash)
        container.addSublayer(lid)

        travel = h + bulge * 1.2
        lid.setValue(travel, forKeyPath: "transform.translation.y")    // open
        reach = CGSize(width: max(0, frame.width / 2 - pupilRadius * 0.85),
                       height: max(0, frame.height / 2 - pupilRadius * 0.85))
    }

    /// x, y in -1…1 relative to the eye centre (y: -1 up). nil = authored gaze.
    func look(_ target: CGPoint?, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        let offset: CGPoint
        if let target {
            let centre = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
            let authored = CGPoint(x: pupil.frame.midX - pupil.transform.m41, y: pupil.frame.midY - pupil.transform.m42)
            let wanted = CGPoint(x: centre.x + target.x * reach.width, y: centre.y - target.y * reach.height)
            offset = CGPoint(x: wanted.x - authored.x, y: wanted.y - authored.y)
        } else {
            offset = .zero
        }
        pupil.animate("transform.translation.x", to: offset.x, duration: duration, delay: delay, curve: Curve.inOut)
        pupil.animate("transform.translation.y", to: offset.y, duration: duration, delay: delay, curve: Curve.inOut)
    }

    /// 0 open … 1 closed.
    func setLid(_ closed: CGFloat, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        lid.animate("transform.translation.y", to: travel * (1 - closed), duration: duration, delay: delay, curve: Curve.inOut)
    }

    func blink(duration: CFTimeInterval = 0.16, delay: CFTimeInterval = 0) {
        let base = lid.value(forKeyPath: "transform.translation.y") as? CGFloat ?? travel
        // Down fast, up a touch slower: reads as a natural blink.
        lid.pulse("transform.translation.y", [0, -base, -base, 0], duration: duration * 2.2, delay: delay, curve: Curve.ease)
    }
}

/// The whole character: a stage scaled to the view, an actor that carries
/// body motion, and one PoseRig per pose (cross-faded, never duplicated).
final class CharacterRig {
    let layer = CALayer()
    let stage = CALayer()
    let actor = CALayer()
    private let assets: CharacterAssets
    private var rigs: [Pose: PoseRig] = [:]
    private(set) var current: Pose?
    private var clip: (layer: AVPlayerLayer, looper: AVPlayerLooper)?
    private var stackTop: CGFloat = 0

    /// Horizontal centre of the canvas inside the view, 0…1.
    var canvasCenter: CGFloat = 0.5 { didSet { layout() } }

    init(assets: CharacterAssets = .shared) {
        self.assets = assets
        layer.masksToBounds = true
        let canvas = assets.canvasSize
        stage.bounds = CGRect(origin: .zero, size: canvas)
        stage.anchorPoint = CGPoint(x: 0.5, y: 0)
        actor.bounds = stage.bounds
        actor.anchorPoint = CGPoint(x: 0.5, y: 0)          // bottom centre: tilt and squash pivot here
        actor.position = CGPoint(x: canvas.width / 2, y: 0)
        stage.addSublayer(actor)
        layer.addSublayer(stage)
    }

    var currentRig: PoseRig? { current.flatMap { rigs[$0] } }
    var eyes: [EyeRig] { currentRig?.eyes ?? [] }

    /// Fits the canvas to the view's height, bottom-aligned (the character
    /// peeks up from the notch's lower edge).
    func layout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let canvas = assets.canvasSize
        let scale = layer.bounds.height / canvas.height
        stage.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        stage.position = CGPoint(x: layer.bounds.width * canvasCenter, y: 0)
        clip?.layer.frame = actor.bounds
        CATransaction.commit()
    }

    private func rig(for pose: Pose) -> PoseRig? {
        if let existing = rigs[pose] { return existing }
        guard let made = PoseRig(pose: pose, assets: assets) else { return nil }
        made.root.opacity = 0
        actor.addSublayer(made.root)
        rigs[pose] = made
        return made
    }

    /// Builds every pose up front (invisible), so the first appearance of a
    /// pose never creates layers or uploads textures mid-animation.
    func prewarm() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Pose.allCases.forEach { _ = rig(for: $0) }
        CATransaction.commit()
    }

    /// Cross-fades to `pose`. Missing assets fall back to a neutral pose
    /// rather than broken imagery.
    ///
    /// The incoming pose fades in on top while the outgoing one holds a beat
    /// longer underneath, so the character never turns see-through mid-change
    /// (two half-transparent poses read as a ghostly double exposure).
    func show(_ pose: Pose, fade: CFTimeInterval = 0.18, delay: CFTimeInterval = 0) {
        let target = rig(for: pose) ?? rig(for: .lookAround) ?? rigs.values.first
        guard let target, target.pose != current else { return }
        stackTop += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.root.zPosition = stackTop        // in front of the pose it replaces
        CATransaction.commit()
        if let old = currentRig {
            old.root.animate("opacity", to: Float(0), duration: fade, delay: delay + fade * 0.5, curve: Curve.inOut)
        }
        target.eyes.forEach { $0.look(nil, duration: 0); $0.setLid(0, duration: 0) }
        target.hand?.removePulses()
        target.fx?.removePulses()
        target.root.animate("opacity", to: Float(1), duration: fade, delay: delay, curve: Curve.out)
        current = target.pose
    }

    /// Plays a drop-in clip instead of the rig for this emotion, if one exists.
    func showClip(for emotion: Emotion) -> Bool {
        stopClip()
        guard let url = assets.clip(for: emotion) else { return false }
        let player = AVQueuePlayer()
        player.isMuted = true
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = actor.bounds
        playerLayer.videoGravity = .resizeAspect
        playerLayer.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        playerLayer.zPosition = 1_000_000           // above every pose (poses stack by zPosition)
        actor.addSublayer(playerLayer)
        currentRig?.root.opacity = 0
        player.play()
        clip = (playerLayer, looper)
        return true
    }

    func stopClip() {
        clip?.layer.player?.pause()
        clip?.layer.removeFromSuperlayer()
        clip = nil
    }

    /// Stops everything (used when hidden: nothing animates off screen).
    func halt() {
        actor.removeAllAnimations()
        for rig in rigs.values {
            rig.root.removeAllAnimations()
            rig.hand?.removeAllAnimations()
            rig.fx?.removeAllAnimations()
            rig.eyes.forEach { $0.pupil.removeAllAnimations(); $0.lid.removeAllAnimations() }
        }
        stopClip()
    }
}
