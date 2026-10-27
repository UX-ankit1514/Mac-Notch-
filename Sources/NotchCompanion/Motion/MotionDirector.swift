import AppKit
import NotchCore
import QuartzCore

/// Runs the character's motion. `MotionStateMachine` (NotchCore) decides
/// what happens; this type turns its commands into Core Animation on the rig
/// and reports completion back. All timings follow PRD §8.5:
/// reveal 300 ms, reaction 500–900 ms, hover 200 ms, exit 250 ms.
final class MotionDirector {
    let rig: CharacterRig
    private(set) var machine = MotionStateMachine()
    private var pending: [DispatchWorkItem] = []
    /// Reports the running reaction's end; a newer reaction replaces it.
    private var reactionDone: DispatchWorkItem?
    private var idleTask: Task<Void, Never>?

    /// 0.55 subtle … 1.3 lively.
    var intensity: Double = 1
    var reduceMotion = false
    /// Called once the retreat is well under way, so the notch closes over
    /// its tail instead of waiting for it (one continuous exit, not two steps).
    var onHidden: (() -> Void)?

    init(rig: CharacterRig) {
        self.rig = rig
    }

    private var actor: CALayer { rig.actor }
    private func amp(_ v: Double) -> Double { reduceMotion ? 0 : v * intensity }

    // MARK: Inputs

    func show(_ emotion: Emotion) { send(.show(emotion)) }
    func remind() { send(.remind) }
    func hide() { send(.hide) }
    func pointer(inside: Bool) { send(inside ? .pointerEntered : .pointerExited) }

    /// Pupils follow the pointer while hovered. Point is -1…1 around the character.
    func track(_ point: CGPoint) {
        guard machine.phase == .interacting, !reduceMotion else { return }
        let clamped = CGPoint(x: max(-1, min(1, point.x)), y: max(-1, min(1, point.y)))
        rig.eyes.forEach { $0.look(clamped, duration: 0.2) }
    }

    /// Press feedback: a quick squash (100–160 ms).
    func press() {
        guard !reduceMotion else { return }
        actor.pulse("transform.scale", [0, -0.03, 0], duration: 0.16, curve: Curve.out)
    }

    private func send(_ input: MotionInput) {
        for command in machine.handle(input) { run(command) }
    }

    private func after(_ seconds: Double, _ body: @escaping () -> Void) {
        let item = DispatchWorkItem(block: body)
        pending.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelScheduled() {
        pending.forEach { $0.cancel() }
        pending.removeAll()
        reactionDone?.cancel()
        reactionDone = nil
    }

    /// One report per reaction: when a new emotion interrupts, the old
    /// reaction's report would otherwise start idling mid-reaction.
    private func finishReaction(after seconds: Double) {
        reactionDone?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.send(.reactionFinished) }
        reactionDone = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: Commands

    private func run(_ command: MotionCommand) {
        switch command {
        case let .playEntry(emotion): entry(emotion)
        case let .playReaction(emotion): finishReaction(after: react(emotion))
        case let .playReminder(emotion): finishReaction(after: remind(emotion))
        case let .crossfade(emotion): crossfade(to: emotion)
        case .startIdle: startIdle()
        case .stopIdle: stopIdle()
        case .hoverOn: hoverOn()
        case .hoverOff: hoverOff()
        case .playExit: exit()
        }
    }

    // MARK: Entry / exit — the character rises out of the notch's lower edge

    private func entry(_ emotion: Emotion) {
        cancelScheduled()
        stopIdle()
        rig.layout()
        if rig.showClip(for: emotion) {
            actor.animate("opacity", to: Float(1), duration: 0.2)
            after(0.3) { [weak self] in self?.send(.entered) }
            return
        }
        let key = Pose.key(for: emotion)
        if reduceMotion {
            rig.show(key, fade: 0)
            place(translationY: 0, opacity: 0)
            actor.animate("opacity", to: Float(1), duration: 0.2, curve: Curve.ease)
            after(0.2) { [weak self] in self?.send(.entered) }
            return
        }
        // Start low (the designer's "Idle Peek"), rise, settle into the key pose.
        rig.show(.idlePeek, fade: 0)
        place(translationY: -70, opacity: 1)
        actor.animate("transform.translation.y", to: 0, duration: 0.32, delay: 0.05, curve: Curve.out)
        if key != .idlePeek { rig.show(key, fade: 0.16, delay: 0.22) }
        after(0.38) { [weak self] in self?.send(.entered) }
    }

    /// The entry's starting state, set without implicit animation. Tilt and
    /// scale go back to rest too: reactions like Sadness's droop and Anger's
    /// lean-in leave them changed, and the next alert must not inherit them.
    private func place(translationY: Double, opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        actor.setValue(translationY, forKeyPath: "transform.translation.y")
        actor.setValue(0, forKeyPath: "transform.rotation.z")
        actor.setValue(1, forKeyPath: "transform.scale")
        actor.removeAnimation(forKey: "transform.rotation.z")
        actor.removeAnimation(forKey: "transform.scale")
        actor.opacity = opacity
        CATransaction.commit()
    }

    private func exit() {
        cancelScheduled()
        stopIdle()
        if reduceMotion {
            actor.animate("opacity", to: Float(0), duration: 0.2, curve: Curve.ease)
        } else {
            rig.show(.retreat, fade: 0.12)
            actor.animate("transform.translation.y", to: -80, duration: 0.25, curve: Curve.out)
        }
        // The notch's own changes reach the screen a frame or two after Core
        // Animation's, so ask early enough that it closes while the retreat ends.
        after(0.08) { [weak self] in self?.onHidden?() }
        after(0.26) { [weak self] in
            guard let self else { return }
            self.rig.halt()
            self.send(.exited)
        }
    }

    private func crossfade(to emotion: Emotion) {
        if rig.showClip(for: emotion) { return }
        rig.stopClip()
        rig.show(Pose.key(for: emotion), fade: 0.2)
        actor.animate("transform.translation.y", to: 0, duration: 0.25, curve: Curve.out)
        actor.animate("transform.rotation.z", to: 0, duration: 0.25, curve: Curve.out)
        actor.animate("transform.scale", to: 1, duration: 0.25, curve: Curve.out)
    }

    // MARK: Reactions (500–900 ms). Returns the duration.

    private func react(_ emotion: Emotion) -> Double {
        let eyes = rig.eyes
        let hand = rig.currentRig?.hand
        let fx = rig.currentRig?.fx
        popFX(fx)

        switch emotion {
        case .anxiety:
            // Quick glance both ways, nervous wave, one small jitter.
            eyes.forEach { $0.look(CGPoint(x: -0.7, y: 0), duration: 0.12) }
            eyes.forEach { $0.look(CGPoint(x: 0.7, y: 0), duration: 0.12, delay: 0.22) }
            eyes.forEach { $0.look(nil, duration: 0.18, delay: 0.5) }
            hand?.pulse("transform.rotation.z", [0, 0.2, -0.12, 0.16, -0.06, 0].map { amp($0) }, duration: 0.75)
            actor.pulse("transform.translation.x", [0, -1.2, 1.2, -0.7, 0].map { amp($0) }, duration: 0.3, delay: 0.1)
            return 0.8

        case .envy:
            // Side-eye, finger-gun flick, a subtle comic tilt.
            eyes.forEach { $0.look(CGPoint(x: 0.8, y: -0.1), duration: 0.18) }
            hand?.pulse("transform.rotation.z", [0, 0.16, -0.05, 0].map { amp($0) }, duration: 0.45, delay: 0.1)
            actor.pulse("transform.rotation.z", [0, 0.04, 0].map { amp($0) }, duration: 0.6)
            return 0.7

        case .embarrassment:
            // Lowered eyes, two taps at the message, a slight shrink back.
            eyes.forEach { $0.look(CGPoint(x: 0.1, y: 0.7), duration: 0.2) }
            hand?.pulse("transform.translation.y", [0, -2.5, 0, -2.5, 0].map { amp($0) }, duration: 0.6, delay: 0.1)
            actor.animate("transform.translation.y", to: -amp(3), duration: 0.5, curve: Curve.inOut)
            return 0.75

        case .ennui:
            // Slow blink, eyes drift, relaxed.
            eyes.forEach { $0.blink(duration: 0.26) }
            eyes.forEach { $0.look(CGPoint(x: 0.3, y: -0.6), duration: 0.7, delay: 0.3) }
            return 0.9

        case .disgust:
            // Recoil back, then a skeptical glance.
            actor.pulse("transform.translation.y", [0, -amp(4), -amp(1.5), 0], duration: 0.55, curve: Curve.out)
            actor.pulse("transform.rotation.z", [0, amp(-0.05), 0], duration: 0.55)
            actor.pulse("transform.scale", [0, amp(-0.03), 0], duration: 0.45)
            eyes.forEach { $0.look(CGPoint(x: 0.85, y: 0), duration: 0.16, delay: 0.25) }
            return 0.7

        case .fear:
            // Startled pop, darting eyes, then sinks to hide.
            actor.pulse("transform.translation.y", [0, amp(6), 0], duration: 0.22, curve: Curve.out)
            actor.pulse("transform.scale", [0, amp(0.04), 0], duration: 0.22, curve: Curve.out)
            eyes.forEach { $0.look(CGPoint(x: -0.6, y: 0), duration: 0.08, delay: 0.25) }
            eyes.forEach { $0.look(CGPoint(x: 0.6, y: 0), duration: 0.08, delay: 0.4) }
            eyes.forEach { $0.look(nil, duration: 0.12, delay: 0.55) }
            actor.animate("transform.translation.y", to: -amp(14), duration: 0.35, delay: 0.5, curve: Curve.inOut)
            return 0.9

        case .joy:
            // Restrained bounce with a thumbs-up pump.
            actor.pulse("transform.translation.y", [0, amp(7), 0, amp(2.5), 0], duration: 0.7)
            hand?.pulse("transform.rotation.z", [0, amp(0.14), amp(-0.04), 0], duration: 0.5, delay: 0.08)
            return 0.75

        case .anger:
            // Brows down (lids narrow), lean in, two short frustrated shakes.
            eyes.forEach { $0.setLid(0.3, duration: 0.15) }
            actor.animate("transform.scale", to: 1 + amp(0.025), duration: 0.2)
            actor.pulse("transform.translation.x", [0, -2, 2, -1.5, 1.5, 0].map { amp($0) }, duration: 0.4, delay: 0.18)
            return 0.7

        case .sadness:
            // Drooping and sinking, subdued.
            actor.animate("transform.translation.y", to: -amp(6), duration: 0.8, curve: Curve.inOut)
            actor.animate("transform.rotation.z", to: amp(0.03), duration: 0.8, curve: Curve.inOut)
            return 0.85

        case .neutral:
            eyes.forEach { $0.look(CGPoint(x: -0.5, y: 0), duration: 0.2) }
            eyes.forEach { $0.look(nil, duration: 0.2, delay: 0.4) }
            return 0.6
        }
    }

    /// A gentle nudge for a request still waiting: smaller than the first reaction.
    private func remind(_ emotion: Emotion) -> Double {
        popFX(rig.currentRig?.fx)
        actor.pulse("transform.translation.y", [0, amp(4), 0], duration: 0.4)
        if emotion == .anxiety {
            rig.currentRig?.hand?.pulse("transform.rotation.z", [0, 0.12, -0.08, 0].map { amp($0) }, duration: 0.5)
        }
        return 0.5
    }

    private func popFX(_ fx: CALayer?) {
        guard let fx else { return }
        if reduceMotion {
            fx.opacity = 1
            return
        }
        fx.opacity = 0
        fx.animate("opacity", to: Float(1), duration: 0.18, delay: 0.12)
        fx.pulse("transform.scale", [-0.3, 0.06, 0], duration: 0.3, delay: 0.12, curve: Curve.out)
    }

    // MARK: Waiting: blink at natural, varied intervals; slight breathing

    private func startIdle() {
        stopIdle()
        if !reduceMotion && intensity >= 1 {
            let breathe = CABasicAnimation(keyPath: "transform.scale.y")
            breathe.fromValue = 0
            breathe.toValue = 0.012
            breathe.isAdditive = true
            breathe.duration = 1.9
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = Curve.inOut
            actor.add(breathe, forKey: "idle.breathe")
        }
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.6...5.8)))
                guard !Task.isCancelled, let self else { return }
                self.rig.eyes.forEach { $0.blink() }
                // Now and then a second, quick blink, like people do.
                if Double.random(in: 0...1) < 0.2 { self.rig.eyes.forEach { $0.blink(delay: 0.42) } }
            }
        }
    }

    private func stopIdle() {
        idleTask?.cancel()
        idleTask = nil
        actor.removeAnimation(forKey: "idle.breathe")
    }

    // MARK: Hover — the character acknowledges the pointer (200 ms)

    private func hoverOn() {
        guard !reduceMotion else { return }
        actor.animate("transform.translation.y", to: amp(2.5), duration: 0.2, curve: Curve.ease)
    }

    private func hoverOff() {
        actor.animate("transform.translation.y", to: 0, duration: 0.2, curve: Curve.ease)
        rig.eyes.forEach { $0.look(nil, duration: 0.2) }
    }
}
