import AppKit
import BlaiseCore

/// How one design direction lays the notes document out: section headings,
/// the chrome around a section, where its content starts, and the reading
/// face. The values are today's `NoteSection`, `UserActionBoxChrome` and
/// `Design.readingFont`; colors are read from `Design` where they are drawn.
struct NotesDocLook: Equatable {
    /// Aquarela: tinted chip + title. Estúdio and Fluido: uppercase caps over
    /// a gradient tick. Caderno: small-caps serif with a fading hairline.
    enum Heading: Equatable { case chip, tick, rule }
    /// What stands behind a section's content: Aquarela's tinted field,
    /// nothing (the page), or Fluido's material card.
    enum Chrome: Equatable { case field, bare, card }
    /// The user-action box: Aquarela's louder field, Estúdio's glass with a
    /// gradient ring and glow, Caderno's margin note with a leading bar,
    /// Fluido's material panel with the ring and glow.
    enum UserBox: Equatable { case field, glass, marginNote, panel }

    struct Insets: Equatable {
        var leading: CGFloat
        var trailing: CGFloat
        var top: CGFloat
        var bottom: CGFloat

        static func all(_ value: CGFloat) -> Insets { Insets(leading: value, trailing: value, top: value, bottom: value) }
    }

    var direction: DesignDirection
    var heading: Heading
    var chrome: Chrome
    var userBox: UserBox
    /// Where the content of an ordinary section sits inside its chrome.
    var content: Insets
    /// Where the user's own action items sit inside their box.
    var userContent: Insets
    /// From the bottom of the title line to the top of the section's chrome.
    var titleGap: CGFloat
    var radius: CGFloat
    var userRadius: CGFloat
    var serifReading: Bool
    /// List markers in the accent (Caderno) instead of tertiary ink.
    var accentMarkers: Bool

    static func of(_ direction: DesignDirection) -> NotesDocLook {
        switch direction {
        case .aquarela:
            return NotesDocLook(
                direction: direction, heading: .chip, chrome: .field, userBox: .field, content: .all(14),
                userContent: .all(14), titleGap: 9, radius: 12, userRadius: 12, serifReading: false,
                accentMarkers: false)
        case .estudio:
            // Title, 5, the 2 pt tick, 10 to the content.
            return NotesDocLook(
                direction: direction, heading: .tick, chrome: .bare, userBox: .glass, content: .all(0),
                userContent: .all(16), titleGap: 5 + 2 + 10 + titleLine, radius: 0, userRadius: 14, serifReading: false,
                accentMarkers: false)
        case .caderno:
            return NotesDocLook(
                direction: direction, heading: .rule, chrome: .bare, userBox: .marginNote, content: .all(0),
                userContent: Insets(leading: 18, trailing: 16, top: 14, bottom: 14), titleGap: 10 + titleLine, radius: 0,
                userRadius: 10, serifReading: true, accentMarkers: true)
        case .fluido:
            return NotesDocLook(
                direction: direction, heading: .tick, chrome: .card, userBox: .panel, content: .all(14),
                userContent: .all(16), titleGap: 5 + 2 + 10 + titleLine, radius: 14, userRadius: 14, serifReading: false,
                accentMarkers: false)
        }
    }

    /// TextKit's line for a caps or small-caps title ends 1 pt higher under
    /// its words than SwiftUI's Text frame does (measured against today's
    /// pixels): what hangs under the title starts 1 pt further down.
    static let titleLine: CGFloat = 1

    /// How much lower than a plain paragraph the "Completed (n)" label stands
    /// (today's disclosure row); Caderno's serif row stands 1 pt lower still
    /// (measured against today's pixels).
    @MainActor var disclosureAbove: CGFloat { NotesDocStyle.disclosureAbove + (direction == .caderno ? 1 : 0) }

    func insets(_ kind: Design.NoteSectionKind) -> Insets { kind == .userActions ? userContent : content }

    /// `Design.readingFont`: Caderno reads in New York one point larger.
    func readingFont(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let system = NSFont.systemFont(ofSize: serifReading ? size + 1 : size, weight: weight)
        guard serifReading, let serif = system.fontDescriptor.withDesign(.serif) else { return system }
        return NSFont(descriptor: serif, size: size + 1) ?? system
    }

    /// The section title as the heading shows it.
    func titleText(_ title: String) -> String { heading == .tick ? title.uppercased() : title }

    /// The heading's face: Aquarela 12 semibold; Estúdio and Fluido 11 bold,
    /// tracked 1.6; Caderno New York 13.5 semibold in small caps, tracked 0.5.
    var titleFont: NSFont {
        switch heading {
        case .chip: return .systemFont(ofSize: 12, weight: .semibold)
        case .tick: return .systemFont(ofSize: 11, weight: .bold)
        case .rule:
            let system = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
            guard let serif = system.fontDescriptor.withDesign(.serif) else { return system }
            // SwiftUI's `.smallCaps()`: lower- and upper-case letters both as small capitals.
            let smallCaps = serif.addingAttributes([
                .featureSettings: [
                    [NSFontDescriptor.FeatureKey.typeIdentifier: kLowerCaseType,
                     NSFontDescriptor.FeatureKey.selectorIdentifier: kLowerCaseSmallCapsSelector],
                    [NSFontDescriptor.FeatureKey.typeIdentifier: kUpperCaseType,
                     NSFontDescriptor.FeatureKey.selectorIdentifier: kUpperCaseSmallCapsSelector],
                ]
            ])
            return NSFont(descriptor: smallCaps, size: 13.5) ?? system
        }
    }

    var titleKerning: CGFloat {
        switch heading {
        case .chip: return 0
        case .tick: return 1.6
        case .rule: return 0.5
        }
    }
}
