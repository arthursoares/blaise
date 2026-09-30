import AppKit
import BlaiseCore
import SwiftUI

// Fluido's motion on the notes document, as today's pane has it: the shine
// sweep when notes materialize, the user box settling on a spring when an item
// completes (the row fades and shrinks away, what stood under it slides up),
// the sparkle burst when the LAST open item is ticked, and the soft scroll
// edge under the toolbar. The controller runs them (NotesDocumentView.swift);
// the pure parts live here.

@MainActor
enum NotesDocMotion {
    /// Today's `.spring(duration: 0.45, bounce: 0.2)` on the user box.
    static let settle = Spring(duration: 0.45, bounce: 0.2)
    /// Today's `.shine(duration: 1.1)`.
    static let shineDuration: CFTimeInterval = 1.1

    /// The user items that became done between two documents of the same
    /// notes — a tick, never a new meeting or a regeneration.
    static func completed(from old: NotesDocument, to new: NotesDocument) -> [String] {
        guard old.userItems == new.userItems else { return [] }
        return new.userItems.filter {
            let key = ActionItemKey.key(for: $0)
            return new.doneUserKeys.contains(key) && !old.doneUserKeys.contains(key)
        }
    }

    /// The user items that became open again between two documents of the
    /// same notes — an un-tick.
    static func reopened(from old: NotesDocument, to new: NotesDocument) -> [String] {
        guard old.userItems == new.userItems else { return [] }
        return new.userItems.filter {
            let key = ActionItemKey.key(for: $0)
            return old.doneUserKeys.contains(key) && !new.doneUserKeys.contains(key)
        }
    }

    /// The Pow shine at `fraction` (0…1) of its sweep over `content`: a
    /// white band, wider than the content twice over, travelling from the
    /// top-leading corner towards the bottom-trailing one. Returns the
    /// gradient's line and its white alphas (evenly spaced along the line).
    static func shine(over content: CGRect, fraction: CGFloat) -> (start: CGPoint, end: CGPoint, alphas: [CGFloat]) {
        let angle = atan2(content.height, content.width)
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        // The content's extent along the sweep (Pow's bounding box at the angle).
        let span = content.width * abs(cos(angle)) + content.height * abs(sin(angle))
        let centre = CGPoint(x: content.midX, y: content.midY)
        let middle = -span + fraction * 2 * span
        let base = sin(Double(fraction))
        let fade = 1 - pow(Double(fraction), 8)
        let alphas = stride(from: 0.0, through: .pi, by: 0.2).map {
            CGFloat(pow(sin($0), 2) * 0.8 * base * fade)
        }
        func point(_ offset: CGFloat) -> CGPoint {
            CGPoint(x: centre.x + direction.x * offset, y: centre.y + direction.y * offset)
        }
        return (point(middle - span), point(middle + span), alphas)
    }

    /// SwiftUI's `.easeInOut` (the cubic Bézier 0.42, 0, 0.58, 1), which
    /// Pow's shine rides: its value at time `t` (0…1).
    static func easeInOut(_ t: Double) -> CGFloat {
        let t = min(1, max(0, t))
        func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - s) * (1 - s) * s * a + 3 * (1 - s) * s * s * b + s * s * s
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<30 {
            let mid = (low + high) / 2
            if bezier(mid, 0.42, 0.58) < t { low = mid } else { high = mid }
        }
        return CGFloat(bezier((low + high) / 2, 0, 1))
    }

    /// `.softTopScrollEdge()` for an AppKit scroll view. AppKit has no public
    /// property for it (macOS 26 SDK): this is the call SwiftUI's
    /// `.scrollEdgeEffectStyle(.soft, for: .top)` makes on its own scroll
    /// view (style 1 on edge 0, read back from SwiftUI's). A no-op where the
    /// method is missing.
    static func setSoftTopEdge(_ scrollView: NSScrollView) {
        guard #available(macOS 26.0, *) else { return }
        let selector = NSSelectorFromString("setScrollPocketStyle:onEdge:")
        guard scrollView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Int, Int) -> Void
        unsafeBitCast(scrollView.method(for: selector), to: Setter.self)(scrollView, selector, 1, 0)
    }
}

/// The motion the controller is running.
@MainActor
final class NotesDocMotionState {
    /// The paragraphs holding the space a completed row (or the lines an
    /// un-ticked row took out of the box, above and below the Completed line)
    /// left, each with the space it held first, and how much of it is still
    /// open (one settle spring for all, overshoot included).
    var settleHolds: [Int: CGFloat] = [:]
    var settleLeft: CGFloat = 0
    var settleStart: CFTimeInterval = 0
    /// The completed row, as it looked, fading and shrinking away.
    var leaving: [(view: NSImageView, frame: NSRect)] = []
    /// "All done." coming in when the last open item completes.
    var fadingIn: Int?
    /// A row coming back (un-ticked): its space opens from nothing on the
    /// settle spring — `fraction` of its lines' height and spacing — while its
    /// picture fades and grows in over it.
    var opening: (paragraph: Int, anchor: String, lineHeight: CGFloat, fraction: CGFloat)?
    var openingStart: CFTimeInterval = 0
    var arriving: (view: NSImageView, frame: NSRect)?
    /// "All done.", a Completed line that goes and an expanded list's done
    /// row, as they looked, fading out while an un-ticked item comes back.
    var departing: [NSImageView] = []
    var burst: NSView?
    var shineStart: CFTimeInterval?
    var shineView: NotesDocShineView?
    var lastShineTick = 0
    var link: CADisplayLink?

    func settle(_ paragraph: Int) -> CGFloat { (settleHolds[paragraph] ?? 0) * settleLeft }
}
