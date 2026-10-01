import Foundation
import GRDB
import Testing

@testable import BlaiseCore
@testable import BlaiseMCPServer

/// Fixture text with quotes, a newline and non-BMP emoji, so JSON escaping
/// and surrogate pairs count toward every measured length.
private func filler(_ index: Int, length: Int) -> String {
    var text = "line \(index) — \"Quoll Harbor\" cue\n🚀 the Vexatron slot moves 🌊 "
    while text.count < length { text += "tide \\ \"quote\" 🐚 " }
    return String(text.prefix(length))
}

private func lineIndex(_ line: String) -> Int? {
    line.firstMatch(of: #/line ([0-9]+) /#).flatMap { Int($0.1) }
}

private let tidewatch = "Tidewatch — prototype review"
private let aurora = "Aurora Drift — post-launch sync"

@Suite struct MCPBudgetTests {
    @Test func longTranscriptPagesCoverEveryLineOnce() async throws {
        let library = try await Library.seeded()
        let id = try library.id(tidewatch)
        try await library.replaceTranscript(id, (0 ..< 3000).map { (nil, filler($0, length: 150)) })
        let helper = try HelperProcess(root: library.root)

        let pages = try helper.pages("get_transcript", ["meeting_id": id])
        #expect(pages.count > 1)
        let indices = pages.flatMap { $0["lines"] as? [String] ?? [] }.compactMap(lineIndex)
        #expect(indices == Array(0 ..< 3000))
        #expect(pages.allSatisfy { $0["total_lines"] as? Int == 3000 })
        #expect(try helper.finish() == 0)
    }

    @Test func contextWindowsPageWithoutLossOrLeadingSeparator() async throws {
        let library = try await Library.seeded()
        let id = try library.id(tidewatch)
        let marked = Set(stride(from: 3, to: 3000, by: 37))
        try await library.replaceTranscript(
            id, (0 ..< 3000).map { (nil, filler($0, length: 150) + (marked.contains($0) ? " harbormark" : "")) })
        let helper = try HelperProcess(root: library.root)

        let pages = try helper.pages("get_transcript", ["meeting_id": id, "contains": "harbormark", "context": 2])
        #expect(pages.count > 1)
        var expected = Set<Int>()
        for i in marked { for j in max(i - 2, 0) ... min(i + 2, 2999) { expected.insert(j) } }
        let lines = pages.map { $0["lines"] as? [String] ?? [] }
        #expect(lines.allSatisfy { $0.first != "…" })
        #expect(lines.joined().contains("…"))
        #expect(lines.joined().compactMap(lineIndex) == expected.sorted())
        #expect(pages.allSatisfy { $0["matched_lines"] as? Int == marked.count })
        #expect(try helper.finish() == 0)
    }

    @Test func oneHugeLineIsCutAndTheCursorAdvances() async throws {
        let library = try await Library.seeded()
        let id = try library.id(tidewatch)
        try await library.replaceTranscript(id, [(nil, filler(0, length: 40_000)), (nil, filler(1, length: 80))])
        let helper = try HelperProcess(root: library.root)

        let first = try helper.json("get_transcript", ["meeting_id": id])
        let lines = try #require(first["lines"] as? [String])
        #expect(lines.count == 1)
        #expect(lines.first?.hasSuffix("…") == true)
        #expect(first["truncated"] as? Bool == true)
        #expect(first["next_cursor"] as? String == "1")
        let second = try helper.json("get_transcript", ["meeting_id": id, "cursor": "1"])
        #expect((second["lines"] as? [String])?.compactMap(lineIndex) == [1])
        #expect(second["next_cursor"] == nil)
        #expect(try helper.finish() == 0)
    }

    @Test func hugeTitleWithNoLines() async throws {
        let library = try await Library.seeded()
        let id = try library.id(tidewatch)
        try library.execute("UPDATE meeting SET title = ? WHERE id = ?", [filler(0, length: 40_000), id])
        let helper = try HelperProcess(root: library.root)

        let result = try helper.json("get_transcript", ["meeting_id": id])
        #expect(result["lines"] as? [String] == [])
        #expect(result["truncated"] as? Bool == true)
        #expect(result["meeting_id"] as? String == id)
        #expect(try helper.finish() == 0)
    }

    @Test func actionItemPagesStayInBudget() async throws {
        let library = try await Library.seeded()
        let id = try library.id(aurora)
        try await library.rewriteNotes(id) { notes in
            notes.structured.userActionItems = (0 ..< 300).map {
                ActionItem(owner: "Demo User", text: filler($0, length: 250))
            }
        }
        let helper = try HelperProcess(root: library.root)

        let pages = try helper.pages("list_action_items", ["limit": 100])
        let texts = pages.flatMap { ($0["items"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String } }
        #expect(pages.contains { ($0["items"] as? [Any])?.count ?? 0 < 100 && $0["next_cursor"] != nil })
        #expect(texts.count == 312)
        #expect(Set(texts).count == 312)
        #expect(texts.compactMap(lineIndex) == Array(0 ..< 300))
        #expect(pages.allSatisfy { $0["truncated"] == nil })
        #expect(try helper.finish() == 0)
    }

    @Test func searchPagesWithLongTitles() async throws {
        let library = try await Library.seeded()
        try await library.database.pool.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM meeting")
            for (i, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE meeting SET title = ? WHERE id = ?", arguments: [filler(i, length: 3000), id])
            }
        }
        let helper = try HelperProcess(root: library.root)

        let pages = try helper.pages("search_meetings", ["limit": 25])
        #expect(pages.count > 1)
        let ids = pages.flatMap { ($0["meetings"] as? [[String: Any]] ?? []).compactMap { $0["meeting_id"] as? String } }
        let expected = try await library.database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM meeting ORDER BY started_at DESC, id DESC")
        }
        #expect(ids == expected)
        #expect(try helper.finish() == 0)
    }

    @Test func hugeNotesAndHugeUserItem() async throws {
        let library = try await Library.seeded()
        let id = try library.id(aurora)
        try await library.rewriteNotes(id) { notes in
            notes.markdown = (0 ..< 400).map { filler($0, length: 99) }.joined(separator: "\n")
            notes.structured.userActionItems = [ActionItem(owner: "Demo User", text: filler(0, length: 33_000))]
        }
        let helper = try HelperProcess(root: library.root)

        let meeting = try helper.json("get_meeting", ["meeting_id": id])
        #expect(meeting["truncated"] as? Bool == true)
        #expect((meeting["notes_markdown"] as? String)?.hasSuffix("…") == true)
        #expect(meeting["meeting_id"] as? String == id)
        #expect(try helper.finish() == 0)
    }

    @Test func notesCutKeepsTheLastFittingLine() async throws {
        let library = try await Library.seeded()
        let id = try library.id(aurora)
        let line = String(repeating: "\"", count: 1000)
        try await library.rewriteNotes(id) { notes in
            notes.markdown = Array(repeating: line, count: 20).joined(separator: "\n")
        }
        let helper = try HelperProcess(root: library.root)

        let meeting = try helper.json("get_meeting", ["meeting_id": id])
        let (text, _) = try helper.call("get_meeting", ["meeting_id": id])
        let notes = try #require(meeting["notes_markdown"] as? String)
        #expect(meeting["truncated"] as? Bool == true)
        #expect(notes.hasSuffix("\n…"))
        #expect(notes.dropLast().split(separator: "\n").allSatisfy { $0 == line })
        // One more whole line serializes to 2.000 escaped quotes plus an escaped newline.
        #expect(text.utf16.count + 2002 > 32_000, "result is \(text.utf16.count) UTF-16 units")
        #expect(try helper.finish() == 0)
    }

    @Test func overlongListsAreCapped() async throws {
        let library = try await Library.seeded()
        let id = try library.id(aurora)
        try await library.rewriteNotes(id) { notes in
            notes.structured.userActionItems = (0 ..< 1300).map { ActionItem(owner: "Demo User", text: "Item \($0)") }
        }
        let attendees = (0 ..< 300).map { ["name": "Quoll Guest \($0)", "source": "manual"] }
        try library.execute(
            "UPDATE meeting SET attendees = ? WHERE id = ?",
            [String(decoding: try JSONSerialization.data(withJSONObject: attendees), as: UTF8.self), id])
        let helper = try HelperProcess(root: library.root)

        let meeting = try helper.json("get_meeting", ["meeting_id": id])
        let names = try #require(meeting["attendees"] as? [String])
        #expect(names.count == 101)
        #expect(names.last == "+200 more")
        #expect((meeting["user_action_items"] as? [Any])?.count == 100)
        #expect(meeting["more_user_action_items"] as? Int == 1200)
        #expect(meeting["truncated"] as? Bool == true)
        #expect(try helper.finish() == 0)
    }

    @Test func oversizedDigestIsDroppedFirst() async throws {
        let library = try await Library.seeded()
        let id = try library.id(aurora)
        try library.execute("UPDATE meeting_notes SET memory_digest = ? WHERE meeting_id = ?", [filler(0, length: 40_000), id])
        let notes = try await library.notes(id)
        let helper = try HelperProcess(root: library.root)

        let meeting = try helper.json("get_meeting", ["meeting_id": id])
        #expect(meeting["digest"] == nil)
        #expect(meeting["truncated"] as? Bool == true)
        #expect(meeting["notes_markdown"] as? String == notes.markdown)

        try library.execute("UPDATE meeting_notes SET memory_digest = ? WHERE meeting_id = ?", ["Short digest.", id])
        let small = try helper.json("get_meeting", ["meeting_id": id])
        #expect(small["digest"] as? String == "Short digest.")
        #expect(small["truncated"] == nil)
        #expect(try helper.finish() == 0)
    }

    @Test func cutPassRemovesTheWholeOverflow() {
        var value = JSON.obj([
            ("id", .str(String(repeating: "7", count: 20))),
            ("a", .text(String(repeating: "🚀\"", count: 12_000))),
            ("b", .text(String(repeating: "x\n", count: 9_000))),
            ("c", .text("y")),
        ])
        cutToBudget(&value)
        #expect(measure(value) <= maxResultChars)
        guard case .obj(let fields) = value, case .str(let id) = fields[0].1 else {
            Issue.record("shape changed")
            return
        }
        #expect(id == String(repeating: "7", count: 20))
    }
}
