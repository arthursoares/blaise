import AppKit
import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

// n7 stage 2 — the notes pane's seams: the rendered block space (AC-3 pane
// half), capture (AC-1), placement, marks, the "Your notes" tail and
// navigation (AC-4), the fallback (AC-6) and the recovery boundary (AC-8).
// Fictional notes only (Vexatron Labs / Quoll Harbor).

private let sep = "\u{2029}"

@MainActor
private func build(_ structured: NotesStructured, done: Set<String> = [], expanded: Bool = false) -> NotesDocument {
    NotesDocumentBuilder.build(
        NotesDocInput(
            structured: structured, doneKeys: done, searchTerms: [], portuguese: false,
            userActionTitle: "Demo User — Action Items", completedExpanded: expanded, direction: .aquarela))
}

private func notes(
    summary: String = "Quoll Harbor signs in May.",
    detailed: String = "",
    decisions: [String] = [],
    actions: [ActionItem] = [],
    user: [ActionItem] = []
) -> NotesStructured {
    NotesStructured(
        title: "Quoll Harbor sonar review", summary: summary, detailedNotes: detailed,
        decisions: decisions, actionItems: actions, userActionItems: user)
}

/// The document range from the start of `from` to the end of `to` (each the
/// first occurrence at or after the previous match).
@MainActor
private func range(_ doc: NotesDocument, from: String, to: String) -> NSRange {
    let text = doc.text.string as NSString
    let start = text.range(of: from)
    let end = text.range(of: to, options: [], range: NSRange(location: start.location, length: text.length - start.location))
    return NSRange(location: start.location, length: NSMaxRange(end) - start.location)
}

private func row(
    _ id: String, _ kind: MeetingCorrection.Kind, _ section: MeetingCorrection.Section, _ quote: String,
    occurrence: Int = 0, status: MeetingCorrection.Status? = nil
) -> MeetingCorrection {
    MeetingCorrection(
        id: id, meetingID: "meeting-n7", kind: kind, section: section, quotedText: quote,
        occurrence: occurrence, userText: "Note \(id)",
        status: status ?? (kind == .annotation ? .applied : .pending),
        createdAt: Date(timeIntervalSince1970: 1_780_000_000))
}

@MainActor
private func passage(_ capture: NotesDocument.Capture) -> PassageCapture? {
    if case .passage(let passage) = capture { return passage }
    return nil
}

// MARK: - AC-3 (pane half)

@MainActor
@Suite struct N7PaneBlockSpaceTests {

    @Test("AC-3 pane half: every pane block's text equals renderedBlocks' text for its identity, every section and block kind")
    func paneTextsAreTheRenderedSpace() {
        let structured = notes(
            summary: "Quoll Harbor **signs** in May.\n\n## Scope\n\n> The barge waits.\n\n---\n\nRead the [brief](https://example.com/brief).",
            detailed: "- Load the buoys\n- Seal the crates\n\n1. First\n2. Second\n\n```\nstep one\n\nstep two\n```\n\n| Step | Owner |\n| --- | --- |\n| Tow | Dana |\n\nAfter the table.",
            decisions: ["Keep the barge contract", "Ship the Vexatron pilot"],
            actions: [
                ActionItem(owner: "Dana Marsh", text: "File the harbor permits"),
                ActionItem(owner: "", text: "  "),
                ActionItem(owner: "", text: "Book the tide window"),
            ],
            user: [
                ActionItem(owner: "Me", text: "Review the barge contract"),
                ActionItem(owner: "Me", text: "Call the harbor master"),
                ActionItem(owner: "Me", text: "   "),
            ])
        let done: Set<String> = [ActionItemKey.key(for: "Call the harbor master")]
        let doc = build(structured, done: done, expanded: true)
        let rendered = CorrectionAnchoring.renderedBlocks(of: structured)
        var byAnchor: [String: String] = [:]
        for block in rendered { byAnchor[notesDocAnchorID(block.id)] = block.text }
        let paneBlocks = doc.blocks.filter { !NotesDocument.isEdge($0.anchorID) }
        #expect(Set(paneBlocks.map(\.anchorID)) == Set(byAnchor.keys), "one pane block per rendered block, completed items open")
        for block in paneBlocks {
            #expect(block.blockText == byAnchor[block.anchorID], "\(block.anchorID)")
            #expect(block.rendered.map { doc.space.blocks[$0].text } == block.blockText, "\(block.anchorID)")
        }
        #expect(paneBlocks.contains { $0.table != nil })
        #expect(paneBlocks.contains { !$0.targetable })
    }
}

// MARK: - AC-1: capture

@MainActor
@Suite struct N7CaptureTests {

    static let twoSections = notes(
        summary: "Quoll Harbor signs in May.\n\nShip the Vexatron pilot to the harbor.",
        decisions: ["Keep the barge contract"],
        actions: [
            ActionItem(owner: "Dana Marsh", text: "File the harbor permits"),
            ActionItem(owner: "Harlan Voss", text: "Book the tide window"),
        ])

    @Test("AC-1: a drag across two paragraphs gives one piece per paragraph, joined by U+2029, anchored under the last")
    func twoParagraphs() throws {
        let doc = build(Self.twoSections)
        let captured = try #require(passage(doc.capture(range(doc, from: "signs in", to: "Vexatron"))))
        #expect(captured.pieces.map(\.text) == ["signs in May.", "Ship the Vexatron"])
        #expect(captured.quote == "signs in May." + sep + "Ship the Vexatron")
        #expect(captured.pieces.map(\.anchorID) == ["notes-summary-0", "notes-summary-1"])
        #expect(captured.sections == [.summary])
        #expect(doc.occurrence(of: captured) == 0)
        let target = NotesEditingEntry.target(
            .note, passage: captured, anchorBlockText: "Ship the Vexatron pilot to the harbor.", occurrence: 0)
        #expect(target.anchorID == "notes-summary-1")
        #expect(target.section == .summary)
        #expect(target.quotedText == captured.quote)
        #expect(target.displayQuote == "signs in May. \u{2026} Ship the Vexatron")
        #expect(!target.isWholeBlock)
    }

    @Test("AC-1: across sections — the anchor section is the last piece's; the sections are listed in order")
    func crossSection() throws {
        let doc = build(Self.twoSections)
        let captured = try #require(passage(doc.capture(range(doc, from: "to the harbor.", to: "Keep the barge"))))
        #expect(captured.pieces.map(\.text) == ["to the harbor.", "Keep the barge"])
        #expect(captured.sections == [.summary, .decision])
        #expect(captured.pieces.last?.anchorID == NotesBlockAnchor.decision(0))
    }

    @Test("AC-1: a drag ending on the next item's owner name gives no piece there — today's one-paragraph entry")
    func endingOnAnOwnerName() {
        let doc = build(Self.twoSections)
        let selection = range(doc, from: "harbor permits", to: "Harlan")
        let first = doc.block(NotesBlockAnchor.actionItem(0))!
        guard case .onePiece(let anchor, let local) = doc.capture(selection) else {
            Issue.record("expected one piece")
            return
        }
        #expect(anchor == first.anchorID)
        #expect((first.hostText as NSString).substring(with: local) == "harbor permits")
    }

    @Test("AC-1: the owner prefix is never part of a piece")
    func ownerPrefixExcluded() throws {
        let doc = build(Self.twoSections)
        let captured = try #require(passage(doc.capture(range(doc, from: "Dana Marsh", to: "Book the"))))
        #expect(captured.pieces.map(\.text) == ["File the harbor permits", "Book the"])
    }

    @Test("AC-1: sloppy drag — a wordless scrap is dropped at each end, one check per end, never grown")
    func sloppyDrag() throws {
        let doc = build(Self.twoSections)
        // "y." ends the first paragraph: no whole word, dropped; one piece.
        guard case .onePiece(let anchor, let local) = doc.capture(range(doc, from: "y.\n", to: "Ship the")) else {
            Issue.record("expected one piece")
            return
        }
        #expect(anchor == "notes-summary-1")
        #expect(local == NSRange(location: 0, length: 8), "the ORIGINAL range, never the whole paragraph")

        // A scrap at each end of three pieces: both dropped.
        let three = build(notes(summary: "Quoll Harbor signs in May.\n\nShip the pilot.\n\nThe barge waits."))
        guard case .onePiece(let middle, _) = three.capture(range(three, from: "y.\n", to: "Th")) else {
            Issue.record("expected one piece")
            return
        }
        #expect(middle == "notes-summary-1")

        // Two scraps: the first check drops the first; the last is then alone.
        guard case .onePiece(let last, _) = three.capture(range(three, from: "t.\nThe", to: "Th")) else {
            Issue.record("expected one piece")
            return
        }
        #expect(last == "notes-summary-2")

        // A piece holding one whole word is kept.
        let kept = try #require(passage(doc.capture(range(doc, from: "May.", to: "Ship"))))
        #expect(kept.pieces.map(\.text) == ["May.", "Ship"])
    }

    @Test("AC-1: a table, a divider and a completed action item give no piece; zero pieces give no AI actions")
    func objectsGiveNoPiece() throws {
        let tabled = build(notes(detailed: "Before the table.\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\n---\n\nAfter the table."))
        let captured = try #require(passage(tabled.capture(range(tabled, from: "the table.", to: "After"))))
        #expect(captured.pieces.map(\.text) == ["the table.", "After"])
        #expect(captured.pieces.map(\.anchorID) == ["notes-detailed-0", "notes-detailed-3"])

        let done: Set<String> = [ActionItemKey.key(for: "Call the harbor master")]
        let items = build(
            notes(
                decisions: ["Keep the barge contract"],
                user: [ActionItem(owner: "Me", text: "Review the barge contract"), ActionItem(owner: "Me", text: "Call the harbor master")]),
            done: done, expanded: true)
        let across = try #require(passage(items.capture(range(items, from: "the barge contract", to: "Keep the"))))
        #expect(across.pieces.map(\.anchorID) == [UserActionAnchor.id(0), NotesBlockAnchor.decision(0)])

        // Only placeholders and the completed item: nothing to act on.
        let text = items.text.string as NSString
        let completed = items.block(UserActionAnchor.id(1))!
        let decisionTitle = text.range(of: "Decisions")
        #expect(items.capture(NSRange(location: completed.range.location, length: NSMaxRange(decisionTitle) - completed.range.location)) == .none)
    }

    @Test("AC-1: a U+2029 inside a selected block is stored as a space; a piece across a link is its rendered text")
    func separatorAndLink() throws {
        let doc = build(notes(summary: "The kelp survey moved,\(sep)and the ferry waits.\n\nRead the [pilot brief](https://example.com/brief) today.\n\nThen sign."))
        let captured = try #require(passage(doc.capture(range(doc, from: "moved,", to: "Then"))))
        #expect(captured.pieces.map(\.text) == ["moved, and the ferry waits.", "Read the pilot brief today.", "Then"])
        #expect(!captured.pieces.contains { $0.text.unicodeScalars.contains("\u{2029}") })
        #expect(CorrectionAnchoring.pieces(captured.quote).count == 3)
    }

    @Test("AC-1: a whole-block entry on a paragraph holding U+2029 quotes it with a space")
    func wholeBlockWithSeparator() {
        let target = NotesEditingEntry.target(
            .note, section: .summary, anchorID: "notes-summary-0",
            blockText: "The kelp survey moved,\(sep)and the ferry waits.", occurrence: 0)
        #expect(target.quotedText == "The kelp survey moved, and the ferry waits.")
        let fallback = NotesEditingEntry.target(
            .note, section: .actionItem, anchorID: "notes-action-0",
            blockText: "File the\(sep)permits", occurrence: 0, selection: SelectedSpan(text: "Marsh: File"),
            hostText: "Dana Marsh: File the\(sep)permits")
        #expect(fallback.quotedText == "File the permits")
        #expect(fallback.isWholeBlock)
    }

    @Test("AC-1: the captured passage occurrence names the dragged copy, when its last piece repeats")
    func draggedCopyOccurrence() throws {
        let doc = build(notes(summary: "Ship the rig.\n\ntow it, tow it\n\nShip the rig.\n\ntow it"))
        // The second "Ship the rig." into the last "tow it".
        let text = doc.text.string as NSString
        let secondShip = text.range(of: "Ship the rig.", options: .backwards)
        let lastTow = text.range(of: "tow it", options: .backwards)
        let captured = try #require(
            passage(doc.capture(NSRange(location: secondShip.location, length: NSMaxRange(lastTow) - secondShip.location))))
        #expect(captured.pieces.map(\.anchorID) == ["notes-summary-2", "notes-summary-3"])
        #expect(
            CorrectionAnchoring.passageInstances(quote: captured.quote, section: .summary, in: doc.space).count == 3)
        #expect(doc.occurrence(of: captured) == 2)
    }
}

// MARK: - AC-4 / AC-5: placement, marks, tail, navigation

@MainActor
@Suite struct N7PanePlacementTests {

    static let structured = notes(
        summary: "Quoll Harbor signs in May.\n\nShip the Vexatron pilot to the harbor.",
        decisions: ["Keep the barge contract"],
        actions: [ActionItem(owner: "Dana Marsh", text: "File the harbor permits")])

    @Test("AC-4: a spanning note and a spanning pending correction stand under the anchor block; every piece is located; neither is in the tail; navigation goes to the first piece")
    func placementMarksTailNavigation() throws {
        let doc = build(Self.structured)
        let note = row("note", .annotation, .decision, "the harbor." + sep + "Keep the barge")
        let pending = row("fix", .understanding, .actionItem, "Keep the barge contract" + sep + "File the harbor")
        let (rows, pieces) = notesDocRows([note, pending], document: doc, structured: Self.structured)
        #expect(rows[NotesBlockAnchor.decision(0)]?.notes.map(\.id) == ["note"])
        #expect(rows[NotesBlockAnchor.actionItem(0)]?.pending.map(\.id) == ["fix"])
        #expect(rows.keys.count == 2, "nothing placed anywhere else")

        let notePieces = try #require(pieces["note"])
        #expect(notePieces.map(\.anchorID) == ["notes-summary-1", NotesBlockAnchor.decision(0)])
        let summary1 = doc.block("notes-summary-1")!
        #expect((summary1.hostText as NSString).substring(with: notePieces[0].local) == "the harbor.")
        // An action item's piece sits after its owner prefix in the host text.
        let item = doc.block(NotesBlockAnchor.actionItem(0))!
        let fixPieces = try #require(pieces["fix"])
        #expect((item.hostText as NSString).substring(with: fixPieces[1].local) == "File the harbor")

        #expect(notesDocUnanchored([note, pending], structured: Self.structured, space: doc.space).isEmpty)
        #expect(notesDocNavigationAnchor(note, space: doc.space) == "notes-summary-1")
        #expect(notesDocNavigationAnchor(pending, space: doc.space) == NotesBlockAnchor.decision(0))
    }

    @Test("AC-4: a passage that also matches one raw anchoring block is placed by the passage rule, not today's resolve")
    func noRawSpacePlacement() {
        // Two summary paragraphs are ONE raw anchoring block: today's resolve
        // would match the flattened quote and fall to the LAST paragraph.
        let structured = notes(summary: "Alpha one.\n\nBeta two.\n\nGamma three.")
        let doc = build(structured)
        let note = row("n", .annotation, .summary, "Alpha one." + sep + "Beta two.")
        let (rows, _) = notesDocRows([note], document: doc, structured: structured)
        #expect(rows["notes-summary-1"]?.notes.map(\.id) == ["n"])
        #expect(rows["notes-summary-2"] == nil)
    }

    @Test("AC-6: first piece gone from the whole document — the note goes to the tail with today's one-paragraph re-pin; the correction is placed nowhere")
    func fallback() {
        let structured = notes(summary: "Ship the Vexatron pilot to the harbor.", decisions: ["Keep the barge contract"])
        let doc = build(structured)
        let note = row("note", .annotation, .decision, "Quoll Harbor signs" + sep + "Keep the barge", status: .stale)
        let fix = row("fix", .understanding, .decision, "Quoll Harbor signs" + sep + "Keep the barge")
        let (rows, pieces) = notesDocRows([note, fix], document: doc, structured: structured)
        #expect(rows.isEmpty)
        #expect(pieces.isEmpty)
        #expect(notesDocUnanchored([note, fix], structured: structured, space: doc.space).map(\.id) == ["note"])
        // The re-pin writes one paragraph; a U+2029 in it becomes a space.
        let pin = notesDocPin(["Keep the barge\(sep)contract"], at: 0)
        #expect(pin?.quote == "Keep the barge contract")
        #expect(pin?.occurrence == 0)
    }

    @Test("AC-5: the card cites every piece; the composer and Changes show the pieces joined by ' … '")
    func presentation() {
        let note = row("note", .annotation, .decision, "the harbor." + sep + "Keep the barge")
        let model = NotesEditingPresentation.marginNotes([note])[0]
        #expect(model.showsQuote, "a spanning note always cites its passage")
        #expect(CorrectionAnchoring.pieces(model.quotedText) == ["the harbor.", "Keep the barge"])
        #expect(NotesEditingText.passage(note.quotedText) == "the harbor. \u{2026} Keep the barge")
        #expect(
            InlineNoteCard.accessibilityLabel(model, portuguese: false)
                == "Your note on \u{201C}the harbor. \u{2026} Keep the barge\u{201D}: Note note")
        // A one-paragraph first note still does not cite (today).
        #expect(!NotesEditingPresentation.marginNotes([row("one", .annotation, .decision, "Keep the barge")])[0].showsQuote)
    }
}

// MARK: - AC-8: the recovery boundary (placement half)

@MainActor
@Suite struct N7RecoveryBoundaryTests {

    static func items(_ texts: [String]) -> NotesStructured {
        notes(actions: texts.map { ActionItem(owner: "Dana Marsh", text: $0) })
    }

    @Test("AC-8 (a)/(b): [A, B, C, A, B] — the second A, B is captured as occurrence 1 and placed at the second B; rewriting that A keeps the placement and marks piece A on the first A")
    func recoveryBoundary() throws {
        let original = Self.items(["Alpha task", "Bravo task", "Charlie task", "Alpha task", "Bravo task"])
        let doc = build(original)
        let text = doc.text.string as NSString
        let secondAlpha = text.range(of: "Alpha task", options: .backwards)
        let secondBravo = text.range(of: "Bravo task", options: .backwards)
        let captured = try #require(
            passage(doc.capture(NSRange(location: secondAlpha.location, length: NSMaxRange(secondBravo) - secondAlpha.location))))
        let occurrence = doc.occurrence(of: captured)
        #expect(occurrence == 1)
        for kind in [MeetingCorrection.Kind.annotation, .understanding] {
            let stored = row("r", kind, .actionItem, captured.quote, occurrence: occurrence)
            let (rows, pieces) = notesDocRows([stored], document: doc, structured: original)
            let placed = kind == .annotation ? rows[NotesBlockAnchor.actionItem(4)]?.notes : rows[NotesBlockAnchor.actionItem(4)]?.pending
            #expect(placed?.map(\.id) == ["r"], "\(kind)")
            #expect(pieces["r"]?.map(\.anchorID) == [NotesBlockAnchor.actionItem(3), NotesBlockAnchor.actionItem(4)])

            // (b) The selected copy's A is rewritten: still at the second B;
            // piece A now resolves onto the first A (R3).
            let rewritten = Self.items(["Alpha task", "Bravo task", "Charlie task", "Delta task", "Bravo task"])
            let after = build(rewritten)
            let (rowsAfter, piecesAfter) = notesDocRows([stored], document: after, structured: rewritten)
            let placedAfter = kind == .annotation
                ? rowsAfter[NotesBlockAnchor.actionItem(4)]?.notes : rowsAfter[NotesBlockAnchor.actionItem(4)]?.pending
            #expect(placedAfter?.map(\.id) == ["r"], "\(kind)")
            #expect(piecesAfter["r"]?.map(\.anchorID) == [NotesBlockAnchor.actionItem(0), NotesBlockAnchor.actionItem(4)])
        }
    }
}

@MainActor
@Suite struct N7FoldPositionTests {
    static let hostile = [
        "e_\u{301} Ship", "Cafe\u{301} **bold** harbor", "a \u{301}b Quoll", "\u{130}stanbul Quoll Harbor",
        "\u{1F469}\u{200D}\u{1F4BB} Vexatron _\u{E9}_", "x*\u{301}*y tide", "`code`\u{301} buoy",
        "  leading  and   trailing  ", "\u{1F1E7}_\u{1F1F7} flags join", "## Heading [link](x) \u{1F44D}\u{1F3FD}",
        "Stra\u{DF}e \u{1F9D1}\u{200D}\u{1F91D}\u{200D}\u{1F9D1} crew", "",
    ]

    @Test("every Character lands on the folded Character its kept scalars end up in; the positions only climb")
    func positionsAgreeWithTheFold() {
        for text in Self.hostile {
            let folded = Array(CorrectionAnchoring.fold(text))
            let positions = CorrectionAnchoring.foldPositions(text)
            #expect(positions.count == text.count, "\(text.debugDescription)")
            var covered = Set<Int>()
            var last = -1
            for (character, position) in zip(text, positions) {
                guard let position else { continue }
                #expect(position >= last, "\(text.debugDescription) climbs")
                last = position
                covered.insert(position)
                let kept = Set(character.unicodeScalars.filter { !"*_`~[]()>#".unicodeScalars.contains($0) }
                    .flatMap { $0.properties.lowercaseMapping.unicodeScalars })
                #expect(
                    position < folded.count && !kept.isDisjoint(with: folded[position].unicodeScalars),
                    "\(text.debugDescription): \(character.debugDescription) at \(position)")
            }
            // Every folded Character but a joining space comes from the text.
            for (offset, character) in folded.enumerated() where character != " " {
                #expect(covered.contains(offset), "\(text.debugDescription): folded \(offset) has no source")
            }
        }
    }

    @Test("a piece's wash covers its words when the syntax before it lets a mark join a letter")
    func washAfterAJoinedMark() throws {
        let structured = notes(decisions: ["e_\u{301} Ship", "Quoll Harbor waits"])
        let doc = build(structured)
        let note = row("note", .annotation, .decision, "Ship" + sep + "Quoll Harbor waits")
        let (rows, pieces) = notesDocRows([note], document: doc, structured: structured)
        #expect(rows[NotesBlockAnchor.decision(1)]?.notes.map(\.id) == ["note"])
        let marks = try #require(pieces["note"])
        let first = try #require(doc.block(marks[0].anchorID))
        #expect(marks[0].anchorID == NotesBlockAnchor.decision(0))
        #expect((first.hostText as NSString).substring(with: marks[0].local) == "Ship")
        #expect((doc.block(marks[1].anchorID)!.hostText as NSString).substring(with: marks[1].local) == "Quoll Harbor waits")
    }
}

@MainActor
@Suite struct N7NavigationCompletedTests {
    @Test("AC-4: \"Go to this passage\" whose first piece is a done item opens Completed, where that block then is")
    func firstPieceOnACollapsedDoneItem() throws {
        let items = [
            ActionItem(owner: "Demo User", text: "Send the tide table to Quoll Harbor"),
            ActionItem(owner: "Demo User", text: "Book the jetty crane"),
        ]
        let structured = notes(decisions: ["Keep the barge contract"], user: items)
        let done: Set<String> = [ActionItemKey.key(for: items[0].text)]
        let collapsed = build(structured, done: done)
        let note = row("note", .annotation, .decision, "the tide table to Quoll Harbor" + sep + "Keep the barge")
        let anchor = try #require(notesDocNavigationAnchor(note, space: collapsed.space))
        #expect(anchor == UserActionAnchor.id(0), "the first piece's block (n7 §7)")
        // Collapsed, the block is not laid out: there is nothing to scroll to.
        #expect(collapsed.block(anchor) == nil)
        #expect(collapsed.hiddenInCompleted(anchor))
        // Opened, it is there.
        let expanded = build(structured, done: done, expanded: true)
        #expect(expanded.block(anchor) != nil)
        #expect(!expanded.hiddenInCompleted(anchor))
        // An open item, or a block of another section, never asks for it.
        #expect(!collapsed.hiddenInCompleted(UserActionAnchor.id(1)))
        #expect(!collapsed.hiddenInCompleted(NotesBlockAnchor.decision(0)))
    }
}
