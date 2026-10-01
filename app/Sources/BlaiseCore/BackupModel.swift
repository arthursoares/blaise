import Foundation

/// Why a backup run failed; the first failing operation decides, by where it acts.
public enum BackupFailureReason: String, Codable, Sendable, CaseIterable {
    case notConnected, full, notWritable
    case passwordUnavailable, databaseCheck, localDiskFull, localError

    /// The `<reason>` of the Settings stale line.
    public var statusText: String {
        switch self {
        case .notConnected: return "drive not connected"
        case .notWritable: return "folder not writable"
        case .full: return "destination full"
        case .localDiskFull: return "this Mac's disk is full"
        case .localError: return "could not read the library on this Mac"
        case .databaseCheck: return "database check failed"
        case .passwordUnavailable:
            return "encryption password missing — turn Encrypt backups off and on again"
        }
    }
}

/// `<root>/.backup-state.json`. Outside the backup allowlist, so a restore never changes it.
public struct BackupState: Codable, Equatable, Sendable {
    public struct Failure: Codable, Equatable, Sendable {
        public var reason: BackupFailureReason
        public var at: Date
    }

    public var destinationBookmark: Data?
    public var configuredAt: Date?
    public var encrypted: Bool?
    public var keyID: String?
    public var lastSuccessAt: Date?
    public var lastFailure: Failure?

    public init() {}

    public var isEncrypted: Bool { encrypted ?? false }
    public var isConfigured: Bool { destinationBookmark != nil }

    /// Due: configured, and the local calendar date of the last success differs from today's
    /// (or there is none). The recording condition is checked by the engine.
    public func isDue(now: Date, calendar: Calendar) -> Bool {
        guard isConfigured else { return false }
        guard let last = lastSuccessAt else { return true }
        return !calendar.isDate(last, inSameDayAs: now)
    }

    public static let staleAfter: TimeInterval = 7 * 86_400

    /// The Backup tab's warning line, or nil while backups are recent enough (or not configured).
    public func staleLine(now: Date) -> String? {
        guard isConfigured else { return nil }
        let head: String
        if let last = lastSuccessAt {
            let age = abs(now.timeIntervalSince(last))
            guard age >= Self.staleAfter else { return nil }
            head = "Last backup \(Int(age / 86_400)) days ago"
        } else {
            guard let configuredAt, now.timeIntervalSince(configuredAt) >= Self.staleAfter
            else { return nil }
            head = "No backup yet"
        }
        guard let reason = lastFailure?.reason else { return head }
        return "\(head) — \(reason.statusText)"
    }
}

/// `manifest.json` of a snapshot.
public struct BackupManifest: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public struct DataFile: Codable, Equatable, Sendable {
        public var file: String
        public var size: Int64
        public var sha256: String
    }

    public struct FileEntry: Codable, Equatable, Sendable {
        public var meeting: String
        public var name: String
        public var size: Int64
        public var mtime: Double
        public var sha256: String
        public var stored: String
        public var storedSize: Int64
    }

    public var format: Int
    public var createdAt: Date
    public var sourceName: String
    public var appVersion: String
    public var appBuild: String
    public var encrypted: Bool
    public var keyID: String?
    public var data: DataFile
    public var meetingCount: Int
    public var files: [FileEntry]

    public enum DecodeError: Error { case unknownFormat, duplicateEntry }

    /// Refuses an unknown `format` and duplicate `(meeting, name)` pairs (a damaged manifest).
    public static func decode(_ data: Data) throws -> BackupManifest {
        let manifest = try BackupJSON.decoder.decode(BackupManifest.self, from: data)
        guard manifest.format <= currentFormat else { throw DecodeError.unknownFormat }
        var seen = Set<String>()
        for entry in manifest.files {
            guard seen.insert(entry.meeting + "/" + entry.name).inserted else {
                throw DecodeError.duplicateEntry
            }
        }
        return manifest
    }

    public func encoded() throws -> Data { try BackupJSON.encoder.encode(self) }
}

enum BackupJSON {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// The meeting-folder names a backup copies and a restore accepts.
public enum BackupAllowlist {
    public static let fixedNames: Set<String> = [
        "import.wav", "diarization.json", "capture_facts.json", "room_treatment.json",
    ]

    /// `audio*.m4a`, `capture_*.caf`, the fixed names, or `handoff/<64 lowercase hex>.json`;
    /// each `*` is zero or more ASCII letters, digits or `_`.
    public static func isMeetingFileName(_ name: String) -> Bool {
        if fixedNames.contains(name) { return true }
        if let hash = middle(name, prefix: "handoff/", suffix: ".json") {
            return MeetingPaths.isValidVersionHash(hash)
        }
        if let star = middle(name, prefix: "audio", suffix: ".m4a") ?? middle(name, prefix: "capture_", suffix: ".caf") {
            return star.utf8.allSatisfy { $0 == UInt8(ascii: "_") || (0x30...0x39).contains($0)
                || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }
        }
        return false
    }

    private static func middle(_ name: String, prefix: String, suffix: String) -> String? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix),
            name.utf8.count >= prefix.utf8.count + suffix.utf8.count
        else { return nil }
        return String(name.dropFirst(prefix.count).dropLast(suffix.count))
    }
}

/// Snapshot folder names: `yyyy-MM-ddTHH-mm-ssZ-<8 hex>` in UTC.
public enum BackupSnapshotName {
    private static var formatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return f
    }

    public static func make(_ date: Date) -> String {
        formatter.string(from: date) + "-" + randomHex(8)
    }

    /// The UTC time of a complete snapshot's name; nil for anything else.
    public static func date(of name: String) -> Date? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard name.utf8.count == 29, parts.count == 6, isLowerHex(parts[5]), parts[5].count == 8
        else { return nil }
        return formatter.date(from: String(name.prefix(20)))
    }

    static func randomHex(_ count: Int) -> String {
        String((0..<count).map { _ in "0123456789abcdef".randomElement()! })
    }

    private static func isLowerHex(_ s: Substring) -> Bool {
        s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// 7 daily / 5 weekly / 12 monthly retention over complete snapshot names.
public enum BackupRetention {
    public static func kept(_ names: [String], now: Date, timeZone: TimeZone) -> Set<String> {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        let dated = names.compactMap { name in BackupSnapshotName.date(of: name).map { (name, $0) } }
        var keep = Set(dated.filter { $0.1 > now }.map(\.0))
        let past = dated.filter { $0.1 <= now }.sorted { $0.1 > $1.1 }
        if let newest = past.first { keep.insert(newest.0) }

        func bucket(_ count: Int, _ key: (Date) -> [Int]) {
            var seen: [[Int]] = []
            for (name, date) in past {
                let k = key(date)
                guard !seen.contains(k) else { continue }
                guard seen.count < count else { return }
                seen.append(k)
                keep.insert(name)
            }
        }
        bucket(7) { let c = calendar.dateComponents([.year, .month, .day], from: $0); return [c.year!, c.month!, c.day!] }
        bucket(5) { let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: $0); return [c.yearForWeekOfYear!, c.weekOfYear!] }
        bucket(12) { let c = calendar.dateComponents([.year, .month], from: $0); return [c.year!, c.month!] }
        return keep
    }
}
