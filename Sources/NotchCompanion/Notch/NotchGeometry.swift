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
    static let flare: CGFloat = 9               // concave corners where the shape meets the top edge
    static let bottomRadius: CGFloat = 24
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

    static func size(for mode: NotchMode, geometry g: NotchGeometry, rows: Int) -> CGSize {
        let nh = g.contentTop
        switch mode {
        case .hidden:
            return g.hasNotch ? CGSize(width: max(0, g.notchSize.width - 6), height: max(0, g.notchSize.height - 4))
                              : CGSize(width: 200, height: 36)
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

/// The expanded notch: flat top, concave flares into the screen edge,
/// rounded bottom. Falls back to a rounded pill away from a notch.
nonisolated struct NotchShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat
    var pill: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, bottomRadius) }
        set { flare = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        if pill {
            return Path(roundedRect: rect, cornerRadius: min(rect.height / 2, 20), style: .continuous)
        }
        let w = rect.width, h = rect.height
        let f = min(flare, w / 4, h / 2)
        let r = min(bottomRadius, (w - 2 * f) / 2, max(0, h - f))
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: f, y: f), control: CGPoint(x: f, y: 0))
        p.addLine(to: CGPoint(x: f, y: h - r))
        p.addQuadCurve(to: CGPoint(x: f + r, y: h), control: CGPoint(x: f, y: h))
        p.addLine(to: CGPoint(x: w - f - r, y: h))
        p.addQuadCurve(to: CGPoint(x: w - f, y: h - r), control: CGPoint(x: w - f, y: h))
        p.addLine(to: CGPoint(x: w - f, y: f))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - f, y: 0))
        p.closeSubpath()
        return p
    }
}
