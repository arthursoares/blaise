import Foundation
import GRDB

// MARK: - Shared meeting fields

struct MeetingRow {
    let id: String
    let title: String
    let startedAt: Date
    let endedAt: Date?
    let status: String
    let source: String
    let attendeesJSON: String

    static let columns = "id, title, started_at, ended_at, status, source, attendees"

    /// Throws on a value that does not decode, so a corrupt row fails the
    /// call instead of trapping the process.
    init(_ row: Row) throws {
        id = try row.decode(forColumn: "id")
        title = try row.decode(forColumn: "title")
        startedAt = try row.decode(forColumn: "started_at")
        endedAt = try row.decode(forColumn: "ended_at")
        status = try row.decode(forColumn: "status")
        source = try row.decode(forColumn: "source")
        attendeesJSON = try row.decode(forColumn: "attendees")
    }

    var durationMinutes: Int? {
        endedAt.map { Int(($0.timeIntervalSince(startedAt) / 60).rounded()) }
    }

    static func fetch(_ db: Database, id: String) throws -> MeetingRow {
        guard
            let row = try Row.fetchOne(
                db, sql: "SELECT \(columns) FROM meeting WHERE id = ?", arguments: [id])
        else { throw ToolError("No meeting with id \(id) in the Blaise library.") }
        return try MeetingRow(row)
    }
}

private func placeholders(_ count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}

// MARK: - search_meetings

func searchMeetings(_ args: Arguments) throws -> String {
    let query = try args.string("query")
    let person = try args.string("person")
    let range = try parseRange(args)
    let limit = try args.integer("limit", in: 1...25) ?? 10
    let offset = try args.cursor()
    var pattern: String?
    if let query {
        guard let built = FTS5Pattern(matchingAllTokensIn: query) else {
            throw ToolError("Invalid query: it has no searchable words.")
        }
        pattern = built.rawPattern
    }

    return try withLibrary { db in
        let (clause, arguments) = range.sql
        var meetings = try Row.fetchAll(
            db,
            sql: "SELECT \(MeetingRow.columns) FROM meeting WHERE \(clause) ORDER BY started_at DESC, id DESC",
            arguments: arguments
        ).map { try MeetingRow($0) }

        var notesMatched: Set<String> = []
        var transcriptHits: [String: Int] = [:]
        if let pattern {
            notesMatched = Set(
                try String.fetchAll(
                    db, sql: "SELECT meeting_id FROM notes_fts WHERE notes_fts MATCH ?", arguments: [pattern]))
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT s.meeting_id, count(*) FROM transcript_fts
                    JOIN transcript_segment s ON s.id = transcript_fts.rowid
                    WHERE transcript_fts MATCH ? GROUP BY s.meeting_id
                    """,
                arguments: [pattern])
            {
                transcriptHits[try row.decode(atIndex: 0)] = try row.decode(atIndex: 1)
            }
            meetings = meetings.filter { notesMatched.contains($0.id) || transcriptHits[$0.id] != nil }
        }

        if let person, !meetings.isEmpty {
            var speakers: [String: [String]] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT meeting_id, speaker_name FROM transcript_segment
                    WHERE speaker_name IS NOT NULL AND meeting_id IN (\(placeholders(meetings.count)))
                    """,
                arguments: StatementArguments(meetings.map(\.id)))
            {
                speakers[try row.decode(atIndex: 0), default: []].append(try row.decode(atIndex: 1))
            }
            meetings = meetings.filter { meeting in
                attendeeNames(meeting.attendeesJSON).contains {
                    folds($0.name, contains: person) || $0.email.map { folds($0, contains: person) } == true
                } || (speakers[meeting.id] ?? []).contains { folds($0, contains: person) }
            }
        }

        let page = Array(meetings.dropFirst(offset).prefix(limit))
        let ids = page.map(\.id)
        let identity = try Identity.read(db)

        var summaries: [String: String] = [:]
        var notesSnippets: [String: String] = [:]
        var transcriptMatches: [String: [String]] = [:]
        if !ids.isEmpty {
            if pattern == nil {
                for row in try Row.fetchAll(
                    db,
                    sql: "SELECT meeting_id, structured FROM meeting_notes WHERE meeting_id IN (\(placeholders(ids.count)))",
                    arguments: StatementArguments(ids))
                {
                    if let notes = NotesSubset.decode(try row.decode(forColumn: "structured")), !notes.summary.isEmpty {
                        summaries[try row.decode(forColumn: "meeting_id")] = clip(notes.summary, 300)
                    }
                }
            } else if let pattern {
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT meeting_id, snippet(notes_fts, 1, '«', '»', '…', 16) FROM notes_fts
                        WHERE notes_fts MATCH ? AND meeting_id IN (\(placeholders(ids.count)))
                        """,
                    arguments: StatementArguments([pattern] + ids))
                {
                    notesSnippets[try row.decode(atIndex: 0)] = clip(try row.decode(atIndex: 1), 240)
                }
                for row in try Row.fetchAll(
                    db,
                    // snippet() is refused inside a window-function subquery, so the
                    // window only picks the first two matching rows per meeting.
                    sql: """
                        SELECT s.meeting_id, s.start_seconds, s.speaker_label, s.speaker_name,
                            snippet(transcript_fts, 0, '«', '»', '…', 16) AS snip
                        FROM transcript_fts JOIN transcript_segment s ON s.id = transcript_fts.rowid
                        WHERE transcript_fts MATCH ? AND transcript_fts.rowid IN (
                            SELECT id FROM (
                                SELECT t.id, row_number() OVER (PARTITION BY t.meeting_id ORDER BY t.ord) AS rn
                                FROM transcript_fts JOIN transcript_segment t ON t.id = transcript_fts.rowid
                                WHERE transcript_fts MATCH ? AND t.meeting_id IN (\(placeholders(ids.count)))
                            ) WHERE rn <= 2)
                        ORDER BY s.meeting_id, s.ord
                        """,
                    arguments: StatementArguments([pattern, pattern] + ids))
                {
                    let speaker = speakerName(
                        label: try row.decode(forColumn: "speaker_label"), name: try row.decode(forColumn: "speaker_name"),
                        identity: identity)
                    let start: Double = try row.decode(forColumn: "start_seconds")
                    let snip: String = try row.decode(forColumn: "snip")
                    let line = "[\(timecode(start))] \(speaker): \(snip)"
                    transcriptMatches[try row.decode(forColumn: "meeting_id"), default: []].append(clip(line, 240))
                }
            }
        }

        let header: [(String, JSON)] = [("total", .int(meetings.count)), ("meetings", .arr([]))]
        var budget = PageBudget(header: header)
        var entries: [JSON] = []
        for meeting in page {
            var fields: [(String, JSON)] = [
                ("meeting_id", .str(meeting.id)),
                ("title", .text(meeting.title)),
                ("started_at", .str(isoDate(meeting.startedAt))),
            ]
            if let minutes = meeting.durationMinutes { fields.append(("duration_min", .int(minutes))) }
            fields.append(("status", .str(meeting.status)))
            fields.append(("attendees", cappedNames(attendeeNames(meeting.attendeesJSON).map(\.name), cap: 12).0))
            if let summary = summaries[meeting.id] { fields.append(("summary", .text(summary))) }
            if let snippet = notesSnippets[meeting.id] { fields.append(("notes_match", .text(snippet))) }
            if let hits = transcriptHits[meeting.id] {
                fields.append(("transcript_hits", .int(hits)))
                fields.append(("transcript_matches", .arr((transcriptMatches[meeting.id] ?? []).map { .text($0) })))
            }
            let entry = JSON.obj(fields)
            guard budget.admit([entry]) else { break }
            entries.append(entry)
        }

        var result = header
        result[1].1 = .arr(entries)
        if offset + entries.count < meetings.count {
            result.append(("next_cursor", .str(String(offset + entries.count))))
        }
        return finish(result, truncated: false)
    }
}

// MARK: - get_meeting

func getMeeting(_ args: Arguments) throws -> String {
    let id = try args.meetingID()
    return try withLibrary { db in
        let meeting = try MeetingRow.fetch(db, id: id)
        let notesRow = try Row.fetchOne(
            db,
            sql: "SELECT markdown, language, structured, memory_digest FROM meeting_notes WHERE meeting_id = ?",
            arguments: [id])
        let lineCount = try Int.fetchOne(
            db, sql: "SELECT count(*) FROM transcript_segment WHERE meeting_id = ?", arguments: [id]) ?? 0
        let doneKeys = Set(
            try String.fetchAll(
                db, sql: "SELECT item_key FROM action_item_state WHERE meeting_id = ?", arguments: [id]))

        var truncated = false
        let (attendees, attendeesOver) = cappedNames(attendeeNames(meeting.attendeesJSON).map(\.name), cap: 100)
        truncated = truncated || attendeesOver
        var notes: String? = try notesRow?.decode(forColumn: "markdown")
        var digest: String? = try notesRow?.decode(forColumn: "memory_digest")
        let language: String? = try notesRow?.decode(forColumn: "language")
        var userItems: [JSON]?
        var moreUserItems = 0
        if let notesRow {
            let items = (NotesSubset.decode(try notesRow.decode(forColumn: "structured"))?.userActionItems ?? [])
                .filter { !isBlank($0.text) }
            userItems = items.prefix(100).map { item in
                .obj([("text", .text(item.text)), ("done", .bool(doneKeys.contains(actionItemKey(item.text))))])
            }
            moreUserItems = max(items.count - 100, 0)
            truncated = truncated || moreUserItems > 0
        }

        func build() -> [(String, JSON)] {
            var fields: [(String, JSON)] = [
                ("meeting_id", .str(meeting.id)),
                ("title", .text(meeting.title)),
                ("started_at", .str(isoDate(meeting.startedAt))),
            ]
            if let ended = meeting.endedAt { fields.append(("ended_at", .str(isoDate(ended)))) }
            if let minutes = meeting.durationMinutes { fields.append(("duration_min", .int(minutes))) }
            fields.append(("status", .str(meeting.status)))
            fields.append(("source", .str(meeting.source)))
            if let language { fields.append(("language", .str(language))) }
            fields.append(("attendees", attendees))
            fields.append(("notes_markdown", notes.map { .text($0) } ?? .null))
            if let userItems { fields.append(("user_action_items", .arr(userItems))) }
            if moreUserItems > 0 { fields.append(("more_user_action_items", .int(moreUserItems))) }
            if let digest { fields.append(("digest", .text(digest))) }
            fields.append(("transcript_lines", .int(lineCount)))
            if truncated { fields.append(("truncated", .bool(true))) }
            return fields
        }

        if measure(.obj(build())) > maxResultChars, digest != nil {
            digest = nil
            truncated = true
        }
        if measure(.obj(build())) > maxResultChars, let markdown = notes {
            truncated = true
            // The last line break whose prefix fits, measured serialized:
            // the result size grows with the prefix, so a binary search finds it.
            let breaks = markdown.indices.filter { markdown[$0] == "\n" }
            func cut(_ k: Int) -> String { String(markdown[...breaks[k]]) + "…" }
            var low = 0
            var high = breaks.count
            while low < high {
                let mid = (low + high) / 2
                notes = cut(mid)
                if measure(.obj(build())) <= maxResultChars { low = mid + 1 } else { high = mid }
            }
            notes = low == 0 ? "…" : cut(low - 1)
        }
        return finish(build().filter { $0.0 != "truncated" }, truncated: truncated)
    }
}

// MARK: - get_transcript

func getTranscript(_ args: Arguments) throws -> String {
    let id = try args.meetingID()
    let contains = try args.string("contains")
    let speaker = try args.string("speaker")
    let startAt = try args.timecode("start_at")
    let endAt = try args.timecode("end_at")
    let context = try args.integer("context", in: 0...5) ?? 0
    let cursor = try args.cursor()
    let terms = contains.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
    if let terms, terms.isEmpty { throw ToolError("Invalid contains: give at least one word.") }
    if let startAt, let endAt, startAt > endAt { throw ToolError("Invalid start_at: it is later than end_at.") }

    return try withLibrary { db in
        let meeting = try MeetingRow.fetch(db, id: id)
        let identity = try Identity.read(db)
        let segments = try Row.fetchAll(
            db,
            sql: """
                SELECT ord, start_seconds, speaker_label, speaker_name, text FROM transcript_segment
                WHERE meeting_id = ? ORDER BY ord
                """,
            arguments: [id])
        let texts: [String] = try segments.map { try $0.decode(forColumn: "text") }
        let starts: [Double] = try segments.map { try $0.decode(forColumn: "start_seconds") }
        let ords: [Int] = try segments.map { try $0.decode(forColumn: "ord") }
        let speakers = try segments.map {
            speakerName(
                label: try $0.decode(forColumn: "speaker_label"), name: try $0.decode(forColumn: "speaker_name"),
                identity: identity)
        }

        let filtered = terms != nil || speaker != nil || startAt != nil || endAt != nil
        var matched: [Int] = []
        for i in segments.indices {
            let text = texts[i]
            let start = starts[i]
            if let terms, !terms.allSatisfy({ folds(text, contains: $0) }) { continue }
            if let speaker, !folds(speakers[i], contains: speaker) { continue }
            if let startAt, start < startAt { continue }
            if let endAt, start > endAt { continue }
            matched.append(i)
        }
        let separated = context > 0 && (terms != nil || speaker != nil)
        var window = Set(matched)
        if separated {
            for i in matched {
                for j in max(i - context, 0)...min(i + context, segments.count - 1) { window.insert(j) }
            }
        }

        var header: [(String, JSON)] = [
            ("meeting_id", .str(meeting.id)),
            ("title", .text(meeting.title)),
            ("started_at", .str(isoDate(meeting.startedAt))),
            ("status", .str(meeting.status)),
            ("total_lines", .int(segments.count)),
        ]
        if filtered { header.append(("matched_lines", .int(matched.count))) }
        header.append(("lines", .arr([])))
        var budget = PageBudget(header: header)
        var lines: [JSON] = []
        var previous: Int?
        var nextCursor: Int?
        for i in window.sorted() where ords[i] >= cursor {
            let line = JSON.text("[\(timecode(starts[i]))] \(speakers[i]): \(texts[i])")
            let items = separated && previous != nil && i != previous! + 1 ? [JSON.str("…"), line] : [line]
            guard budget.admit(items) else {
                nextCursor = ords[i]
                break
            }
            lines += items
            previous = i
        }

        var result = header
        result[result.count - 1].1 = .arr(lines)
        if let nextCursor { result.append(("next_cursor", .str(String(nextCursor)))) }
        return finish(result, truncated: false)
    }
}

// MARK: - list_action_items

func listActionItems(_ args: Arguments) throws -> String {
    let owner = try args.string("owner")
    let state = try args.string("state") ?? "open"
    guard ["open", "done", "all"].contains(state) else {
        throw ToolError("Invalid state: use \"open\", \"done\" or \"all\".")
    }
    let range = try parseRange(args)
    let limit = try args.integer("limit", in: 1...100) ?? 50
    let offset = try args.cursor()

    return try withLibrary { db in
        let identity = try Identity.read(db)
        let (clause, arguments) = range.sql
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT m.id, m.title, m.started_at, m.status, n.structured
                FROM meeting_notes n JOIN meeting m ON m.id = n.meeting_id
                WHERE \(clause) ORDER BY m.started_at DESC, m.id DESC
                """,
            arguments: arguments)
        var done: Set<String> = []
        for row in try Row.fetchAll(db, sql: "SELECT meeting_id, item_key FROM action_item_state") {
            done.insert((try row.decode(String.self, atIndex: 0)) + " " + (try row.decode(String.self, atIndex: 1)))
        }

        let userOwner = identity.displayName
        let userMatches =
            owner == nil || owner == "*"
            || folds(userOwner, contains: owner!) || folds(identity.name, contains: owner!)
            || identity.aliases.contains { folds($0, contains: owner!) }

        var items: [JSON] = []
        for row in rows {
            guard let notes = NotesSubset.decode(try row.decode(forColumn: "structured")) else { continue }
            let meetingID: String = try row.decode(forColumn: "id")
            let title: String = try row.decode(forColumn: "title")
            let startedAt: Date = try row.decode(forColumn: "started_at")
            let status: String = try row.decode(forColumn: "status")
            let meetingFields: [(String, JSON)] = [
                ("meeting_id", .str(meetingID)),
                ("meeting_title", .text(title)),
                ("meeting_date", .str(isoDate(startedAt))),
                ("meeting_status", .str(status)),
            ]
            let userItems = notes.userActionItems.filter { !isBlank($0.text) }
            if userMatches {
                for item in userItems {
                    let itemState = done.contains(meetingID + " " + actionItemKey(item.text)) ? "done" : "open"
                    guard state == "all" || state == itemState else { continue }
                    items.append(
                        .obj(meetingFields + [
                            ("owner", .text(userOwner)), ("text", .text(item.text)), ("state", .str(itemState)),
                        ]))
                }
            }
            guard state == "all", let owner else { continue }
            let userCopies = userItems.map { ($0.owner, actionItemKey($0.text)) }
            for item in notes.actionItems where !isBlank(item.text) {
                if owner != "*" && !folds(item.owner, contains: owner) { continue }
                let key = actionItemKey(item.text)
                if userCopies.contains(where: { foldEqual($0.0, item.owner) && $0.1 == key }) { continue }
                items.append(
                    .obj(meetingFields + [
                        ("owner", .text(item.owner)), ("text", .text(item.text)), ("state", .str("untracked")),
                    ]))
            }
        }

        let header: [(String, JSON)] = [("total", .int(items.count)), ("items", .arr([]))]
        var budget = PageBudget(header: header)
        var page: [JSON] = []
        for item in items.dropFirst(offset).prefix(limit) {
            guard budget.admit([item]) else { break }
            page.append(item)
        }
        var result = header
        result[1].1 = .arr(page)
        if offset + page.count < items.count {
            result.append(("next_cursor", .str(String(offset + page.count))))
        }
        return finish(result, truncated: false)
    }
}
