import AppKit
import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

// The one-text-view document: the string it builds and the map from its
// character ranges back onto the notes blocks. Fictional notes only.

@MainActor
private func build(
    _ structured: NotesStructured, done: Set<String> = [], terms: [String] = [], expanded: Bool = false,
    direction: DesignDirection = .aquarela
) -> NotesDocument {
    NotesDocumentBuilder.build(
        NotesDocInput(
            structured: structured, doneKeys: done, searchTerms: terms, portuguese: false,
            userActionTitle: "Demo User — Action Items", completedExpanded: expanded, direction: direction))
}

private let quollItems = [
    ActionItem(owner: "Demo User", text: "Send the tide table to Quoll Harbor."),
    ActionItem(owner: "Demo User", text: "Book the ferry survey with Vexatron Labs."),
    ActionItem(owner: "Demo User", text: "Check the jetty lights before Friday."),
]

private func notes(summary: String = "The kelp survey moved to Thursday.", detailed: String = "") -> NotesStructured {
    NotesStructured(
        summary: summary, detailedNotes: detailed, decisions: ["The harbour lights stay amber."],
        actionItems: [ActionItem(owner: "Vexatron Labs", text: "Ship the buoy firmware.")],
        userActionItems: quollItems)
}

@MainActor
@Suite struct NotesDocumentParagraphMapTests {
    /// Every block's range lies inside its own paragraph, and the text system
    /// sees that paragraph as ONE paragraph.
    private func assertOneParagraphPerBlock(_ doc: NotesDocument) {
        let string = doc.text.string as NSString
        for block in doc.blocks where block.range.length > 0 {
            let paragraph = doc.paragraphs[block.paragraph].range
            #expect(NSIntersectionRange(paragraph, block.range) == block.range)
            let seen = string.paragraphRange(for: block.range)
            // The document's last paragraph has no trailing break.
            #expect(seen.location == paragraph.location)
            #expect(NSMaxRange(seen) == NSMaxRange(paragraph))
        }
    }

    @Test("a U+2029 inside notes text never splits a block's paragraph")
    func paragraphSeparatorInsideText() {
        let separator = "\u{2029}"
        let plain = build(notes(
            summary: "The kelp survey moved to Thursday, and the ferry waits.",
            detailed: "- Tide sensor calibration is finished.\n\nThe buoy firmware ships Monday."))
        let spiked = build(notes(
            summary: "The kelp survey moved to Thursday,\(separator)and the ferry waits.",
            detailed: "- Tide sensor\(separator)calibration is finished.\n\nThe buoy firmware\(separator)ships Monday."))

        // Same blocks, same identities, same paragraph count.
        #expect(spiked.blocks.map(\.anchorID) == plain.blocks.map(\.anchorID))
        #expect(spiked.paragraphs.count == plain.paragraphs.count)
        #expect(!spiked.text.string.contains(separator))

        // The block keeps the stored text (with its U+2029) as its text; the
        // string carries a line separator in the same UTF-16 position.
        let summary = spiked.blocks.first { $0.section == .summary && !NotesDocument.isEdge($0.anchorID) }!
        #expect(summary.blockText == "The kelp survey moved to Thursday,\(separator)and the ferry waits.")
        #expect(summary.hostText == summary.blockText)
        let shown = (spiked.text.string as NSString).substring(with: summary.range)
        #expect(shown == "The kelp survey moved to Thursday,\u{2028}and the ferry waits.")
        #expect((shown as NSString).length == (summary.hostText as NSString).length)

        assertOneParagraphPerBlock(spiked)

        // Click-to-block: every character of each block maps back onto it,
        // including the characters after the separator.
        for block in spiked.blocks where block.range.length > 0 {
            for offset in [0, block.range.length / 2, block.range.length - 1] {
                #expect(spiked.block(atCharacter: block.range.location + offset)?.anchorID == block.anchorID)
            }
        }
        // Placement: a row on the words after the separator is keyed to that block.
        let row = MeetingCorrection(
            id: "row-1", meetingID: "meeting-1", kind: .annotation, section: .summary,
            quotedText: "and the ferry waits", occurrence: 0, userText: "Confirm with the harbour.",
            createdAt: Date(timeIntervalSince1970: 0))
        let rows = notesDocRows([row], document: spiked, structured: notes(summary: summary.blockText)).rows
        #expect(rows[summary.anchorID]?.notes.map(\.id) == ["row-1"])
    }

    @Test("return and next-line characters are also kept inside the block")
    func otherParagraphBreaks() {
        let doc = build(notes(summary: "Vexatron Labs\u{0085}ships the buoy firmware.\rThe jetty waits."))
        #expect(!doc.text.string.contains("\u{0085}"))
        #expect(!doc.text.string.contains("\r"))
        assertOneParagraphPerBlock(doc)
    }

    @Test("a selection inside one block aims at it; across two it aims at nothing")
    func selectionAim() {
        let doc = build(notes(detailed: "First paragraph about the harbour.\n\nSecond paragraph about the kelp."))
        let first = doc.blocks.first { $0.section == .detailedNotes }!
        let aimed = doc.aim(for: NSRange(location: first.range.location + 6, length: 9))
        #expect(aimed?.block.anchorID == first.anchorID)
        #expect(aimed?.local == NSRange(location: 6, length: 9))
        let second = doc.blocks.last { $0.section == .detailedNotes }!
        #expect(doc.aim(for: NSRange(location: first.range.location, length: NSMaxRange(second.range) - first.range.location)) == nil)
    }

    @Test("a selection inside a code block aims at nothing (the whole block is aimed by click and menu)")
    func codeBlockAim() {
        let doc = build(notes(detailed: "Intro line.\n\n```\nbuild-4.2  frame p95 16.4 ms\n```"))
        let code = doc.blocks.first { doc.paragraphs[$0.paragraph].isCode }!
        #expect(code.targetable)
        #expect(doc.aim(for: NSRange(location: code.range.location + 2, length: 5)) == nil)
    }
}

@MainActor
@Suite struct NotesDocumentCompletedItemTests {
    private let done: Set<String> = [ActionItemKey.key(for: quollItems[1].text)]

    @Test("the done items sit behind a collapsed Completed (n) line by default")
    func collapsedByDefault() {
        let doc = build(notes(), done: done)
        let line = doc.completedDisclosure.map { (doc.text.string as NSString).substring(with: doc.paragraphs[$0].range) }
        #expect(line?.hasPrefix("Completed (1)") == true)
        #expect(!doc.text.string.contains(quollItems[1].text))
        #expect(doc.toggles.map(\.done) == [false, false])
    }

    @Test("expanded, done items are blocks in the user-action anchor space, in stored order, never a target")
    func expandedBlocks() {
        let doc = build(notes(), done: done, expanded: true)
        #expect(doc.text.string.contains(quollItems[1].text))
        let user = doc.blocks.filter { $0.section == .userActionItem }
        // Identities are the stored positions: ticking never renames a block.
        #expect(Set(user.map(\.anchorID)) == Set((0..<3).map(UserActionAnchor.id)))
        let completed = doc.block(UserActionAnchor.id(1))!
        #expect(!completed.targetable)
        #expect(completed.blockText == quollItems[1].text)
        #expect(doc.blocks.filter { !$0.targetable }.map(\.anchorID) == [UserActionAnchor.id(1)])
        // Its toggle is a done toggle.
        #expect(doc.toggles.first { $0.paragraph == completed.paragraph }?.done == true)
        // Never an AI target: a selection inside it aims at nothing.
        #expect(doc.aim(for: NSRange(location: completed.range.location + 2, length: 6)) == nil)
        // The open items still are.
        let open = doc.block(UserActionAnchor.id(0))!
        #expect(doc.aim(for: NSRange(location: open.range.location + 2, length: 6))?.block.anchorID == open.anchorID)
    }

    @Test("a row anchored to a done item's text is placed under that item")
    func rowUnderCompletedItem() {
        let row = MeetingCorrection(
            id: "row-done", meetingID: "meeting-1", kind: .annotation, section: .userActionItem,
            quotedText: "ferry survey", occurrence: 0, userText: "Booked already.",
            createdAt: Date(timeIntervalSince1970: 0))
        let structured = notes()
        let doc = build(structured, done: done, expanded: true)
        let rows = notesDocRows([row], document: doc, structured: structured).rows
        #expect(rows[UserActionAnchor.id(1)]?.notes.map(\.id) == ["row-done"])
        #expect(doc.block(UserActionAnchor.id(1)) != nil)
    }

    @Test("ticking an item does not change any block's identity")
    func tickKeepsIdentities() {
        let before = build(notes(), expanded: true)
        let after = build(notes(), done: done, expanded: true)
        let ids = { (doc: NotesDocument) in Set(doc.blocks.map(\.anchorID)) }
        #expect(ids(before) == ids(after))
    }
}

@MainActor
@Suite struct NotesDocumentInlineAndCopyTests {
    @Test("links carry their URL and strikethrough is struck")
    func linksAndStrikethrough() {
        let doc = build(notes(summary: "See the [milestone board](https://example.com/board) and ~~the old date~~ now."))
        let text = doc.text
        let linkRange = (text.string as NSString).range(of: "milestone board")
        #expect(text.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
            == URL(string: "https://example.com/board"))
        let struck = (text.string as NSString).range(of: "the old date")
        #expect(text.attribute(.strikethroughStyle, at: struck.location, effectiveRange: nil) as? Int
            == NSUnderlineStyle.single.rawValue)
        let plain = (text.string as NSString).range(of: "See the")
        #expect(text.attribute(.link, at: plain.location, effectiveRange: nil) == nil)
        #expect(text.attribute(.strikethroughStyle, at: plain.location, effectiveRange: nil) == nil)
    }

    @Test("search highlight layers over a link")
    func searchOverLink() {
        let doc = build(notes(summary: "See the [milestone board](https://example.com/board) now."), terms: ["milestone"])
        let match = (doc.text.string as NSString).range(of: "milestone")
        #expect(doc.text.attribute(.link, at: match.location, effectiveRange: nil) != nil)
        #expect(doc.text.attribute(.backgroundColor, at: match.location, effectiveRange: nil) != nil)
        #expect(doc.blocks.first { $0.section == .summary && !NotesDocument.isEdge($0.anchorID) }?.searchMatch == true)
        #expect(doc.blocks.first { $0.section == .decision }?.searchMatch == false)
    }

    @Test("copied text is clean: no placeholders, newlines for line breaks, readable list markers")
    func cleanCopy() {
        let doc = build(notes(
            summary: "Harbour line one  \nline two.",
            detailed: "- Tide sensor calibrated.\n- Ferry\ttimetable early.\n\n1. First step.\n2. Second step.\n\n---\n\n```\nbuild-4.2\tframe 16.4\n```"))
        let copied = NotesDocument.copyText(doc.text).string
        #expect(!copied.contains("\u{200B}"))
        #expect(!copied.contains("\u{2028}"))
        #expect(copied.contains("Harbour line one\nline two."))
        #expect(copied.contains("• Tide sensor calibrated."))
        #expect(copied.contains("• Ferry\ttimetable early."))
        #expect(copied.contains("1. First step."))
        #expect(copied.contains("2. Second step."))
        #expect(!copied.contains("•\t"))
        #expect(!copied.contains("1.\t"))
        // A tab inside the notes' own text is kept.
        #expect(copied.contains("build-4.2\tframe 16.4"))
    }

    @Test("a U+200B in the notes' own text survives a copy; only the pane's placeholders are dropped")
    func genuineZeroWidthSpaceSurvivesCopy() {
        let doc = build(notes(
            summary: "Harbour\u{200B}line stays.",
            detailed: "Intro line.\n\n```\nalpha\u{200B}beta\n```\n\n---\n\n| Buoy | Owner |\n| --- | --- |\n| B1 | Quoll |"))
        // The document holds placeholders (head, divider, table, tail) and the
        // two genuine characters.
        let string = doc.text.string as NSString
        var zeroWidth = 0
        for index in 0..<string.length where string.character(at: index) == 0x200B { zeroWidth += 1 }
        #expect(zeroWidth > 2)
        let copied = NotesDocument.copyText(doc.text).string
        #expect(copied.contains("Harbour\u{200B}line stays."))
        #expect(copied.contains("alpha\u{200B}beta"))
        #expect(copied.components(separatedBy: "\u{200B}").count - 1 == 2)
    }
}

@MainActor
@Suite struct NotesDocumentOccurrenceTests {
    /// Today's counter, block by block: the oracle.
    private func today(_ texts: [String]) -> [Int] {
        let folded = CorrectionAnchoring.FoldedBlocks(texts)
        return texts.indices.map { CorrectionAnchoring.occurrence(ofBlockAt: $0, in: folded) }
    }

    private func fast(_ texts: [String]) -> [Int] {
        fastOccurrences(in: CorrectionAnchoring.FoldedBlocks(texts))
    }

    @Test("the fast counter gives today's occurrence for composed, decomposed and repeated blocks")
    func matchesToday() {
        let lists: [[String]] = [
            // Canonically equal, differently encoded (both orders).
            ["Caf\u{00E9} opens Friday.", "Cafe\u{0301} opens Friday."],
            ["Cafe\u{0301} opens Friday.", "Caf\u{00E9} opens Friday."],
            // Exact repeats, and a shorter block inside a longer earlier one.
            ["Ship it.", "Ship it.", "Ship it."],
            ["Ship it after the Quoll Harbor review.", "Ship it", "ship  IT"],
            ["Vexatron Labs keeps the buoy.", "The kelp survey moved.", "vexatron labs keeps the buoy."],
            // A base letter that a combining mark extends in an earlier block.
            ["Cafe\u{0301} and more", "cafe"],
            ["cafe", "Cafe\u{0301} and more", "Caf\u{00E9}"],
            // Combining marks whose canonical order differs.
            ["Xa\u{0301}\u{0323}y harbour", "Xa\u{0323}\u{0301}y harbour", "a\u{0301}", "Xa\u{0301}"],
            ["Quoll a\u{0323}\u{0301}", "a\u{0301}\u{0323}", "Quoll a\u{0301}\u{0323}"],
            // Hangul composed vs jamo, and a precomposed Å vs the Ångström sign.
            ["\u{D55C} buoy", "\u{1112}\u{1161}\u{11AB} buoy", "\u{212B} tide", "\u{00C5} tide", "A\u{030A} tide"],
            // Markdown tokens and blanks fold away.
            ["**Kelp** survey", "Kelp survey", "", "  ", "kelp"],
            // Tibetan vowel signs Foundation's decomposition leaves out of
            // canonical order, next to a mark (both spellings, both orders).
            ["\u{00E5}\u{0F73} buoy", "\u{00E5}\u{0F71}\u{0F72} buoy"],
            ["xa\u{0300}\u{0F73}", "a\u{0300}\u{0F71}\u{0F72}"],
            ["\u{00E5}\u{0F75} tide", "a\u{030A}\u{0F71}\u{0F74} tide", "\u{00E5}\u{0F81}", "a\u{0F71}\u{0F80}\u{030A}"],
            // Marks reordered across a block's first or last scalar once
            // syntax between them folds away.
            ["Quoll a\u{0301}_\u{0323}y Harbor", "_\u{0323}y Harbor", "Quoll a\u{0301}", "\u{0323}"],
            ["x\u{00E1}\u{0323}y", "x\u{00E1}", "\u{0323}\u{0301}y"],
        ]
        for texts in lists {
            #expect(fast(texts) == today(texts), "\(texts.map { Array($0.unicodeScalars) })")
        }
        // The case that went wrong: the second of two canonically equal
        // decisions is the SECOND occurrence, as today counts it.
        #expect(fast(["Caf\u{00E9} opens Friday.", "Cafe\u{0301} opens Friday."]) == [0, 1])
    }

    @Test("the builder stores today's occurrence on every block of a real-size note")
    func builderMatchesToday() {
        var paragraphs: [String] = []
        for index in 0..<160 {
            switch index % 5 {
            case 0: paragraphs.append("Vexatron Labs moved the buoy survey \(index % 7) days.")
            case 1: paragraphs.append("Caf\u{00E9} review at Quoll Harbor.")
            case 2: paragraphs.append("Cafe\u{0301} review at Quoll Harbor.")
            case 3: paragraphs.append("Ship it.")
            default: paragraphs.append("The kelp line \(index) holds.")
            }
        }
        let doc = build(notes(detailed: paragraphs.joined(separator: "\n\n")))
        let detailed = doc.blocks.filter { $0.section == .detailedNotes && !NotesDocument.isEdge($0.anchorID) }
        let parsed = MarkdownBlocks.parse(paragraphs.joined(separator: "\n\n")).map { String($0.text.characters) }
        #expect(detailed.map(\.occurrence) == today(parsed))
    }

    @Test("the fast counter gives today's occurrence on generated hostile block lists (fixed seed)")
    func fuzzMatchesToday() {
        let result = occurrenceFuzz(rounds: 5_000, seed: 0x5EED_0F73)
        #expect(result.mismatches.isEmpty, "\(result.mismatches.prefix(5))")
        #expect(result.positives > 1_000, "the generator must produce contained pairs")
    }
}

/// Block lists built to hold one another — substrings by Character, by
/// scalar, of the fold, recomposed, decomposed, with the Tibetan vowel signs
/// respelled — over hostile scalars; the fast counter against today's.
@MainActor
func occurrenceFuzz(rounds: Int, seed: UInt64) -> (lists: Int, pairs: Int, positives: Int, mismatches: [String]) {
    var state = seed
    func int(_ n: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(n))
    }
    let alphabet: [String] = [
        "e", "a", "A", "x", "y", " ", "\n", "\t", "\u{0301}", "\u{0323}", "\u{0300}", "\u{0308}", "\u{030A}",
        "\u{0345}", "\u{0344}", "\u{00E9}", "\u{00E1}", "\u{00C5}", "\u{00E5}", "\u{212B}", "\u{212A}", "k",
        "\u{0130}", "i", "\u{00DF}", "\u{FB01}", "\u{1FB3}", "\u{200D}", "\u{1F1FA}", "\u{1F1F8}",
        "\u{1112}", "\u{1161}", "\u{11AB}", "\u{D55C}", "\u{0958}", "\u{0915}", "\u{093C}",
        "\u{0F40}", "\u{0F71}", "\u{0F72}", "\u{0F74}", "\u{0F80}", "\u{0F73}", "\u{0F75}", "\u{0F81}",
        "*", "_", "#", "[", "]", "`", "\u{0B47}", "\u{0B3E}", "\u{0B4B}", "\u{05B8}", "\u{05B7}", "\u{05D0}",
        "\u{0340}", "\u{0343}", "\u{0313}", "\u{1E9B}", "\u{0627}", "\u{0653}", "\u{0622}", "\u{1B05}", "\u{1B35}",
    ]
    let respell: [(String, String)] = [
        ("\u{0F73}", "\u{0F71}\u{0F72}"), ("\u{0F75}", "\u{0F71}\u{0F74}"), ("\u{0F81}", "\u{0F71}\u{0F80}"),
    ]
    func random(_ maxLen: Int) -> String { (0..<int(maxLen + 1)).map { _ in alphabet[int(alphabet.count)] }.joined() }
    func scalarSlice(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        guard !scalars.isEmpty else { return s }
        let a = int(scalars.count), b = a + 1 + int(scalars.count - a)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[a..<b])
        return String(view)
    }
    func derived(from s: String) -> String {
        switch int(7) {
        case 0:
            let chars = Array(s)
            guard !chars.isEmpty else { return s }
            let a = int(chars.count)
            return String(chars[a..<(a + 1 + int(chars.count - a))])
        case 1: return scalarSlice(s)
        case 2: return scalarSlice(CorrectionAnchoring.fold(s))
        case 3: return scalarSlice(s).precomposedStringWithCanonicalMapping
        case 4: return scalarSlice(s).decomposedStringWithCanonicalMapping
        case 5:
            var out = int(2) == 0 ? s : scalarSlice(s)
            for (one, two) in respell {
                out = int(2) == 0 ? out.replacingOccurrences(of: one, with: two) : out.replacingOccurrences(of: two, with: one)
            }
            return out
        default: return s
        }
    }
    var pairs = 0, positives = 0
    var mismatches: [String] = []
    for _ in 0..<rounds {
        var texts = [random(10)]
        for _ in 0..<(1 + int(4)) { texts.append(int(5) == 0 ? random(10) : derived(from: texts[int(texts.count)])) }
        // Sometimes a derived block comes first.
        if int(3) == 0 { for i in stride(from: texts.count - 1, to: 0, by: -1) { texts.swapAt(i, int(i + 1)) } }
        let folded = CorrectionAnchoring.FoldedBlocks(texts)
        let today = texts.indices.map { CorrectionAnchoring.occurrence(ofBlockAt: $0, in: folded) }
        let fast = fastOccurrences(in: folded)
        pairs += texts.count * (texts.count - 1) / 2
        positives += today.reduce(0, +)
        if fast != today {
            mismatches.append("\(texts.map { $0.unicodeScalars.map { String($0.value, radix: 16) } }) today \(today) fast \(fast)")
        }
    }
    return (rounds, pairs, positives, mismatches)
}

@MainActor
@Suite struct NotesDocumentUnanchoredTests {
    private func detailed(blocks: Int) -> String {
        let words = ["Vexatron", "Labs", "moved", "the", "Quoll", "Harbor", "buoy", "survey", "to", "Thursday", "and", "tide", "table"]
        return (0..<blocks).map { i in
            (0..<(18 + i % 9)).map { words[($0 * 7 + i) % words.count] }.joined(separator: " ") + " \(i)."
        }.joined(separator: "\n\n")
    }

    /// Today's `unanchoredAnnotations`, row by row: the oracle.
    private func today(_ rows: [MeetingCorrection], _ structured: NotesStructured) -> [String] {
        rows.filter { $0.kind == .annotation && $0.status != .resolved }.filter { row in
            CorrectionAnchoring.resolve(
                quote: row.quotedText, occurrence: row.occurrence,
                in: CorrectionAnchoring.blocks(of: structured, section: row.section)) == nil
        }.map(\.id)
    }

    @Test("the notes under Your notes are today's, worked out once per rows or document change")
    func workedOutOncePerChange() {
        let structured = NotesStructured(
            summary: "The kelp survey moved to Thursday.", detailedNotes: detailed(blocks: 626),
            decisions: ["The harbour lights stay amber."], actionItems: [], userActionItems: [])
        var rows: [MeetingCorrection] = []
        for i in 0..<200 {
            let stale = i % 10 == 0
            rows.append(MeetingCorrection(
                id: "n\(i)", meetingID: "meeting-1", kind: i % 7 == 0 ? .understanding : .annotation,
                section: i % 13 == 0 ? .decision : .detailedNotes,
                quotedText: stale ? "a passage Quoll Harbor rewrote \(i)" : (i % 13 == 0 ? "harbour lights" : " \(i * 3 % 626)."),
                userText: "Check with Vexatron Labs.", status: i % 11 == 0 ? .resolved : .pending,
                createdAt: Date(timeIntervalSince1970: 0)))
        }
        let doc = NotesDocumentBuilder.build(
            NotesDocInput(
                structured: structured, doneKeys: [], searchTerms: [], portuguese: false,
                userActionTitle: "Demo User — Action Items", direction: .aquarela))
        let cache = NotesDocCache()
        _ = cache.rows(rows, for: doc, structured: structured)
        let expected = today(rows, structured)
        #expect(!expected.isEmpty)
        #expect(cache.unanchored.map(\.id) == expected)
        // A render with nothing changed does no anchoring work at all.
        let start = CACurrentMediaTime()
        for _ in 0..<100 { _ = cache.rows(rows, for: doc, structured: structured) }
        #expect((CACurrentMediaTime() - start) * 1000 < 20)
        #expect(cache.unanchored.map(\.id) == expected)
        // A rows change is picked up.
        let fewer = Array(rows.dropFirst(10))
        _ = cache.rows(fewer, for: doc, structured: structured)
        #expect(cache.unanchored.map(\.id) == today(fewer, structured))
    }
}

@MainActor
@Suite struct NotesDocumentRowsFoldTests {
    private func detailed(blocks: Int) -> String {
        let words = ["Vexatron", "Labs", "moved", "the", "Quoll", "Harbor", "buoy", "survey", "to", "Thursday", "and", "tide", "table"]
        return (0..<blocks).map { i in
            (0..<(18 + i % 9)).map { words[($0 * 7 + i) % words.count] }.joined(separator: " ") + " \(i)."
        }.joined(separator: "\n\n")
    }

    private func rows(_ count: Int) -> [MeetingCorrection] {
        (0..<count).map { i in
            MeetingCorrection(
                id: "n\(i)", meetingID: "meeting-1", kind: i % 7 == 0 ? .understanding : .annotation,
                section: i % 13 == 0 ? .summary : .detailedNotes,
                quotedText: i % 10 == 0 ? "a passage Quoll Harbor rewrote \(i)" : (i % 13 == 0 ? "kelp survey" : " \(i * 3 % 626)."),
                occurrence: i % 3, userText: "Check with Vexatron Labs.", status: i % 11 == 0 ? .resolved : .pending,
                createdAt: Date(timeIntervalSince1970: 0))
        }
    }

    /// Today's grouping of the summary and detailed rows, each row resolved
    /// against its section folded on the spot: the oracle.
    private func today(_ rows: [MeetingCorrection], _ structured: NotesStructured) -> [String: [String]] {
        var out: [String: [String]] = [:]
        let live = rows.filter {
            $0.kind == .annotation ? $0.status != .resolved : ($0.status != .applied && $0.status != .resolved)
        }
        for (section, parsed, anchor) in [
            (MeetingCorrection.Section.summary, MarkdownBlocks.parse(structured.summary), NotesBlockAnchor.summary),
            (.detailedNotes, MarkdownBlocks.parse(structured.detailedNotes.trimmingCharacters(in: .whitespacesAndNewlines)),
             NotesBlockAnchor.detailed),
        ] {
            let ui = parsed.map { String($0.text.characters) }
            for kind in [MeetingCorrection.Kind.annotation, .understanding] {
                for row in live where row.kind == kind && row.section == section
                    && CorrectionAnchoring.resolve(
                        quote: row.quotedText, occurrence: row.occurrence,
                        in: CorrectionAnchoring.blocks(of: structured, section: section)) != nil
                {
                    let index = CorrectionAnchoring.resolve(
                        quote: row.quotedText, occurrence: row.occurrence, in: ui)?.blockIndex ?? ui.count - 1
                    out["\(kind == .annotation ? "note" : "pending") \(anchor(parsed[index].id))", default: []].append(row.id)
                }
            }
        }
        return out
    }

    @Test("rows are placed as today, each section folded once for all of them")
    func sectionFoldedOncePerChange() {
        let structured = NotesStructured(
            summary: "The kelp survey moved to Thursday.", detailedNotes: detailed(blocks: 626),
            decisions: ["The harbour lights stay amber."], actionItems: [], userActionItems: [])
        let doc = NotesDocumentBuilder.build(
            NotesDocInput(
                structured: structured, doneKeys: [], searchTerms: [], portuguese: false,
                userActionTitle: "Demo User — Action Items", direction: .aquarela))
        let rows = rows(200)
        let (grouped, _) = notesDocRows(rows, document: doc, structured: structured)
        var placed: [String: [String]] = [:]
        for (anchor, blockRows) in grouped {
            if !blockRows.notes.isEmpty { placed["note \(anchor)"] = blockRows.notes.map(\.id) }
            if !blockRows.pending.isEmpty { placed["pending \(anchor)"] = blockRows.pending.map(\.id) }
        }
        let expected = today(rows, structured)
        #expect(expected.values.map(\.count).reduce(0, +) > 100)
        #expect(placed == expected)
        // The cost is the tail's (which folds each section once over the same
        // rows), not a fold of the whole section per row.
        func median(_ body: () -> Void) -> Double {
            (0..<5).map { _ in
                let start = CACurrentMediaTime()
                body()
                return CACurrentMediaTime() - start
            }.sorted()[2]
        }
        let grouping = median { _ = notesDocRows(rows, document: doc, structured: structured) }
        let tail = median { _ = notesDocUnanchored(rows, structured: structured, space: doc.space) }
        #expect(grouping < tail * 3, "grouping \(grouping * 1000) ms vs tail \(tail * 1000) ms")
    }

    @Test("the rows read the document's rendered space: no rows pass parses or folds the notes again")
    func rowsReadTheDocumentSpace() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        let source = try String(
            contentsOf: root.appendingPathComponent("app/Sources/BlaiseApp/NotesDocument.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "func notesDocRows("))
        let end = try #require(source.range(of: "\n}\n", range: start.upperBound ..< source.endIndex))
        let body = source[start.upperBound ..< end.lowerBound]
        // The body read is the real one: it asks the document's space for both rendered sections.
        #expect(body.contains("document.space.foldedBlocks(of: .summary)"))
        #expect(body.contains("document.space.foldedBlocks(of: .detailedNotes)"))
        #expect(!body.contains("MarkdownBlocks.parse"), "the document parsed these notes once")
    }
}
