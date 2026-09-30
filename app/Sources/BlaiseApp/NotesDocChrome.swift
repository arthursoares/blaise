import AppKit
import SwiftUI

/// Section chrome and headings drawn behind the notes text, per look (today's
/// `NoteSection` and `UserActionBoxChrome`). Rects are in the text view's
/// flipped space; each call leaves the graphics state as it found it.
@MainActor
enum NotesDocChrome {
    /// The chrome behind a section's content.
    static func drawSection(_ look: NotesDocLook, kind: Design.NoteSectionKind, rect: NSRect) {
        let accented = kind == .userActions
        if accented {
            switch look.userBox {
            case .field: break
            case .glass: return drawGlass(rect, radius: look.userRadius)
            case .marginNote: return drawMarginNote(rect, radius: look.userRadius)
            case .panel: return drawPanelRing(rect, radius: look.userRadius)
            }
        }
        switch look.chrome {
        case .field:
            let tint = Design.sectionTint(kind)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            NSColor(tint.opacity(accented ? 0.11 : 0.055)).setFill()
            path.fill()
            NSColor(tint.opacity(accented ? 0.38 : 0.14)).setStroke()
            path.lineWidth = 1
            path.stroke()
        case .bare:
            break
        case .card:
            // The material is the card view under the text; this is its hairline.
            let path = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: look.radius - 0.5, yRadius: look.radius - 0.5)
            NSColor(white: 1, alpha: 0.06).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// How far a user box's glow reaches past its edges (drawn only when a
    /// dirty rect meets the box grown by this much).
    static let glowReach: CGFloat = 48

    /// The heading ornament beside or under a title line (Aquarela's chip is
    /// drawn by the view). `textWidth` is the title's own width.
    static func drawHeading(_ look: NotesDocLook, line: NSRect, textWidth: CGFloat, left: CGFloat, width: CGFloat) {
        switch look.heading {
        case .chip:
            break
        case .tick:
            // 5 under the title: a 36×2 capsule, accent to support.
            let tick = NSRect(x: left, y: (line.maxY + NotesDocLook.titleLine + 5).rounded(), width: 36, height: 2)
            fill(NSBezierPath(roundedRect: tick, xRadius: 1, yRadius: 1), tick,
                 [NSColor(Design.accent), NSColor(Design.support)], diagonal: false)
        case .rule:
            // 10 after the title to the column's end, 1 below the row's middle.
            let start = left + textWidth + 10
            guard start < left + width else { return }
            let rule = NSRect(x: start, y: line.midY + 0.5, width: left + width - start, height: 1)
            fill(NSBezierPath(rect: rule), rule, [NSColor(Design.accent.opacity(0.35)), .clear], diagonal: false)
        }
    }

    // MARK: User boxes

    /// Estúdio: white 0.045 glass, a 1.5 pt accent→support ring, a soft accent glow.
    private static func drawGlass(_ rect: NSRect, radius: CGFloat) {
        withGlow(opacity: 0.12) {
            NSColor(white: 1, alpha: 0.045).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            drawRing(rect, radius: radius)
        }
    }

    /// Fluido: the material panel is a view under the text; its ring and glow.
    private static func drawPanelRing(_ rect: NSRect, radius: CGFloat) {
        // The panel is opaque to its shadow: the glow is the shadow of the
        // whole rounded rect, drawn only outside it.
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: rect.insetBy(dx: -glowReach, dy: -glowReach))
        outside.append(NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius))
        outside.windingRule = .evenOdd
        outside.addClip()
        withGlow(opacity: 0.14) {
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        drawRing(rect, radius: radius)
    }

    /// Caderno: accent 0.09 wash, a 3 pt solid accent leading bar, accent 0.22 hairline.
    private static func drawMarginNote(_ rect: NSRect, radius: CGFloat) {
        NSColor(Design.accent.opacity(0.09)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSColor(Design.accent).setFill()
        leadingBar(NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height)).fill()
        let stroke = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        NSColor(Design.accent.opacity(0.22)).setStroke()
        stroke.lineWidth = 1
        stroke.stroke()
    }

    /// Today's `UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)`
    /// 3 pt wide: its radii are clamped to half the width.
    private static func leadingBar(_ bar: NSRect) -> NSBezierPath {
        let r = bar.width / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bar.maxX, y: bar.minY))
        path.line(to: NSPoint(x: bar.maxX, y: bar.maxY))
        path.line(to: NSPoint(x: bar.minX + r, y: bar.maxY))
        path.appendArc(withCenter: NSPoint(x: bar.minX + r, y: bar.maxY - r), radius: r, startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: bar.minX, y: bar.minY + r))
        path.appendArc(withCenter: NSPoint(x: bar.minX + r, y: bar.minY + r), radius: r, startAngle: 180, endAngle: 270)
        path.close()
        return path
    }

    /// `strokeBorder(LinearGradient(accent 0.75 → support 0.75, topLeading →
    /// bottomTrailing), lineWidth: 1.5)`.
    private static func drawRing(_ rect: NSRect, radius: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let inset = rect.insetBy(dx: 0.75, dy: 0.75)
        context.addPath(
            CGPath(roundedRect: inset, cornerWidth: radius - 0.75, cornerHeight: radius - 0.75, transform: nil))
        context.setLineWidth(1.5)
        context.replacePathWithStrokedPath()
        context.clip()
        gradient([NSColor(Design.accent.opacity(0.75)), NSColor(Design.support.opacity(0.75))]).map {
            context.drawLinearGradient(
                $0, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }
        context.restoreGState()
    }

    /// Everything drawn in `body` casts one soft accent shadow as a whole
    /// (SwiftUI's `.shadow(color: accent.opacity(o), radius: 18, y: 4)`).
    private static func withGlow(opacity: CGFloat, _ body: () -> Void) {
        guard let context = NSGraphicsContext.current?.cgContext else { return body() }
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -4), blur: glowBlur,
            color: NSColor(Design.accent.opacity(opacity)).cgColor)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    static let glowBlur: CGFloat = 18

    private static func fill(_ path: NSBezierPath, _ rect: NSRect, _ colors: [NSColor], diagonal: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext, let gradient = gradient(colors) else { return }
        context.saveGState()
        path.addClip()
        context.drawLinearGradient(
            gradient, start: CGPoint(x: rect.minX, y: rect.minY),
            end: CGPoint(x: rect.maxX, y: diagonal ? rect.maxY : rect.minY), options: [])
        context.restoreGState()
    }

    private static func gradient(_ colors: [NSColor]) -> CGGradient? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let converted = colors.compactMap { $0.usingColorSpace(.sRGB)?.cgColor }
        return CGGradient(colorsSpace: space, colors: converted as CFArray, locations: nil)
    }
}

/// Fluido's material cards: one `NSVisualEffectView` per section box, a
/// sibling of the text view in the clip view, below it, so it scrolls with
/// the document while the text view stays the document view (a full-height
/// drawing view that is not the document view costs scrolling).
@MainActor
final class NotesDocCards {
    private var views: [NSVisualEffectView] = []

    func place(_ frames: [(rect: NSRect, radius: CGFloat)], in clip: NSView, below textView: NSView) {
        for (index, frame) in frames.enumerated() {
            if index == views.count {
                let card = NSVisualEffectView()
                card.material = .hudWindow
                card.blendingMode = .withinWindow
                card.state = .active
                card.wantsLayer = true
                card.layer?.masksToBounds = true
                clip.addSubview(card, positioned: .below, relativeTo: textView)
                views.append(card)
            }
            views[index].layer?.cornerRadius = frame.radius
            views[index].frame = frame.rect
        }
        while views.count > frames.count { views.removeLast().removeFromSuperview() }
    }
}
