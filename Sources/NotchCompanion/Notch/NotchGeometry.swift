import AppKit
import SwiftUI

/// The physical notch of a display, measured from the system's own
/// geometry (safe-area inset and the auxiliary areas either side of it).
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    /// Hardware notch size; zero on displays without one.
    var notchSize: CGSize
    var menuBarHeight: CGFloat
    /// Screen x of the notch's centre (the display's centre without one).
    var centerX: CGFloat

    var hasNotch: Bool { notchSize.width > 0 }

    /// Distance from the top of the screen to the top of our shape: 0 under a
    /// notch, just below the menu bar for the floating fallback.
    var topOffset: CGFloat { hasNotch ? 0 : menuBarHeight + 6 }

    /// Content starts below the camera housing.
    var contentTop: CGFloat { hasNotch ? notchSize.height : 0 }

    static func measure(_ screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let menuBar = max(0, frame.maxY - screen.visibleFrame.maxY)
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = right.minX - left.maxX
            return NotchGeometry(screenFrame: frame,
                                 notchSize: CGSize(width: width, height: screen.safeAreaInsets.top),
                                 menuBarHeight: max(menuBar, screen.safeAreaInsets.top),
                                 centerX: left.maxX + width / 2)
        }
        return NotchGeometry(screenFrame: frame, notchSize: .zero,
                             menuBarHeight: menuBar == 0 ? 24 : menuBar, centerX: frame.midX)
    }

    /// The built-in notched display if there is one, else the main display.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

enum NotchMode: Equatable {
    case hidden, compact, character, detail, list
}

enum NotchLayout {
    static let contentHeight: CGFloat = 100
    static let characterWidth: CGFloat = 300
    static let detailWidth: CGFloat = 470
    static let characterSlot: CGFloat = 214     // left part of the detail layout
    /// Character canvas aspect (300×116 in the Figma storyboard).
    static let canvasAspect: CGFloat = 300 / 116
    static let compactWing: CGFloat = 104
    static let listHeader: CGFloat = 56
    static let rowHeight: CGFloat = 48
    static let maxRows = 5
    static let panelWidth: CGFloat = 680
    static let panelExtraHeight: CGFloat = 360

    /// How far the collapsed silhouette stays inside the hardware notch, so
    /// it is invisible at rest and the first frames of an opening read as the
    /// notch itself growing.
    static let restInset = CGSize(width: 1.5, height: 1)

    /// Concave corners where the shape meets the top edge of the screen.
    static func flare(for mode: NotchMode, geometry g: NotchGeometry) -> CGFloat {
        guard g.hasNotch else { return 0 }
        switch mode {
        case .hidden: return 3
        case .compact: return 6
        case .character, .detail, .list: return 10
        }
    }

    static func bottomRadius(for mode: NotchMode, geometry g: NotchGeometry) -> CGFloat {
        switch mode {
        case .hidden: return g.hasNotch ? 11 : 18
        case .compact: return g.hasNotch ? 13 : 20
        case .character, .detail, .list: return 24
        }
    }

    /// Body size, without the flares.
    static func size(for mode: NotchMode, geometry g: NotchGeometry, rows: Int) -> CGSize {
        let nh = g.contentTop
        switch mode {
        case .hidden:
            guard g.hasNotch else { return CGSize(width: 200, height: 36) }
            let width = g.notchSize.width - 2 * restInset.width - 2 * flare(for: .hidden, geometry: g)
            return CGSize(width: max(0, width), height: max(0, g.notchSize.height - restInset.height))
        case .compact:
            return g.hasNotch ? CGSize(width: g.notchSize.width + 2 * compactWing, height: g.notchSize.height)
                              : CGSize(width: 230, height: 40)
        case .character:
            return CGSize(width: max(characterWidth, g.notchSize.width + 60), height: nh + contentHeight)
        case .detail:
            return CGSize(width: detailWidth, height: nh + contentHeight)
        case .list:
            return CGSize(width: detailWidth, height: nh + listHeader + CGFloat(min(rows, maxRows)) * rowHeight + 10)
        }
    }
}

/// The notch silhouette: flat top, concave flares into the screen edge,
/// rounded bottom. Falls back to a rounded pill away from a notch.
///
/// It is drawn hanging from the top centre of whatever rect it's given, at
/// an explicit size, so the size animates as shape data on the same spring
/// as the flares and corners, while the content around it keeps fixed
/// coordinates (nothing drifts as the silhouette grows).
nonisolated struct NotchShape: Shape {
    /// Body size, without the flares.
    var size: CGSize
    var flare: CGFloat
    var bottomRadius: CGFloat
    var pill: Bool

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(size.width, size.height), AnimatablePair(flare, bottomRadius)) }
        set {
            size = CGSize(width: newValue.first.first, height: newValue.first.second)
            flare = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    /// Continuous corners: control points pulled toward the corner, and the
    /// curve starting further along each edge, so curvature ramps up instead
    /// of jumping like a circular arc. `cornerReach` keeps the visual radius
    /// equal to a circle's (same midpoint).
    private static let smoothing: CGFloat = 0.8
    private static let cornerReach: CGFloat = (1 - 1 / 2.squareRoot()) / (0.5 - 0.375 * smoothing)
    private static let flareSmoothing: CGFloat = 0.7
    private static let flareDepth: CGFloat = 1.25     // flares run a little deeper than wide: a softer join

    func path(in rect: CGRect) -> Path {
        let h = max(0, size.height)
        if pill {
            let body = CGRect(x: rect.midX - size.width / 2, y: rect.minY, width: max(0, size.width), height: h)
            return Path(roundedRect: body, cornerRadius: min(h / 2, bottomRadius), style: .continuous)
        }
        let bodyWidth = max(0, size.width)
        let f = max(0, min(flare, bodyWidth / 4, h / 3))
        let fh = f * Self.flareDepth
        let reach = Self.cornerReach
        let r = max(0, min(bottomRadius, bodyWidth / (2 * reach), max(0, h - fh) / reach))
        let l = r * reach, k = l * (1 - Self.smoothing), fk = Self.flareSmoothing

        let x0 = rect.midX - bodyWidth / 2 - f, x1 = rect.midX + bodyWidth / 2 + f
        let top = rect.minY, bottom = rect.minY + h
        var p = Path()
        p.move(to: CGPoint(x: x0, y: top))
        p.addCurve(to: CGPoint(x: x0 + f, y: top + fh),
                   control1: CGPoint(x: x0 + f * fk, y: top),
                   control2: CGPoint(x: x0 + f, y: top + fh * (1 - fk)))
        p.addLine(to: CGPoint(x: x0 + f, y: bottom - l))
        p.addCurve(to: CGPoint(x: x0 + f + l, y: bottom),
                   control1: CGPoint(x: x0 + f, y: bottom - k),
                   control2: CGPoint(x: x0 + f + k, y: bottom))
        p.addLine(to: CGPoint(x: x1 - f - l, y: bottom))
        p.addCurve(to: CGPoint(x: x1 - f, y: bottom - l),
                   control1: CGPoint(x: x1 - f - k, y: bottom),
                   control2: CGPoint(x: x1 - f, y: bottom - k))
        p.addLine(to: CGPoint(x: x1 - f, y: top + fh))
        p.addCurve(to: CGPoint(x: x1, y: top),
                   control1: CGPoint(x: x1 - f, y: top + fh * (1 - fk)),
                   control2: CGPoint(x: x1 - f * fk, y: top))
        p.closeSubpath()
        return p
    }
}
