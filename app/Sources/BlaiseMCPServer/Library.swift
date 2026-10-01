import CryptoKit
import Foundation
import GRDB

/// The last migration the helper's SQL was written against. Must equal the
/// app's last migration identifier (pinned by a test).
let expectedSchema = "v23"
private let knownSchemas = Set((1...23).map { "v\($0)" })

/// A tool execution error: one plain sentence, returned with `isError: true`.
struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

enum LibraryText {
    static let missing =
        "Blaise has no meeting library on this Mac yet. Open Blaise and record or import a meeting, then try again."
    static let notReady = "Blaise's library isn't ready for reading. Open Blaise once, then try again."
    static let behind = "Blaise was updated but hasn't been opened since. Open Blaise once, then try again."
    static let ahead = "This connector is older than your Blaise library. Update Blaise, then try again."
    static let busy = "Blaise is busy writing right now. Try again in a moment."
    static func sqlite(_ code: Int32) -> String { "Blaise's library could not be read (SQLite error \(code))." }
}

/// `BLAISE_DATA_ROOT` when set, else `<Application Support>/Blaise`, found
/// without creating anything.
func libraryDatabasePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    let root: String
    if let override = environment["BLAISE_DATA_ROOT"] {
        root = override
    } else {
        guard
            let support = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        else { return nil }
        root = support.appendingPathComponent("Blaise", isDirectory: true).path
    }
    return (root as NSString).appendingPathComponent("blaise.sqlite")
}

/// Read-only comes from the open flag: a write on this connection fails with
/// `SQLITE_READONLY`.
func openReadOnly(path: String) throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.readonly = true
    configuration.busyMode = .timeout(2)
    return try DatabaseQueue(path: path, configuration: configuration)
}

/// Opens the library for one call, checks the schema, and runs `body` inside
/// a single read transaction (one snapshot), then closes the connection.
func withLibrary<T>(_ body: (Database) throws -> T) throws -> T {
    guard let path = libraryDatabasePath(), FileManager.default.fileExists(atPath: path) else {
        throw ToolError(LibraryText.missing)
    }
    do {
        let queue = try openReadOnly(path: path)
        defer { try? queue.close() }
        return try queue.read { db in
            let tail = try String.fetchOne(
                db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1")
            if tail != expectedSchema {
                throw ToolError(knownSchemas.contains(tail ?? "") ? LibraryText.behind : LibraryText.ahead)
            }
            return try body(db)
        }
    } catch let error as DatabaseError {
        switch error.resultCode.primaryResultCode {
        case .SQLITE_CANTOPEN: throw ToolError(LibraryText.notReady)
        case .SQLITE_BUSY: throw ToolError(LibraryText.busy)
        default: throw ToolError(LibraryText.sqlite(error.resultCode.primaryResultCode.rawValue))
        }
    }
}

// MARK: - Library records

struct Identity: Decodable {
    var name: String
    var aliases: [String]

    static let empty = Identity(name: "", aliases: [])

    static func read(_ db: Database) throws -> Identity {
        guard
            let json = try String.fetchOne(
                db, sql: "SELECT value FROM app_setting WHERE key = 'user.identity'"),
            let identity = try? JSONDecoder().decode(Identity.self, from: Data(json.utf8))
        else { return .empty }
        return identity
    }

    /// The owner shown for the user's own items and the reserved `user` speaker.
    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "You" : name
    }
}

struct NoteItem: Decodable {
    var owner: String
    var text: String
}

/// The part of the notes' structured JSON the helper reads.
struct NotesSubset: Decodable {
    var summary: String
    var actionItems: [NoteItem]
    var userActionItems: [NoteItem]

    enum CodingKeys: String, CodingKey {
        case summary
        case actionItems = "action_items"
        case userActionItems = "user_action_items"
        case legacyUserActionItems = "ric_action_items"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary)
        actionItems = try c.decode([NoteItem].self, forKey: .actionItems)
        userActionItems =
            try c.decodeIfPresent([NoteItem].self, forKey: .userActionItems)
            ?? c.decode([NoteItem].self, forKey: .legacyUserActionItems)
    }

    static func decode(_ json: String?) -> NotesSubset? {
        json.flatMap { try? JSONDecoder().decode(NotesSubset.self, from: Data($0.utf8)) }
    }
}

func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

private struct AttendeeSubset: Decodable {
    var name: String
    var email: String?
}

/// Attendee display names, e-mail-shaped names prettified as the app shows
/// them; an e-mail-shaped name with no e-mail field is also the e-mail.
func attendeeNames(_ json: String) -> [(name: String, email: String?)] {
    let attendees = (try? JSONDecoder().decode([AttendeeSubset].self, from: Data(json.utf8))) ?? []
    return attendees.map { attendee in
        let name = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.contains("@") { return (prettifyLocalPart(name), attendee.email ?? name) }
        if name.isEmpty, let email = attendee.email { return (prettifyLocalPart(email), email) }
        return (name, attendee.email)
    }
}

private func prettifyLocalPart(_ emailish: String) -> String {
    let local =
        emailish.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    guard !local.isEmpty else { return emailish }
    let parts = local
        .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
        .filter { !$0.allSatisfy(\.isNumber) }
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
    return parts.isEmpty ? String(local) : parts.joined(separator: " ")
}

/// A list capped at `cap` entries, then `"+N more"`.
func cappedNames(_ names: [String], cap: Int) -> (JSON, overflow: Bool) {
    var out = names.prefix(cap).map { JSON.text($0) }
    if names.count > cap { out.append(.str("+\(names.count - cap) more")) }
    return (.arr(out), names.count > cap)
}

/// The action-item key: case/diacritic fold, curly apostrophe straightened,
/// whitespace collapsed, SHA-256 hex. Must equal the app's key for every text.
func actionItemKey(_ text: String) -> String {
    let folded = text.replacingOccurrences(of: "\u{2019}", with: "'")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    let collapsed = folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let digits = Array("0123456789abcdef".utf8)
    var hex: [UInt8] = []
    hex.reserveCapacity(64)
    for byte in SHA256.hash(data: Data(collapsed.utf8)) {
        hex.append(digits[Int(byte >> 4)])
        hex.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: hex, as: UTF8.self)
}

func folds(_ haystack: String, contains needle: String) -> Bool {
    haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

func foldEqual(_ a: String, _ b: String) -> Bool {
    a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
}

func speakerName(label: String, name: String?, identity: Identity) -> String {
    if let name { return name }
    return label == "user" ? identity.displayName : label
}

func timecode(_ seconds: Double) -> String {
    let total = Int(seconds)
    return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}

// MARK: - Dates

nonisolated(unsafe) private let outputFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    return formatter
}()

func isoDate(_ date: Date) -> String { outputFormatter.string(from: date) }

/// A `started_at` range: `from` inclusive, `to` inclusive of its whole day
/// when given as a day.
struct DateRange {
    var lower: Date?
    var upper: Date?
    var upperInclusive = false

    var sql: (clause: String, arguments: StatementArguments) {
        var clauses: [String] = []
        var arguments = StatementArguments()
        if let lower {
            clauses.append("started_at >= ?")
            arguments += [lower]
        }
        if let upper {
            clauses.append(upperInclusive ? "started_at <= ?" : "started_at < ?")
            arguments += [upper]
        }
        return (clauses.isEmpty ? "1" : clauses.joined(separator: " AND "), arguments)
    }
}

/// `YYYY-MM-DD`, or the whole of `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`.
private func parseDateInput(_ s: String, field: String) throws -> (date: Date, isDay: Bool) {
    let shape = ToolError(
        "Invalid \(field): use YYYY-MM-DD or a full ISO 8601 timestamp such as 2026-09-29T14:30:00-03:00.")
    guard
        let m = s.wholeMatch(
            of: /([0-9]{4})-([0-9]{2})-([0-9]{2})(?:T([01][0-9]|2[0-3]):([0-5][0-9]):([0-5][0-9])(\.[0-9]+)?(?:(Z)|([+-])([01][0-9]|2[0-3]):([0-5][0-9])))?/)
    else { throw shape }
    let (year, month, day) = (Int(m.1)!, Int(m.2)!, Int(m.3)!)
    guard
        DateComponents(calendar: Calendar(identifier: .gregorian), year: year, month: month, day: day)
            .isValidDate
    else { throw ToolError("Invalid \(field): \(s.prefix(10)) is not a real date.") }
    var calendar = Calendar(identifier: .gregorian)
    guard let hour = m.4, let minute = m.5, let second = m.6 else {
        calendar.timeZone = .current
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            throw shape
        }
        return (date, true)
    }
    var offset = 0
    if let sign = m.9, let offsetHours = m.10, let offsetMinutes = m.11 {
        offset = (Int(offsetHours)! * 3600 + Int(offsetMinutes)! * 60) * (sign == "-" ? -1 : 1)
    }
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard
        let date = calendar.date(
            from: DateComponents(
                year: year, month: month, day: day, hour: Int(hour)!, minute: Int(minute)!, second: Int(second)!))
    else { throw shape }
    let fraction = m.7.flatMap { Double("0" + $0) } ?? 0
    return (date.addingTimeInterval(fraction - Double(offset)), false)
}

func parseRange(_ args: Arguments) throws -> DateRange {
    var range = DateRange()
    if let from = try args.string("from") {
        range.lower = try parseDateInput(from, field: "from").date
    }
    if let to = try args.string("to") {
        let parsed = try parseDateInput(to, field: "to")
        if parsed.isDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            range.upper = calendar.date(byAdding: .day, value: 1, to: parsed.date)
        } else {
            range.upper = parsed.date
            range.upperInclusive = true
        }
    }
    if let lower = range.lower, let upper = range.upper,
        range.upperInclusive ? lower > upper : lower >= upper
    {
        throw ToolError("Invalid from: it is later than to.")
    }
    return range
}

// MARK: - Arguments

/// Tool arguments, validated at the boundary; every failure names its field.
struct Arguments {
    let raw: [String: Any]

    func string(_ key: String) throws -> String? {
        guard let v = raw[key] else { return nil }
        guard let s = v as? String else { throw ToolError("Invalid \(key): expected a string.") }
        return s
    }

    func integer(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let v = raw[key] else { return nil }
        guard let n = jsonInteger(v), range.contains(n) else {
            throw ToolError(
                "Invalid \(key): expected an integer from \(range.lowerBound) to \(range.upperBound).")
        }
        return n
    }

    func meetingID() throws -> String {
        guard let id = try string("meeting_id") else {
            throw ToolError("Missing meeting_id: pass the meeting_id from search_meetings.")
        }
        guard id.wholeMatch(of: /[0-7][0-9A-HJKMNP-TV-Z]{25}/) != nil else {
            throw ToolError("Invalid meeting_id: expected a 26-character Blaise meeting id from search_meetings.")
        }
        return id
    }

    /// The decimal position a previous result handed out; 0 when absent.
    func cursor() throws -> Int {
        guard let s = try string("cursor") else { return 0 }
        guard s.wholeMatch(of: /[0-9]{1,9}/) != nil, let n = Int(s) else {
            throw ToolError("Invalid cursor: pass back the next_cursor value unchanged.")
        }
        return n
    }

    /// `H:MM:SS`, `M:SS` or `MM:SS`, in seconds.
    func timecode(_ key: String) throws -> Double? {
        guard let s = try string(key) else { return nil }
        if let m = s.wholeMatch(of: /([0-9]{1,6}):([0-5][0-9]):([0-5][0-9])/) {
            return Double(Int(m.1)! * 3600 + Int(m.2)! * 60 + Int(m.3)!)
        }
        if let m = s.wholeMatch(of: /([0-9]{1,2}):([0-5][0-9])/) {
            return Double(Int(m.1)! * 60 + Int(m.2)!)
        }
        throw ToolError("Invalid \(key): use H:MM:SS, M:SS or MM:SS from the meeting's start.")
    }
}
