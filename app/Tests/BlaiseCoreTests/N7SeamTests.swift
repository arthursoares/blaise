import Foundation
import Testing

@testable import BlaiseCore

// n7 stage 2 — the BlaiseCore seams marked "passage rule" in n7 §3's
// inventory, each driven with one spanning fixture: the re-anchor callers
// (add / rename / speaker rename / name fix / re-synthesis), the reopen, and
// the markdown weave. Every fixture is fictional (Vexatron Labs / Quoll
// Harbor).

private let sep = "\u{2029}"

private let twoParagraphs = "Quoll Harbor signs in May.\n\nShip the Vexatron pilot to the harbor."
private let spanningQuote = "Quoll Harbor signs in May." + sep + "Ship the Vexatron pilot"

private func liveRow(
    _ harness: PipelineHarness, _ meetingID: MeetingID, _ id: String
) async throws -> MeetingCorrection {
    try #require(
        try await harness.database.pool.read { db in
            try MeetingCorrectionStore.all(db, meetingID: meetingID).first { $0.id == id }
        })
}

private func markdown(_ harness: PipelineHarness, _ meetingID: MeetingID) async throws -> String {
    try #require(try await NotesRepository(database: harness.database).fetch(meetingID: meetingID)).markdown
}

/// The position of `needle` in `text`, for ordering assertions.
private func at(_ needle: String, in text: String) throws -> String.Index {
    try #require(text.range(of: needle)?.lowerBound, "missing \(needle)")
}

@Suite struct N7PipelineSeamTests {

    @Test("AC-4: a spanning note stays applied through add, rename, speaker rename, name fix, reopen and re-synthesis; its aside ends the summary")
    func spanningNoteThroughEveryReanchorCaller() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.summary = twoParagraphs }
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)

        // G-C10: the add path re-mints and re-anchors by the passage rule.
        let added = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .annotation, section: .summary,
            quotedText: spanningQuote, occurrence: 0, userText: "Check the tide tables.")
        #expect(added.row.quotedText == spanningQuote, "the joiner survives the end-trim")
        #expect(try await liveRow(harness, meeting.id, added.row.id).status == .applied)
        func asideEndsTheSummary() async throws {
            let text = try await markdown(harness, meeting.id)
            let aside = try at("> **Sua nota:** Check the tide tables.", in: text)
            #expect(try at("Ship the Vexatron pilot to the harbor.", in: text) < aside)
            #expect(aside < (try at("## Notas detalhadas", in: text)))
            #expect(!text.contains("## Suas notas"), "never in the tail while it resolves")
        }
        try await asideEndsTheSummary()

        // G-C1: a meeting rename.
        #expect(try await harness.pipeline.renameMeeting(meetingID: meeting.id, to: "Quoll Harbor review"))
        #expect(try await liveRow(harness, meeting.id, added.row.id).status == .applied)
        try await asideEndsTheSummary()

        // G-C2: a speaker rename.
        _ = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "S1", to: "Dana Marsh")
        #expect(try await liveRow(harness, meeting.id, added.row.id).status == .applied)
        try await asideEndsTheSummary()

        // G-C3/G-C4: the name fix rewrites each piece in place; the joiner
        // stays and the rewritten passage still resolves.
        #expect(
            try await harness.pipeline.correctNameInNotes(
                meetingID: meeting.id, original: "Quoll", replacement: "Kestrel",
                allOccurrences: true) >= 1)
        let renamed = try await liveRow(harness, meeting.id, added.row.id)
        #expect(renamed.quotedText == "Kestrel Harbor signs in May." + sep + "Ship the Vexatron pilot")
        #expect(renamed.status == .applied)

        // G-C6: resolve, then reopen against the current notes.
        let current = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        try await harness.pipeline.setCorrectionResolved(
            meetingID: meeting.id, id: added.row.id, resolved: true, structuredNotes: current.structured)
        try await harness.pipeline.setCorrectionResolved(
            meetingID: meeting.id, id: added.row.id, resolved: false, structuredNotes: current.structured)
        #expect(try await liveRow(harness, meeting.id, added.row.id).status == .applied)

        // G-C14 (and C12): a re-synthesis that keeps both paragraphs.
        harness.notesPrimary.state.withLock {
            $0.summary = "Kestrel Harbor signs in May.\n\nShip the Vexatron pilot to the harbor."
        }
        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        #expect(try await liveRow(harness, meeting.id, added.row.id).status == .applied)
        try await asideEndsTheSummary()

        // A re-synthesis that drops the first piece's words from the whole
        // document: stale, in the tail; a reopen agrees.
        harness.notesPrimary.state.withLock { $0.summary = "Ship the Vexatron pilot to the harbor." }
        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        #expect(try await liveRow(harness, meeting.id, added.row.id).status == .stale)
        let orphaned = try await markdown(harness, meeting.id)
        #expect(orphaned.contains("## Suas notas"))
        #expect(!orphaned.contains("> **Sua nota:** Check the tide tables."))
        let dropped = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        try await harness.pipeline.setCorrectionResolved(
            meetingID: meeting.id, id: added.row.id, resolved: true, structuredNotes: dropped.structured)
        try await harness.pipeline.setCorrectionResolved(
            meetingID: meeting.id, id: added.row.id, resolved: false, structuredNotes: dropped.structured)
        #expect(try await liveRow(harness, meeting.id, added.row.id).status == .stale)
    }

    @Test("AC-4: the reopen reads the passage rule — a raw-space resolve would call this passage stale")
    func reopenUsesThePassageRule() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.summary = twoParagraphs }
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        // Summary into the decisions: no single raw block holds both pieces.
        let quote = "Ship the Vexatron pilot to the harbor." + sep + "manda o contrato"
        let added = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .annotation, section: .decision,
            quotedText: quote, occurrence: 0, userText: "Confirm the courier.")
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(
            CorrectionAnchoring.resolve(
                quote: quote, occurrence: 0,
                in: CorrectionAnchoring.blocks(of: notes.structured, section: .decision)) == nil)
        try await harness.pipeline.setCorrectionResolved(
            meetingID: meeting.id, id: added.row.id, resolved: true, structuredNotes: notes.structured)
        try await harness.pipeline.setCorrectionResolved(
            meetingID: meeting.id, id: added.row.id, resolved: false, structuredNotes: notes.structured)
        #expect(try await liveRow(harness, meeting.id, added.row.id).status == .applied)
    }
}

// MARK: - The markdown weave (G-F1; AC-7's delivered half)

@Suite struct N7WeaveTests {

    private static func note(
        _ quote: String, _ section: MeetingCorrection.Section, occurrence: Int = 0, _ text: String
    ) -> MeetingCorrection {
        MeetingCorrection(
            id: "row-\(text.count)", meetingID: N7GoldenFixture.meetingID, kind: .annotation,
            section: section, quotedText: quote, occurrence: occurrence, userText: text,
            status: .applied, createdAt: N7GoldenFixture.baseTime)
    }

    private static let structured = NotesStructured(
        title: "Quoll Harbor sonar review",
        summary: "Quoll Harbor signs in May.\n\nThe barge leaves at dawn.\n\nThe crew is ready.",
        detailedNotes: "First detail here.\n\nSecond detail there.\n\nThird paragraph closes it.",
        decisions: ["Keep the barge contract", "Ship the Vexatron pilot"],
        actionItems: [
            ActionItem(owner: "Dana Marsh", text: "File the harbor permits"),
            ActionItem(owner: "Harlan Voss", text: "Book the tide window"),
        ],
        userActionItems: [])

    private static func render(_ rows: [MeetingCorrection]) throws -> String {
        try NotesRenderer.render(structured, language: "en", meetingTitle: "Quoll Harbor", annotations: rows)
    }

    @Test("AC-7: a detailed-notes anchor followed by another paragraph — the aside comes after the last paragraph, quoting the pieces")
    func detailedAsideAfterTheWholeSection() throws {
        let text = try Self.render([
            Self.note("detail here." + sep + "Second detail", .detailedNotes, "Recheck the depth.")
        ])
        let aside = try at(
            "> **Your note** (on \u{201C}detail here. \u{2026} Second detail\u{201D}): Recheck the depth.", in: text)
        #expect(try at("Third paragraph closes it.", in: text) < aside)
        #expect(aside < (try at("## Decisions", in: text)))
        #expect(!text.contains("## Your notes"))
    }

    @Test("AC-7: summary, list and cross-section anchors land at the end of the anchor block's section; a list aside quotes the anchor block")
    func summaryAndListAsides() throws {
        let text = try Self.render([
            Self.note("signs in May." + sep + "The barge leaves", .summary, "Tide first."),
            Self.note("The crew is ready." + sep + "Keep the barge", .decision, "Cross into decisions."),
            Self.note("File the harbor permits" + sep + "Book the tide", .actionItem, "Both by Friday."),
        ])
        let summaryAside = try at("> **Your note:** Tide first.", in: text)
        #expect(try at("The crew is ready.", in: text) < summaryAside)
        #expect(summaryAside < (try at("## Detailed notes", in: text)))

        let decisionAside = try at(
            "> **Your note** (on \u{201C}Keep the barge contract\u{201D}): Cross into decisions.", in: text)
        #expect(try at("- Ship the Vexatron pilot", in: text) < decisionAside)
        #expect(decisionAside < (try at("## Action items", in: text)))

        let actionAside = try at(
            "> **Your note** (on \u{201C}Book the tide window\u{201D}): Both by Friday.", in: text)
        #expect(try at("Book the tide window", in: text) < actionAside)
        #expect(!text.contains("## Your notes"))
    }

    @Test("AC-7: an unresolved passage goes to the tail, flattened and cut as today (R5)")
    func unresolvedPassageInTheTail() throws {
        let text = try Self.render([Self.note("words gone" + sep + "Second detail", .detailedNotes, "Lost.")])
        #expect(text.contains("## Your notes\n\n- Lost. *(on \u{201C}words gone Second detail\u{201D})*"))
    }

    @Test("AC-7: the fenced detailed path appends the passage aside after the blob too")
    func fencedDetailedPath() throws {
        var notes = Self.structured
        notes.detailedNotes = "```\nstep one\n\nstep two\n```\n\nAfter the code."
        let row = Self.note("step one\n\nstep two" + sep + "After the", .detailedNotes, "Order holds.")
        let text = try NotesRenderer.render(notes, language: "en", meetingTitle: "Quoll Harbor", annotations: [row])
        let aside = try at(
            "> **Your note** (on \u{201C}step one  step two \u{2026} After the\u{201D}): Order holds.", in: text)
        #expect(try at("After the code.", in: text) < aside)
    }
}

// MARK: - AC-2: storage round-trip

@Suite struct N7StorageTests {

    private func stored(_ harness: PipelineHarness, _ meetingID: MeetingID, _ id: String) async throws -> MeetingCorrection {
        try #require(
            try await harness.database.pool.read { db in
                try MeetingCorrectionStore.all(db, meetingID: meetingID).first { $0.id == id }
            })
    }

    @Test("AC-2: addCorrection stores the joined quote, the anchor section and the passage occurrence byte-exact; a one-piece capture stores today's bytes")
    func roundTrip() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.summary = twoParagraphs }
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)

        let joined = "signs in May." + sep + "Ship the Vexatron pilot"
        let passage = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .decision,
            quotedText: joined, occurrence: 2, userText: "It slipped.")
        let reloaded = try await stored(harness, meeting.id, passage.row.id)
        #expect(Array(reloaded.quotedText.utf8) == Array(joined.utf8))
        #expect(reloaded.section == .decision)
        #expect(reloaded.occurrence == 2)

        // The one-piece golden's capture ("signs in", occurrence 3 of its
        // block) stores exactly those bytes, as before n7.
        let one = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .annotation, section: .summary,
            quotedText: "signs in", occurrence: 3, userText: "Confirm.")
        let onePiece = try await stored(harness, meeting.id, one.row.id)
        #expect(Array(onePiece.quotedText.utf8) == Array("signs in".utf8))
        #expect(onePiece.section == .summary)
        #expect(onePiece.occurrence == 0, "re-anchored on the add path, as today")
    }
}

// MARK: - Round-1 piggybacks: L-1-001 and L-1-002

@Suite struct N7PiggybackTests {

    @Test("L-1-002: an earlier piece takes its LAST occurrence before the next piece — in the block, and in a walked-to block")
    func lastOccurrenceRule() {
        let inBlock = CorrectionAnchoring.RenderedSpace(
            NotesStructured(title: "Quoll", summary: "beta alpha beta gamma", detailedNotes: "", decisions: [], actionItems: [], userActionItems: []))
        let one = CorrectionAnchoring.passageInstances(quote: "beta" + sep + "gamma", section: .summary, in: inBlock)
        #expect(one.map { $0.placements.map { $0?.range } } == [[11 ..< 15, 16 ..< 21]])

        let walked = CorrectionAnchoring.RenderedSpace(
            NotesStructured(
                title: "Quoll", summary: "beta harbor beta pier\n\ngamma", detailedNotes: "", decisions: [],
                actionItems: [], userActionItems: []))
        let two = CorrectionAnchoring.passageInstances(quote: "beta" + sep + "gamma", section: .summary, in: walked)
        #expect(two.map { $0.placements.map { $0.map { [$0.block, $0.range.lowerBound] } } } == [[[0, 12], [1, 0]]])
    }

    @Test("L-1-001: a regeneration restoring a withdrawn passage piece that holds a link is withheld (the gate searches the rendered notes)")
    func linkPieceRestorationWithheld() async throws {
        let linked = "Read the [pilot brief](https://example.com/brief) today."
        let pieceA = "Read the pilot brief today."
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.summary = "\(linked)\n\nThe barge is ready." }
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let row = MeetingCorrection(
            meetingID: meeting.id, kind: .understanding, section: .decision,
            quotedText: pieceA + sep + "Fábio manda o contrato",
            userText: "The brief was withdrawn.", status: .applied, createdAt: msDate())
        try await harness.database.pool.write { db in try MeetingCorrectionStore.insert(db, row) }

        harness.notesPrimary.state.withLock { $0.summary = "The harbor date is open." }
        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        let summaryAfterRemoval = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id)).structured.summary
        #expect(summaryAfterRemoval == "The harbor date is open.")

        // The link comes back: its rendered text is piece A; the raw fold
        // keeps the URL and would not match.
        let restored = "Signed. \(linked)"
        #expect(
            !CorrectionAnchoring.fold(restored).contains(CorrectionAnchoring.fold(pieceA)),
            "the raw haystack would miss it")
        harness.notesPrimary.state.withLock { $0.summary = restored }
        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        let kept = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id)).structured.summary
        #expect(kept == "The harbor date is open.")
        #expect(try await harness.meeting(meeting.id)?.processingNote == ProcessingPipeline.resurrectedClaimNote)
    }
}
