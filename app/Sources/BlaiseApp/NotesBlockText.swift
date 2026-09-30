import AppKit
import BlaiseCore
import SwiftUI

// Search-highlighted text for the pieces the notes pane hosts as SwiftUI
// (table cells, code), and the helpers that map a selection onto a block's
// own characters.

struct NotesBlockText: View {
    let source: AttributedString
    let terms: [String]

    var body: some View {
        Text(Self.displayText(source: source, terms: terms))
            .accessibilityHint(Self.searchHint(source: source, terms: terms))
    }

    /// The source with the search cues layered on.
    @MainActor
    static func displayText(source: AttributedString, terms: [String]) -> AttributedString {
        SearchHighlight.applied(to: source, terms: terms)
    }

    static func searchHint(source: AttributedString, terms: [String]) -> String {
        SearchTextMatcher.contains(String(source.characters), terms: terms)
            ? "Contains the current search match" : ""
    }
}

/// A block's own characters and the spans selected or marked in them.
@MainActor
enum NotesProseHost {
    /// Where a marked passage sits in the block's own characters. A block can
    /// repeat the same words, so the span names WHICH of its equals is marked;
    /// an occurrence the text no longer has falls back to its last one, the
    /// same choice the anchor resolver makes when a rewrite collapses
    /// duplicates. Text the block no longer contains marks nothing rather than
    /// guessing.
    static func markRange(of mark: SelectedSpan, in text: String) -> NSRange? {
        guard !mark.text.isEmpty else { return nil }
        var found: [Range<String.Index>] = []
        var cursor = text.startIndex
        while let next = text.range(of: mark.text, range: cursor..<text.endIndex) {
            found.append(next)
            cursor = text.index(after: next.lowerBound)
        }
        guard let hit = found.indices.contains(mark.occurrence) ? found[mark.occurrence] : found.last
        else { return nil }
        return NSRange(hit, in: text)
    }

    /// The selected span — its text and which occurrence of that text inside
    /// the block it is — or nil for an insertion point / empty range. The
    /// occurrence comes from where the selection actually starts, so selecting
    /// the second of two identical phrases reports the second.
    static func span(of range: NSRange, in text: String) -> SelectedSpan? {
        guard range.length > 0, let swift = Range(range, in: text) else { return nil }
        let selected = String(text[swift])
        guard !selected.isEmpty else { return nil }
        return SelectedSpan(
            text: selected,
            occurrence: spanOccurrence(
                of: selected, startingAt: text.distance(from: text.startIndex, to: swift.lowerBound),
                in: text))
    }
}

/// How selected prose is painted. The AppKit text host runs in the LIGHT
/// system appearance even though the pane around it is dark, so the system
/// fill it inherits is the light-mode one — pale blue under this palette's
/// near-white glyphs, which makes the one word the person is trying to correct
/// the least legible thing on screen. The fill is replaced with the palette's
/// own accent, at the alpha where it is still dark enough to carry the prose
/// ink and already light enough to read as a selection against the page.
@MainActor
enum BlockSelection {
    static var fill: NSColor { NSColor(Design.accent.opacity(0.45)) }
}
