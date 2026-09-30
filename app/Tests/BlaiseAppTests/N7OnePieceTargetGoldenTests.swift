import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

// n7 AC-1 / AC-2 one-piece invariant: in a block whose text holds no U+2029,
// a one-piece selection builds exactly the target the entry seam built before
// n7 (every expected value below was produced by the pre-n7 seam, committed
// before any stage-2 source change). Fictional notes only.

@Suite struct N7OnePieceTargetGoldenTests {

    private static func target(
        _ blockText: String, selection: SelectedSpan?, hostText: String? = nil,
        section: MeetingCorrection.Section = .summary, occurrence: Int = 0
    ) -> EditingTarget {
        NotesEditingEntry.target(
            .correct, section: section, anchorID: "notes-summary-0", blockText: blockText,
            occurrence: occurrence, selection: selection, hostText: hostText)
    }

    @Test("AC-1 golden: a padded span inside one paragraph")
    func paddedSpan() {
        #expect(
            Self.target("Quoll Harbor signs in May.", selection: SelectedSpan(text: " signs in "), occurrence: 3)
                == EditingTarget(
                    kind: .correct, section: .summary, anchorID: "notes-summary-0",
                    blockText: "Quoll Harbor signs in May.", quotedText: "signs in", displayQuote: "signs in",
                    occurrence: 3, spanOccurrence: 0, isWholeBlock: false))
    }

    @Test("AC-1 golden: a whole block (no selection)")
    func wholeBlock() {
        #expect(
            Self.target("Quoll Harbor signs in May.", selection: nil)
                == EditingTarget(
                    kind: .correct, section: .summary, anchorID: "notes-summary-0",
                    blockText: "Quoll Harbor signs in May.", quotedText: "Quoll Harbor signs in May.",
                    displayQuote: "Quoll Harbor signs in May.", occurrence: 0, spanOccurrence: 0,
                    isWholeBlock: true))
    }

    @Test("AC-1 golden: an action item's span, and a span over its owner prefix (whole-block fallback)")
    func actionItem() {
        let host = "Dana Marsh: File the permits"
        #expect(
            Self.target("File the permits", selection: SelectedSpan(text: "the permits"), hostText: host,
                        section: .actionItem, occurrence: 1)
                == EditingTarget(
                    kind: .correct, section: .actionItem, anchorID: "notes-summary-0",
                    blockText: "File the permits", quotedText: "the permits", displayQuote: "the permits",
                    occurrence: 1, spanOccurrence: 0, isWholeBlock: false))
        #expect(
            Self.target("File the permits", selection: SelectedSpan(text: "Marsh: File"), hostText: host,
                        section: .actionItem)
                == EditingTarget(
                    kind: .correct, section: .actionItem, anchorID: "notes-summary-0",
                    blockText: "File the permits", quotedText: "File the permits", displayQuote: host,
                    occurrence: 0, spanOccurrence: 0, isWholeBlock: true))
    }

    @Test("AC-1 golden: the second of two equal words, selected with its trailing space")
    func repeatedWords() {
        #expect(
            Self.target("go and go again", selection: SelectedSpan(text: "go ", occurrence: 1))
                == EditingTarget(
                    kind: .correct, section: .summary, anchorID: "notes-summary-0",
                    blockText: "go and go again", quotedText: "go", displayQuote: "go",
                    occurrence: 0, spanOccurrence: 1, isWholeBlock: false))
    }
}
