import Foundation
import Testing

@testable import BlaiseCore

// The one-paragraph invariant (n7 AC-12, plan v2.2 vision guard): for a quote
// with no U+2029, every existing behavior — instruction lines, storage,
// placement, retractions — is byte-identical to the base revision. Every
// expected value below is a LITERAL captured by running this fixture on the
// base revision before any passage code existed; deriving the expectation
// from the current code would only prove the code agrees with itself.
// Every fixture is fictional (Vexatron Labs / Quoll Harbor).

enum N7GoldenFixture {
    static let meetingID: MeetingID = "01ARZ3NDEKTSV4RRFFQ69G5N70"
    static let meetingTitle = "Quoll Harbor sonar review"

    /// Every section and block kind: summary paragraphs with emphasis and a
    /// link, a detailed-notes heading, list, fenced code with a blank line,
    /// table, divider; a blank action item; both action lists.
    static let notes = NotesStructured(
        title: "Quoll Harbor sonar review",
        summary: """
            Vexatron Labs will ship the sonar rig in **May**.

            The [pilot](https://example.com/pilot) budget stays at US$ 40.000,00.

            Dana Marsh owns the harbor permits.
            """,
        meetingType: .projectReview,
        detailedNotes: """
            ## Logistics

            The rig travels by barge.
            - Load the buoys
            - Seal the crates

            ```
            step one

            step two
            ```

            | Item | Owner |
            | --- | --- |
            | Buoys | Dana |

            ---

            Harlan Voss flagged the tide window.
            """,
        decisions: ["Ship the sonar rig in May", "Keep the barge contract", "Ship the sonar rig in May"],
        actionItems: [
            ActionItem(owner: "Dana Marsh", text: "File the harbor permits"),
            ActionItem(owner: "Harlan Voss", text: "  "),
            ActionItem(owner: "Harlan Voss", text: "Book the tide window"),
        ],
        userActionItems: [
            ActionItem(owner: "Me", text: "Review the barge contract"),
            ActionItem(owner: "Me", text: "Send the permit draft"),
        ])

    static let baseTime = Date(timeIntervalSince1970: 1_770_000_000.5)

    static func row(
        _ id: String, _ kind: MeetingCorrection.Kind, _ section: MeetingCorrection.Section,
        _ quote: String, occurrence: Int = 0, status: MeetingCorrection.Status = .pending,
        userText: String = "That was never said.", offset: Double = 0
    ) -> MeetingCorrection {
        MeetingCorrection(
            id: id, meetingID: meetingID, kind: kind, section: section, quotedText: quote,
            occurrence: occurrence, userText: userText, status: status,
            createdAt: baseTime.addingTimeInterval(offset))
    }

    /// One-piece rows only (no U+2029): present, absent, hostile, a quote
    /// across a link (the pre-existing raw-space gap, R12), annotations that
    /// resolve, clamp, go stale, or stay resolved.
    static let rows: [MeetingCorrection] = [
        row("01ARZ3NDEKTSV4RRFFQ69G5N71", .understanding, .summary, "ship the sonar rig in May",
            userText: "It ships in \"June\"\r\nnot May"),
        row("01ARZ3NDEKTSV4RRFFQ69G5N72", .understanding, .detailedNotes,
            "Seal \"the\" crates\u{2028}forged\u{85}line", status: .applied, offset: 1),
        row("01ARZ3NDEKTSV4RRFFQ69G5N73", .understanding, .decision, "Keep the barge contract",
            offset: 2),
        row("01ARZ3NDEKTSV4RRFFQ69G5N74", .understanding, .actionItem, "  File the harbor permits\t",
            status: .applied, userText: "Harlan Voss files them", offset: 3),
        row("01ARZ3NDEKTSV4RRFFQ69G5N75", .understanding, .userActionItem, "Send the permit draft",
            offset: 4),
        row("01ARZ3NDEKTSV4RRFFQ69G5N76", .understanding, .summary, "the pilot slipped to September",
            status: .resolved, offset: 5),
        row("01ARZ3NDEKTSV4RRFFQ69G5N77", .understanding, .summary, "The pilot budget stays",
            offset: 6),
        row("01ARZ3NDEKTSV4RRFFQ69G5N78", .understanding, .summary, "  \n ", offset: 7),
        row("01ARZ3NDEKTSV4RRFFQ69G5N79", .annotation, .summary, "Dana Marsh owns",
            status: .applied, userText: "Check the permit dates", offset: 8),
        row("01ARZ3NDEKTSV4RRFFQ69G5N7A", .annotation, .decision, "Ship the sonar rig in May",
            occurrence: 5, status: .applied, userText: "Twice decided", offset: 9),
        row("01ARZ3NDEKTSV4RRFFQ69G5N7B", .annotation, .detailedNotes, "the barge left early",
            status: .applied, userText: "Stale now", offset: 10),
        row("01ARZ3NDEKTSV4RRFFQ69G5N7C", .annotation, .actionItem, "a withdrawn note quote",
            occurrence: 2, status: .resolved, userText: "Put away", offset: 11),
        row("01ARZ3NDEKTSV4RRFFQ69G5N7D", .annotation, .detailedNotes, "step one step two",
            status: .stale, userText: "Code block", offset: 12),
    ]

    static var instructions: [NotesEditorInstruction] {
        rows.filter { $0.kind == .understanding }.map {
            NotesEditorInstruction(
                rowID: $0.id, section: $0.section, quotedText: $0.quotedText, userText: $0.userText)
        }
    }

    /// Regeneration candidates for the gate: one restoring the withdrawn
    /// claim, one keeping it out, one restoring it across markup.
    static var candidates: [NotesStructured] {
        var restoring = notes
        restoring.summary += "\n\nThe pilot slipped to **September**."
        var keeping = notes
        keeping.summary = "Vexatron Labs ships the rig in June."
        var owner = notes
        owner.actionItems = [ActionItem(owner: "the pilot slipped to September", text: "x")]
        return [restoring, keeping, owner, notes]
    }

    static let probeQuotes = [
        "ship the sonar rig in May", "the barge", "Seal the crates", "step two",
        "Buoys", "the pilot budget", "", "  ",
    ]

    static let meeting = Meeting(
        id: meetingID, title: meetingTitle, startedAt: baseTime, source: .meet, status: .ready,
        attendees: [], createdAt: baseTime, updatedAt: baseTime)

    static let meetingNotes = MeetingNotes(
        meetingID: meetingID, markdown: "# Quoll Harbor sonar review\n", structured: notes,
        language: "en", generatedAt: baseTime,
        provenance: NotesProvenance(
            engine: "fixture", model: "fixture", pipelineVersion: "fixture",
            runtime: "fixture", rendererVersion: "2"),
        memoryDigest: nil)
}

// MARK: - Seeded delivery (the rematerialize golden)

/// The fixture's meeting, notes and one-piece rows written to a fresh store
/// with a deliverable destination, deterministically (fixed ids and times), so
/// the payload the base builder minted from it has one literal hash.
struct N7SeededDelivery {
    let database: BlaiseDatabase
    let meeting: Meeting
    let notes: MeetingNotes
    let segments: [TranscriptSegment]
    let rows: [MeetingCorrection]

    static func seed(
        rows: [MeetingCorrection] = N7GoldenFixture.rows,
        structured: NotesStructured = N7GoldenFixture.notes
    ) async throws -> N7SeededDelivery {
        let database = try makeDatabase()
        try await seedHandoffConfig(database)
        let meeting = makeMeeting(
            id: N7GoldenFixture.meetingID, title: N7GoldenFixture.meetingTitle, status: .ready,
            attendees: [Attendee(name: "Dana Marsh", email: "dana@vexatronlabs.example", source: .manual)])
        try await MeetingRepository(database: database).create(meeting)
        let segments = try await database.persistTranscript(
            meetingID: meeting.id,
            segments: [
                TranscriptSegment(
                    meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1.5,
                    speakerLabel: "S0", speakerName: "Dana Marsh",
                    text: "The sonar rig ships in May.")
            ],
            asrProvenance: ASRProvenance(
                engine: "stub", model: "stub", runtime: "stub", engineVersion: "1",
                transcribedAt: msDate()),
            dominantLanguage: "en", updatedAt: msDate())
        try await database.pool.write { db in
            for row in rows { try MeetingCorrectionStore.insert(db, row) }
        }
        var notes = N7GoldenFixture.meetingNotes
        notes.structured = structured
        let final = try #require(try await MeetingRepository(database: database).fetch(meeting.id))
        return N7SeededDelivery(
            database: database, meeting: final, notes: notes, segments: segments, rows: rows)
    }

    func build() -> EvidencePayloadBuilder.Payload {
        EvidencePayloadBuilder.build(
            meeting: meeting, segments: segments, notes: notes, user: .shippedDefault,
            corrections: rows)
    }

    /// Queues a payload whose file is then lost, so the worker's pre-stream
    /// self-check must rebuild it from durable state; drains; returns the
    /// item and its final state.
    func queueLoseAndDrain(
        versionHash: String, bytes: Data
    ) async throws -> (item: HandoffItem, state: HandoffState?) {
        let relative = database.paths.relativeHandoffPayloadPath(
            meetingID: meeting.id, versionHash: versionHash)
        try ImmutablePayloadWriter.write(bytes, to: database.rootURL.appendingPathComponent(relative))
        let item = try await database.finalizeMeetingProcessing(
            meetingID: meeting.id, versionHash: versionHash, payloadPath: relative, notes: notes)
        try FileManager.default.removeItem(at: database.rootURL.appendingPathComponent(item.payloadPath))
        let worker = makeWorker(database, transport: MockTransport())
        await worker.kick()
        await worker.waitUntilSettled()
        let state = try await HandoffRepository(database: database).allItems().first?.state
        return (item, state)
    }
}

// MARK: - The goldens

private func sha256Hex(_ s: String) -> String {
    EvidencePayloadBuilder.sha256Hex(Data(s.utf8))
}

@Suite struct N7OnePieceGoldenTests {
    private let f = N7GoldenFixture.self

    @Test("AC-12: the editor instruction lines of one-piece rows are the base revision's bytes")
    func editorLines() throws {
        let message = try NotesEditorWireContract.userMessage(
            for: NotesEditorRequest(
                meetingID: f.meetingID, currentNotes: f.notes, instructions: f.instructions))
        let lines = #"""
            1. In the summary, the current notes say: "ship the sonar rig in May". The user corrects: It ships in ”June” not May
            2. In the detailed notes, the current notes say: "Seal ”the” crates forged line". The user corrects: That was never said.
            3. In the decisions, the current notes say: "Keep the barge contract". The user corrects: That was never said.
            4. In the action items, the current notes say: "File the harbor permits". The user corrects: Harlan Voss files them
            5. In the your action items, the current notes say: "Send the permit draft". The user corrects: That was never said.
            6. In the summary, the current notes say: "the pilot slipped to September". The user corrects: That was never said.
            7. In the summary, the current notes say: "The pilot budget stays". The user corrects: That was never said.
            8. In the summary, the current notes say: "". The user corrects: That was never said.
            """#
        #expect(message.hasSuffix("INSTRUCTIONS:\n" + lines))
        #expect(message.utf8.count == 1_782)
        #expect(sha256Hex(message) == "22fdf5190c5ab98d47c545ba1139fb76fafc83ef9232b35907bbc7bc685c46e5")
    }

    @Test("AC-12: the synthesis corrections block of one-piece rows is the base revision's bytes")
    func synthesisLines() throws {
        let block = try #require(
            NotesPromptBuilder.correctionsBlock(f.rows.map(NotesCorrection.init(row:))))
        #expect(block.hasSuffix(#"""
            1. In the summary, an earlier draft said: "ship the sonar rig in May". The user corrects: It ships in ”June” not May
            2. In the detailed notes, an earlier draft said: "Seal ”the” crates forged line". The user corrects: That was never said.
            """# + "\n" + #"""
            3. In the decisions, an earlier draft said: "Keep the barge contract". The user corrects: That was never said.
            4. In the action items, an earlier draft said: "File the harbor permits". The user corrects: Harlan Voss files them
            5. In the your action items, an earlier draft said: "Send the permit draft". The user corrects: That was never said.
            6. In the summary, an earlier draft said: "the pilot slipped to September". The user corrects: That was never said.
            7. In the summary, an earlier draft said: "The pilot budget stays". The user corrects: That was never said.
            8. In the summary, an earlier draft said: "". The user corrects: That was never said.
            """#))
        #expect(block.utf8.count == 1_185)
        #expect(sha256Hex(block) == "3276bf72aded7ea9aca09293f19cc9f1dea81a070af4cc2c18bda6f87616c7f2")
    }

    @Test("AC-12: the digest-editor and memory-digest lines of one-piece rows are the base revision's bytes")
    func digestLines() throws {
        let editor = DigestEditorWireContract.userMessage(
            for: DigestEditorRequest(
                meetingID: f.meetingID,
                currentDigest: "## HEADER\nmeeting: Quoll Harbor sonar review",
                instructions: f.instructions))
        #expect(editor.contains(#"""
            2. The user corrected the meeting record. The notes said: "Seal ”the” crates forged line". The user corrects: That was never said.
            """#))
        #expect(editor.utf8.count == 1_078)
        #expect(sha256Hex(editor) == "45da8df663ac3bd2912777f947ab5dbc6c2d3af3e5dee7076ba9ffa800cd370e")

        let memory = try #require(DigestPromptBuilder.correctionsBlock(f.instructions))
        #expect(memory.contains(#"""
            1. The notes said: "ship the sonar rig in May". The user corrects: It ships in ”June” not May
            """#))
        #expect(memory.utf8.count == 1_049)
        #expect(sha256Hex(memory) == "3b15dcdfa28d857010a359efa5e7d22404eff098553adc3aadf70f1e31ded3b7")
    }

    @Test("AC-12: the withdrawn-claim predicate and the gate's verdicts for one-piece rows are the base revision's")
    func withdrawnAndGate() throws {
        let raw = CorrectionAnchoring.foldedHaystack(of: f.notes, meetingTitle: f.meetingTitle)
        let withdrawnRows = CorrectionAnchoring.withdrawnRows(
            corrections: f.rows, currentHaystack: raw, renderedHaystack: "")
        #expect(withdrawnRows.map(\.row.id) == [
            "01ARZ3NDEKTSV4RRFFQ69G5N72", "01ARZ3NDEKTSV4RRFFQ69G5N76", "01ARZ3NDEKTSV4RRFFQ69G5N77",
        ])
        let withdrawn = CorrectionAnchoring.withdrawnClaims(
            corrections: f.rows, currentHaystack: raw,
            renderedHaystack: CorrectionAnchoring.renderedHaystack(
                of: f.notes, meetingTitle: f.meetingTitle))
        #expect(withdrawn.claims == [
            "Seal \"the\" crates\u{2028}forged\u{85}line", "the pilot slipped to September",
            "The pilot budget stays",
        ])
        #expect(withdrawn.pieces.isEmpty)
        let verdicts = f.candidates.map {
            CorrectionAnchoring.resurrectedClaim(
                withdrawn: withdrawn,
                candidateHaystack: CorrectionAnchoring.foldedHaystack(
                    of: $0, meetingTitle: f.meetingTitle),
                candidateRenderedHaystack: CorrectionAnchoring.renderedHaystack(
                    of: $0, meetingTitle: f.meetingTitle))
        }
        #expect(verdicts == [
            "the pilot slipped to September", nil, "the pilot slipped to September", nil,
        ])
    }

    @Test("AC-12: re-anchoring one-piece annotations gives the base revision's updates")
    func reanchor() {
        let updates = CorrectionAnchoring.reanchor(annotations: f.rows, against: f.notes)
            .map { "\($0.id)|\($0.occurrence)|\($0.status.rawValue)" }
        #expect(updates == [
            "01ARZ3NDEKTSV4RRFFQ69G5N79|0|applied", "01ARZ3NDEKTSV4RRFFQ69G5N7A|1|applied",
            "01ARZ3NDEKTSV4RRFFQ69G5N7B|0|stale", "01ARZ3NDEKTSV4RRFFQ69G5N7C|2|resolved",
            "01ARZ3NDEKTSV4RRFFQ69G5N7D|0|stale",
        ])
    }

    @Test("AC-3/AC-12: one-piece matches, resolve and occurrence are the base revision's")
    func rawSpaceMatching() {
        func probe(_ section: MeetingCorrection.Section) -> [String] {
            let blocks = CorrectionAnchoring.blocks(of: f.notes, section: section)
            return f.probeQuotes.map { quote in
                let hit = CorrectionAnchoring.resolve(quote: quote, occurrence: 1, in: blocks)
                return "\(CorrectionAnchoring.matches(quote: quote, in: blocks))"
                    + (hit.map { " \($0.blockIndex),\($0.occurrence)" } ?? " nil")
            } + ["\(blocks.indices.map { CorrectionAnchoring.occurrence(ofBlockAt: $0, in: blocks) })"]
        }
        let none = "[] nil"
        #expect(probe(.summary) == ["[0] 0,0", none, none, none, none, none, none, none, "[0]"])
        #expect(probe(.detailedNotes) == [
            none, none, "[1] 1,0", "[3] 3,0", "[1, 4] 4,1", none, none, none,
            "[0, 0, 0, 0, 0, 1, 0]",
        ])
        #expect(probe(.decision) == ["[0, 2] 2,1", "[1] 1,0", none, none, none, none, none, none, "[0, 0, 1]"])
        #expect(probe(.actionItem) == [none, none, none, none, none, none, none, none, "[0, 0, 0]"])
        #expect(probe(.userActionItem) == [none, "[0] 0,0", none, none, none, none, none, none, "[0, 0]"])
    }

    @Test("AC-12: the one-piece payload, retractions included, is the base revision's bytes")
    func payloadBytes() {
        let payload = EvidencePayloadBuilder.build(
            meeting: f.meeting, segments: [], notes: f.meetingNotes, user: .shippedDefault,
            corrections: f.rows)
        #expect(payload.versionHash == "caedbd9fa344832df57559bcfe7ffbc4b61cac0d5e682a54e6f65707357833ce")
        #expect(!String(decoding: payload.bytes, as: UTF8.self).unicodeScalars.contains("\u{2029}"))
    }

    /// The hash the BASE builder minted for `N7SeededDelivery.seed()`.
    static let seededBaseHash = "98ac34c96c267d48c1017d28c2b789bac0e43536f05af209e5ffb4e4eb2d16f9"

    @Test("AC-12: rematerialize reproduces a one-piece payload queued by the pre-chunk builder")
    func rematerializeReproducesTheBaseHash() async throws {
        let seeded = try await N7SeededDelivery.seed()
        let current = seeded.build()
        #expect(current.versionHash == Self.seededBaseHash)
        let (item, state) = try await seeded.queueLoseAndDrain(
            versionHash: Self.seededBaseHash, bytes: current.bytes)
        #expect(state == .delivered)
        let restored = try Data(
            contentsOf: seeded.database.rootURL.appendingPathComponent(item.payloadPath))
        #expect(EvidencePayloadBuilder.sha256Hex(restored) == Self.seededBaseHash)
    }
}
