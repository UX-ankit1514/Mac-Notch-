import AppKit
import NotchCore
import SwiftUI

/// Hosts a character rig in an NSView. The rig's layer tree does all its
/// animation on the render server, so SwiftUI never re-renders per frame.
final class CharacterNSView: NSView {
    let rig: CharacterRig
    let director: MotionDirector

    init(assets: CharacterAssets = .shared) {
        rig = CharacterRig(assets: assets)
        director = MotionDirector(rig: rig)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(rig.layer)
        layer?.masksToBounds = true
        setAccessibilityElement(false)   // the notch view carries the spoken text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rig.layer.frame = bounds
        CATransaction.commit()
        rig.layout()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // SwiftUI handles input
}

/// A live character for SwiftUI. `controller` lets the owner drive motion.
struct CharacterView: NSViewRepresentable {
    let controller: CharacterController
    var canvasCenter: CGFloat = 0.5

    func makeNSView(context: Context) -> CharacterNSView {
        let view = controller.view
        view.rig.canvasCenter = canvasCenter
        return view
    }

    func updateNSView(_ view: CharacterNSView, context: Context) {
        // Per frame while SwiftUI animates (see AnimatedCharacterView), so no
        // Core Animation easing of its own: it rides the notch's spring.
        if view.rig.canvasCenter != canvasCenter { view.rig.canvasCenter = canvasCenter }
    }
}

/// The notch's character. Interpolates `canvasCenter` on the same spring as
/// its frame, so the character glides with the notch instead of jumping to
/// its new horizontal anchor when the layout changes.
struct AnimatedCharacterView: View, Animatable {
    let controller: CharacterController
    var canvasCenter: CGFloat

    var animatableData: CGFloat {
        get { canvasCenter }
        set { canvasCenter = newValue }
    }

    var body: some View {
        CharacterView(controller: controller, canvasCenter: canvasCenter)
    }
}

/// Owns one character view and its director. One per surface (the notch,
/// the preview screen), so the notch never shows two characters at once.
@MainActor
final class CharacterController {
    let view = CharacterNSView()
    var director: MotionDirector { view.director }

    func apply(intensity: Double, reduceMotion: Bool) {
        director.intensity = intensity
        director.reduceMotion = reduceMotion
    }
}
