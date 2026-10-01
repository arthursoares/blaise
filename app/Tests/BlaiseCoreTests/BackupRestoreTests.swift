import AppleArchive
import CryptoKit
import Foundation
import GRDB
import Synchronization
import System
import Testing
@testable import BlaiseCore

// Backup restore (slice 2): fictional DemoSeeder libraries plus synthetic Vexatron Labs meetings
// and synthetic meeting-file bytes, in throwaway data roots and destinations.

private let restoreInstallID = "fedcba9876543210"
private let utcZone = TimeZone(identifier: "UTC")!
private let armDate = Date(timeIntervalSince1970: 1_780_000_000)
private let setAsideName = "Set Aside Before Restore 2026-05-28 20-26-40"
private var fm: FileManager { .default }

private func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func bytes(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: 0...255) })
}

// MARK: - Library state

/// What TP1 compares: a canonical hash per table, the archive items' bytes, the meeting files' bytes.
struct LibraryState: Equatable {
    var tables: [String: String]
    var items: [String: String]
    var files: [String: String]
}

private let archiveItems = ["Glossary.md", "stoplist_user.txt", "voice_profile/profile.json", "voice_profile/candidates.json"]

/// SHA-256 of `SELECT * ORDER BY rowid` for every table, minus `grdb_migrations` and FTS shadow tables.
func tableHashes(_ db: Database) throws -> [String: String] {
    let tables = try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'table'")
    let virtual = tables.compactMap { row -> String? in
        let sql: String = row["sql"] ?? ""
        return sql.uppercased().hasPrefix("CREATE VIRTUAL TABLE") ? row["name"] : nil
    }
    var out: [String: String] = [:]
    for table in tables {
        let name: String = table["name"]
        if name == "grdb_migrations" || virtual.contains(where: { name.hasPrefix($0 + "_") }) { continue }
        var hasher = SHA256()
        for row in try Row.fetchAll(db, sql: "SELECT * FROM \"\(name)\" ORDER BY rowid") {
            let line = row.map { column, value -> String in
                switch value.storage {
                case .null: return "\(column)=N"
                case .int64(let i): return "\(column)=i\(i)"
                case .double(let d): return "\(column)=d\(d.bitPattern)"
                case .string(let s): return "\(column)=s\(s.utf8.count):\(s)"
                case .blob(let b): return "\(column)=b\(b.base64EncodedString())"
                }
            }.joined(separator: "|")
            hasher.update(data: Data((line + "\n").utf8))
        }
        out[name] = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    return out
}

func libraryState(_ database: BlaiseDatabase) async throws -> LibraryState {
    let tables = try await database.pool.read { try tableHashes($0) }
    return LibraryState(tables: tables, items: itemHashes(database.rootURL), files: meetingFileHashes(database.rootURL))
}

func itemHashes(_ root: URL) -> [String: String] {
    var out: [String: String] = [:]
    for item in archiveItems {
        if let data = try? Data(contentsOf: root.appendingPathComponent(item)) { out[item] = sha(data) }
    }
    return out
}

/// Allowlisted meeting files under valid-ULID folders, `meeting/name` → SHA-256.
func meetingFileHashes(_ root: URL) -> [String: String] {
    let meetings = root.appendingPathComponent("meetings")
    var out: [String: String] = [:]
    for m in (try? fm.contentsOfDirectory(atPath: meetings.path)) ?? [] where ULID.isValid(m) {
        let dir = meetings.appendingPathComponent(m)
        var names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        names += ((try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("handoff").path)) ?? []).map { "handoff/" + $0 }
        for n in names where BackupAllowlist.isMeetingFileName(n) {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(n)) { out["\(m)/\(n)"] = sha(data) }
        }
    }
    return out
}

/// Every regular file under `root` (links noted, never followed), relative path → SHA-256.
func inventory(_ root: URL, skipping: [String] = []) throws -> [String: String] {
    var out: [String: String] = [:]
    func walk(_ dir: URL, _ rel: String) throws {
        for name in try fm.contentsOfDirectory(atPath: dir.path) {
            let path = rel.isEmpty ? name : rel + "/" + name
            if skipping.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            let url = dir.appendingPathComponent(name)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: try walk(url, path)
            case S_IFREG: out[path] = sha(try Data(contentsOf: url))
            default: out[path] = "link"
            }
        }
    }
    try walk(root, "")
    return out
}

func readOnlyTables(_ path: URL) throws -> [String: String] {
    var config = Configuration()
    config.readonly = true
    let queue = try DatabaseQueue(path: path.path, configuration: config)
    defer { try? queue.close() }
    return try queue.read { try tableHashes($0) }
}

// MARK: - Fixtures

/// A seeded fictional library (BackupHarness's seed plus optional synthetic meetings), closed and
/// reopened so the startup sweeps have run, with its own engine.
final class RestoreLibrary: @unchecked Sendable {
    let root: URL
    let secrets: InMemorySecretStore
    let recording = Locked(false)
    let log = Locked<[RestoreFileOp]>([])
    private(set) var database: BlaiseDatabase
    private(set) var engine: BackupEngine
    private let harness: BackupHarness

    /// The synthetic meetings added on top of DemoSeeder's, in creation order.
    private(set) var synthetic: [MeetingID] = []

    init(syntheticMeetings: Int = 0, secrets: InMemorySecretStore = InMemorySecretStore()) async throws {
        harness = try await BackupHarness()
        root = harness.root
        self.secrets = secrets
        let meetings = MeetingRepository(database: harness.database)
        let transcripts = TranscriptRepository(database: harness.database)
        let words = ["Vexatron", "Quoll", "Harbor", "prototype", "sprint", "render", "lighthouse", "kelp"]
        for i in 0..<syntheticMeetings {
            let id = ULID.generate()
            let started = Date(timeIntervalSince1970: 1_760_000_000 + Double(i) * 86_400)
            try await meetings.create(makeMeeting(
                id: id, title: "Vexatron Labs sync \(i)", startedAt: started, status: .ready,
                attendees: [Attendee(name: "Quinn Harbor", source: .manual)]))
            try await transcripts.replaceAllSegments(meetingID: id, with: (0..<6).map { n in
                TranscriptSegment(
                    meetingID: id, ord: n, startSeconds: Double(n) * 10, endSeconds: Double(n) * 10 + 8,
                    speakerLabel: "S\(n % 2)", text: (0..<12).map { words[($0 + n + i) % words.count] }.joined(separator: " "))
            })
            if i % 10 != 9 { try harness.writeMeetingFiles(id, variant: i) }
            synthetic.append(id)
        }
        let settings = SettingsStore(database: harness.database)
        try await settings.set("fixture.harborName", to: "Quoll Harbor")
        try await settings.set("fixture.sprintLength", to: 14)
        try harness.database.pool.close()
        database = try BlaiseDatabase(rootURL: harness.root)
        engine = Self.makeEngine(database, secrets, recording)
    }

    private static func makeEngine(_ database: BlaiseDatabase, _ secrets: SecretStore, _ recording: Locked<Bool>) -> BackupEngine {
        BackupEngine(
            database: database, secrets: secrets, isRecording: { recording.m.withLock { $0 } },
            timeZone: { utcZone }, installID: restoreInstallID)
    }

    func writeMeetingFiles(_ id: MeetingID, variant: Int) throws { try harness.writeMeetingFiles(id, variant: variant) }

    func close() throws { try database.pool.close() }

    func reopen() throws {
        database = try BlaiseDatabase(rootURL: root)
        engine = Self.makeEngine(database, secrets, recording)
    }

    func meetingIDs() async throws -> [MeetingID] {
        try await database.pool.read { try String.fetchAll($0, sql: "SELECT id FROM meeting ORDER BY id") }
    }

    /// Backs the library up to a new destination; the one complete snapshot there.
    func backUp(encrypted: Bool = false) async throws -> (dest: URL, snapshot: RestoreSnapshot) {
        let dest = try makeTempRoot()
        if encrypted { try await engine.enableEncryption(password: BackupEngine.generatePassword()) }
        #expect(try await engine.chooseFolder(dest) == .succeeded)
        let rows = await engine.restoreSnapshots(in: dest)
        #expect(rows.count == 1)
        return (dest, try #require(rows.first))
    }

    func stage(_ snapshot: RestoreSnapshot, password: String? = nil) async -> RestoreStageOutcome {
        await engine.stageRestore(snapshot, password: password, hook: { [log] op in log.m.withLock { $0.append(op) } })
    }

    /// A copy of this (closed) library's root.
    func copyRoot() throws -> URL {
        let copy = try makeTempRoot().appendingPathComponent("Blaise")
        try fm.copyItem(at: root, to: copy)
        return copy
    }
}

/// A library copy to restore into, with an engine whose file hook logs every restore operation.
final class RestoreTarget: @unchecked Sendable {
    let root: URL
    let database: BlaiseDatabase
    let engine: BackupEngine
    let recording = Locked(false)
    let recordingChecks = Locked(0)
    let log = Locked<[RestoreFileOp]>([])

    init(root: URL, secrets: SecretStore = InMemorySecretStore(), recordingAfterChecks: Int? = nil) throws {
        self.root = root
        database = try BlaiseDatabase(rootURL: root)
        let recording = self.recording, checks = recordingChecks
        engine = BackupEngine(
            database: database, secrets: secrets,
            isRecording: {
                let n = checks.m.withLock { $0 += 1; return $0 }
                if let after = recordingAfterChecks, n > after { return true }
                return recording.m.withLock { $0 }
            },
            timeZone: { utcZone }, installID: restoreInstallID)
    }

    func stage(
        _ snapshot: RestoreSnapshot, password: String? = nil, also: RestoreFileHook? = nil
    ) async -> RestoreStageOutcome {
        await engine.stageRestore(snapshot, password: password, hook: { [log] op in
            log.m.withLock { $0.append(op) }
            try also?(op)
        })
    }

    var ops: [RestoreFileOp] { log.m.withLock { $0 } }

    var staging: URL { root.appendingPathComponent(".restore-staging") }
}

private func staged(_ outcome: RestoreStageOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> StagedRestore {
    guard case .staged(let s) = outcome else {
        Issue.record("expected staged, got \(outcome)", sourceLocation: sourceLocation)
        throw TestFailure()
    }
    return s
}

// MARK: - Crafted snapshots

struct CraftedEntry {
    var path: String
    var type: ArchiveHeader.EntryType = .regularFile
    var data: Data?
}

private func key(_ s: String) -> ArchiveHeader.FieldKey { ArchiveHeader.FieldKey(s) }

func writeArchive(_ entries: [CraftedEntry], to url: URL) throws {
    let out = try #require(ArchiveByteStream.fileStream(
        path: FilePath(url.path), mode: .writeOnly, options: [.create, .truncate],
        permissions: FilePermissions(rawValue: 0o644)))
    let compressed = try #require(ArchiveByteStream.compressionStream(using: .lzfse, writingTo: out))
    let encoder = try #require(ArchiveStream.encodeStream(writingTo: compressed))
    for entry in entries {
        let header = ArchiveHeader()
        header.append(.uint(key: key("TYP"), value: UInt64(entry.type.rawValue)))
        header.append(.string(key: key("PAT"), value: entry.path))
        if let data = entry.data { header.append(.blob(key: key("DAT"), size: UInt64(data.count))) }
        try encoder.writeHeader(header)
        if let data = entry.data, !data.isEmpty {
            try data.withUnsafeBytes { try encoder.writeBlob(key: key("DAT"), from: $0) }
        }
    }
    try encoder.close()
    try compressed.close()
    try out.close()
}

/// A complete plaintext snapshot written by hand into `install`.
func craftSnapshot(
    install: URL, entries: [CraftedEntry], files: [BackupManifest.FileEntry] = [],
    edit: (inout BackupManifest) -> Void = { _ in }
) throws -> RestoreSnapshot {
    let folder = install.appendingPathComponent("snapshots/\(BackupSnapshotName.make(armDate))")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let archive = folder.appendingPathComponent("data.aar")
    try writeArchive(entries, to: archive)
    let data = try Data(contentsOf: archive)
    var manifest = BackupManifest(
        format: 1, createdAt: armDate, sourceName: "Quoll Harbor iMac", appVersion: "1.9.2", appBuild: "1",
        encrypted: false, keyID: nil, data: .init(file: "data.aar", size: Int64(data.count), sha256: sha(data)),
        meetingCount: 0, files: files)
    edit(&manifest)
    try BackupJSON.encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
    return RestoreSnapshot(folder: folder, manifest: manifest)
}

/// Stores `data` as a plaintext store file of `install` and returns its manifest entry.
func storeFile(install: URL, meeting: String, name: String, data: Data) throws -> BackupManifest.FileEntry {
    let digest = sha(data)
    let base = String(name.split(separator: "/").last!)
    let stored = "files/\(meeting)/\(digest.prefix(16))-\(base)"
    let url = install.appendingPathComponent(stored)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return .init(
        meeting: meeting, name: name, size: Int64(data.count), mtime: 0, sha256: digest,
        stored: stored, storedSize: Int64(data.count))
}

/// The bytes of a standalone SQLite file built by `build`, closed.
func databaseFile(wal: Bool = false, _ build: (any DatabaseWriter) throws -> Void) throws -> Data {
    let path = try makeTempRoot().appendingPathComponent("crafted.sqlite").path
    if wal {
        let pool = try DatabasePool(path: path)
        try build(pool)
        try pool.close()
    } else {
        let queue = try DatabaseQueue(path: path)
        try build(queue)
        try queue.close()
    }
    return try Data(contentsOf: URL(fileURLWithPath: path))
}

/// A copy of a live library's database, edited, in DELETE mode (or left in WAL mode).
func databaseCopy(
    _ database: BlaiseDatabase, wal: Bool = false, _ edit: (Database) throws -> Void = { _ in }
) throws -> Data {
    try databaseFile(wal: wal) { writer in
        try database.pool.backup(to: writer)
        try writer.write(edit)
        if !wal { _ = try writer.writeWithoutTransaction { try String.fetchOne($0, sql: "PRAGMA journal_mode=DELETE") } }
    }
}

// MARK: - TP1 Restore round-trip

@Suite(.serialized) struct BackupRestoreRoundTripTests {
    @Test(arguments: [true, false]) func restoreRoundTrip(stoplistInSnapshot: Bool) async throws {
        // 1. Fixture: DemoSeeder + 100 synthetic meetings, settings, glossary, voice print, files, a row-less folder.
        let lib = try await RestoreLibrary(syntheticMeetings: 100)
        let stoplist = lib.root.appendingPathComponent("stoplist_user.txt")
        if !stoplistInSnapshot {
            try fm.removeItem(at: stoplist)
            try lib.close()
            try lib.reopen()
        }
        #expect(try await lib.meetingIDs().count >= 100)

        // 2. E1, plaintext backup to D; E2, encryption on, backup to D2.
        let e1 = try await libraryState(lib.database)
        let (_, snapshotD) = try await lib.backUp()
        let e2 = try await libraryState(lib.database)
        let (_, snapshotD2) = try await lib.backUp(encrypted: true)
        #expect(snapshotD2.manifest?.encrypted == true && snapshotD.manifest?.encrypted == false)

        // 3. Mutate.
        let removed = Array(lib.synthetic.prefix(3))
        for id in removed {
            let tombstone = try await MeetingDeletion.eraseAndTombstone(database: lib.database, meetingID: id)
            await MeetingDeletion.removeDirAndClear(database: lib.database, tombstone: tombstone)
        }
        let meetings = MeetingRepository(database: lib.database)
        for i in 0..<5 {
            let id = ULID.generate()
            try await meetings.create(makeMeeting(id: id, title: "Quoll Harbor review \(i)", status: .ready))
            try lib.writeMeetingFiles(id, variant: i)
        }
        let settings = SettingsStore(database: lib.database)
        try await settings.set("fixture.harborName", to: "Quoll Harbor East")
        try await settings.set("fixture.added", to: true)
        try Data("# Glossary\n- Vexatron Labs\n- Kelp Lighthouse\n".utf8).write(to: lib.root.appendingPathComponent("Glossary.md"))
        if stoplistInSnapshot { try fm.removeItem(at: stoplist) } else { try Data("harbor\n".utf8).write(to: stoplist) }
        let rewritten = lib.synthetic[10]
        try bytes(3_000).write(to: lib.root.appendingPathComponent("meetings/\(rewritten)/diarization.json"))
        try lib.close()

        // 4-6. For each destination, on its own copy of the mutated library.
        for (snapshot, expected) in [(snapshotD, e1), (snapshotD2, e2)] {
            let copy = try lib.copyRoot()
            let target = try RestoreTarget(root: copy, secrets: lib.secrets)
            let p = try await libraryState(target.database)
            let restore = try staged(await target.stage(snapshot))
            #expect(restore.damagedCount == 0)
            #expect(restore.items == (stoplistInSnapshot
                ? ["blaise.sqlite", "Glossary.md", "stoplist_user.txt", "voice_profile"]
                : ["blaise.sqlite", "Glossary.md", "voice_profile"]))
            try target.database.pool.close()
            let before = try inventory(copy, skipping: [".restore-staging"])

            try BackupRestore.arm(restore, dataRoot: copy, now: armDate, timeZone: utcZone)
            try BackupRestore.applyPendingRestore(dataRoot: copy)
            #expect(!fm.fileExists(atPath: target.staging.path))

            // Nothing under R′ was deleted: each file is where it was, or in the set-aside folder.
            let after = try inventory(copy)
            for (path, digest) in before {
                if path.hasPrefix("meetings/") {
                    #expect(after[path] == digest, "meeting file changed: \(path)")
                } else {
                    #expect(after[path] == digest || after["\(setAsideName)/\(path)"] == digest, "lost: \(path)")
                }
            }
            #expect(try readOnlyTables(copy.appendingPathComponent("\(setAsideName)/blaise.sqlite")) == p.tables)

            let reopened = try BlaiseDatabase(rootURL: copy)
            let restored = try await libraryState(reopened)
            #expect(restored.tables == expected.tables)
            #expect(restored.items == expected.items)
            for (file, digest) in expected.files where p.files[file] == nil {
                #expect(restored.files[file] == digest, "not restored: \(file)")
            }
            #expect(expected.files.keys.contains { $0.hasPrefix(removed[0]) })
            for (file, digest) in p.files { #expect(restored.files[file] == digest, "changed: \(file)") }
            try reopened.pool.close()

            // The help text's undo, literally.
            let kept = copy.appendingPathComponent("Kept After Restore")
            try fm.createDirectory(at: kept, withIntermediateDirectories: false)
            for name in ["blaise.sqlite", "blaise.sqlite-wal", "blaise.sqlite-shm", "Glossary.md", "stoplist_user.txt", "voice_profile"]
            where fm.fileExists(atPath: copy.appendingPathComponent(name).path) {
                try fm.moveItem(at: copy.appendingPathComponent(name), to: kept.appendingPathComponent(name))
            }
            let setAside = copy.appendingPathComponent(setAsideName)
            for name in try fm.contentsOfDirectory(atPath: setAside.path) {
                try fm.moveItem(at: setAside.appendingPathComponent(name), to: copy.appendingPathComponent(name))
            }
            let undone = try BlaiseDatabase(rootURL: copy)
            let u = try await libraryState(undone)
            #expect(u.tables == p.tables)
            #expect(u.items == p.items)
            try undone.pool.close()
        }
    }
}

// MARK: - TP2 / TP3 Schema

@Suite struct BackupRestoreSchemaTests {
    /// A small target library and a crafted snapshot folder beside it.
    private func target() async throws -> (RestoreTarget, URL) {
        let root = try makeTempRoot()
        let db = try BlaiseDatabase(rootURL: root)
        try await DemoSeeder.seed(database: db, now: armDate)
        try db.pool.close()
        return (try RestoreTarget(root: root), try makeTempRoot().appendingPathComponent("Blaise Backups/\(restoreInstallID)"))
    }

    private func expectRefusedUnchanged(
        _ target: RestoreTarget, _ snapshot: RestoreSnapshot, message: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try target.database.pool.close()
        let before = try inventory(target.root)
        let outcome = await target.stage(snapshot)
        #expect(outcome == .refused(message), sourceLocation: sourceLocation)
        #expect(try inventory(target.root) == before, sourceLocation: sourceLocation)
        #expect(!fm.fileExists(atPath: target.staging.path), sourceLocation: sourceLocation)
        try BackupRestore.applyPendingRestore(dataRoot: target.root)
        #expect(try inventory(target.root) == before, sourceLocation: sourceLocation)
    }

    @Test func newerSchemaIsRefused() async throws {
        let (target, install) = try await target()
        let db = try databaseFile {
            try BlaiseDatabase.migrator.migrate($0)
            try $0.write { try $0.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999')") }
        }
        let snapshot = try craftSnapshot(install: install, entries: [.init(path: "blaise.sqlite", data: db)]) {
            $0.appVersion = "7.3.0"
        }
        try await expectRefusedUnchanged(target, snapshot, message: BackupRestore.newerVersionMessage("7.3.0"))
        #expect(BackupRestore.newerVersionMessage("7.3.0")
            == "This backup was made by a newer version of Blaise (7.3.0). Update Blaise, then restore it.")
    }

    /// A database that opens, reads and migrates fine but whose index no longer matches its table.
    /// The corruption sits in an object a fresh migration creates, so only `integrity_check`
    /// refuses it.
    @Test func damagedDatabaseIsRefused() async throws {
        let (target, install) = try await target()
        let marker = Data("vexatron labs kelp ledger".utf8)
        var db = try databaseFile {
            try BlaiseDatabase.migrator.migrate($0)
            try $0.write {
                try $0.execute(
                    sql: """
                        INSERT INTO name_correction (id, misheard_folded, replacement, everyday, created_at)
                        VALUES (?, ?, 'Quoll Harbor', 0, '2026-01-05 10:00:00.000')
                        """,
                    arguments: [ULID.generate(), String(decoding: marker, as: UTF8.self)])
            }
        }
        // One copy in the table's B-tree, one in the index's.
        let first = try #require(db.range(of: marker))
        #expect(db[first.upperBound...].range(of: marker) != nil)
        db[first.upperBound - 1] ^= 0x01
        let snapshot = try craftSnapshot(install: install, entries: [.init(path: "blaise.sqlite", data: db)])
        try await expectRefusedUnchanged(target, snapshot, message: BackupRestore.damagedMessage)
    }

    @Test func failingMigrationIsRefusedAndLeavesNoCopy() async throws {
        let (target, install) = try await target()
        let db = try databaseFile {
            try BlaiseDatabase.migrator.migrate($0, upTo: "v10")
            try $0.write { try $0.execute(sql: "CREATE TABLE meeting_tombstone (id TEXT)") }
        }
        let snapshot = try craftSnapshot(install: install, entries: [.init(path: "blaise.sqlite", data: db)])
        target.log.m.withLock { $0 = [] }
        try await expectRefusedUnchanged(target, snapshot, message: BackupRestore.migrateFailedMessage)
        let copies = target.log.m.withLock { $0 }.filter {
            if case .write(let p) = $0 { return p.hasSuffix("migrate-check.sqlite") }
            return false
        }
        #expect(copies.count == 1)
    }

    @Test func migrateCheckRunsOnACopyAndIsDeleted() async throws {
        let (target, install) = try await target()
        let db = try databaseFile { try BlaiseDatabase.migrator.migrate($0, upTo: "v10") }
        let snapshot = try craftSnapshot(install: install, entries: [.init(path: "blaise.sqlite", data: db)])
        _ = try staged(await target.stage(snapshot))
        let names = try fm.contentsOfDirectory(atPath: target.staging.path)
        #expect(!names.contains { $0.hasPrefix("migrate-check") })
        // The staged file itself is not migrated.
        let staged = try DatabaseQueue(path: target.staging.appendingPathComponent("blaise.sqlite").path)
        let applied = try await staged.read { try BlaiseDatabase.migrator.appliedIdentifiers($0) }
        try staged.close()
        #expect(applied.count == 10)
    }

    @Test func failedMigrateCheckCleanupFailsStaging() async throws {
        let (target, install) = try await target()
        let db = try databaseFile { try BlaiseDatabase.migrator.migrate($0, upTo: "v10") }
        let snapshot = try craftSnapshot(install: install, entries: [.init(path: "blaise.sqlite", data: db)])
        let copy = target.staging.appendingPathComponent("migrate-check.sqlite").path
        let outcome = await target.stage(snapshot, also: { op in
            if op == .delete(copy) { throw TestFailure() }
        })
        guard case .refused(let message) = outcome else {
            Issue.record("expected refused, got \(outcome)")
            return
        }
        #expect(message.hasPrefix("The restore could not be prepared: "))
        #expect(!fm.fileExists(atPath: target.staging.path))
    }

    /// v17 predates the rebuild of `meeting` but already holds the notes search triggers, whose
    /// SQL text the schema check compares.
    @Test(arguments: ["v10", "v17"]) func olderSchemaRestoresAndMigratesAtOpen(version: String) async throws {
        let (target, install) = try await target()
        let meetingID = ULID.generate()
        let db = try databaseFile {
            try BlaiseDatabase.migrator.migrate($0, upTo: version)
            try $0.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO meeting (id, title, started_at, source, status, attendees, created_at, updated_at)
                        VALUES (?, 'Kelp Lighthouse retro', '2026-01-05 10:00:00.000', 'meet', 'ready', '[]',
                                '2026-01-05 10:00:00.000', '2026-01-05 11:00:00.000')
                        """, arguments: [meetingID])
            }
        }
        let probe = try makeTempRoot().appendingPathComponent("\(version).sqlite")
        try db.write(to: probe)
        let probeQueue = try DatabaseQueue(path: probe.path)
        #expect(try await probeQueue.read { try $0.tableExists("meeting_tombstone") } == (version != "v10"))
        try probeQueue.close()
        let snapshot = try craftSnapshot(install: install, entries: [.init(path: "blaise.sqlite", data: db)])
        let restore = try staged(await target.stage(snapshot))
        try target.database.pool.close()
        try BackupRestore.arm(restore, dataRoot: target.root, now: armDate, timeZone: utcZone)
        try BackupRestore.applyPendingRestore(dataRoot: target.root)
        let reopened = try BlaiseDatabase(rootURL: target.root)
        let (applied, titles) = try await reopened.pool.read { db in
            (try BlaiseDatabase.migrator.appliedIdentifiers(db),
             try String.fetchAll(db, sql: "SELECT title FROM meeting WHERE id = ?", arguments: [meetingID]))
        }
        #expect(Set(applied) == Set(BlaiseDatabase.migrator.migrations))
        #expect(titles == ["Kelp Lighthouse retro"])
        #expect(try await reopened.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meeting") } == 1)
    }
}

// MARK: - TP5 Swap crash-convergence

/// An armed restore in a copy of `lib`: some meeting files missing, a changed glossary, the
/// database files replaced by a crash image with a non-empty stale `-wal`.
private struct ArmedTemplate {
    let root: URL
    let setAside: String
    let before: [String: String]
    let beforeFiles: [String: String]
}

private func armedTemplate(
    _ lib: RestoreLibrary, _ snapshot: RestoreSnapshot, preexistingSetAside: Bool = false
) async throws -> ArmedTemplate {
    let root = try lib.copyRoot()
    let meetings = root.appendingPathComponent("meetings")
    let ids = (try fm.contentsOfDirectory(atPath: meetings.path)).filter(ULID.isValid).sorted()
    try fm.removeItem(at: meetings.appendingPathComponent(ids[0]))
    try fm.removeItem(at: meetings.appendingPathComponent("\(ids[1])/audio.m4a"))
    try fm.removeItem(at: meetings.appendingPathComponent("\(ids[2])/handoff"))
    try Data("# Glossary\n- Kelp Lighthouse\n".utf8).write(to: root.appendingPathComponent("Glossary.md"))

    let target = try RestoreTarget(root: root, secrets: lib.secrets)
    let restore = try staged(await target.stage(snapshot))

    // Crash image: the three database files copied while uncheckpointed commits sit in the WAL.
    for i in 0..<40 {
        try await SettingsStore(database: target.database).set("fixture.crash.\(i)", to: String(repeating: "q", count: 500))
    }
    let side = try makeTempRoot()
    for name in ["blaise.sqlite", "blaise.sqlite-wal", "blaise.sqlite-shm"] {
        try fm.copyItem(at: root.appendingPathComponent(name), to: side.appendingPathComponent(name))
    }
    try target.database.pool.close()
    for name in ["blaise.sqlite", "blaise.sqlite-wal", "blaise.sqlite-shm"] {
        try? fm.removeItem(at: root.appendingPathComponent(name))
        try fm.moveItem(at: side.appendingPathComponent(name), to: root.appendingPathComponent(name))
    }
    let walSize = try #require(try fm.attributesOfItem(atPath: root.appendingPathComponent("blaise.sqlite-wal").path)[.size] as? Int)
    #expect(walSize > 0)

    if preexistingSetAside {
        let taken = root.appendingPathComponent(setAsideName)
        try fm.createDirectory(at: taken, withIntermediateDirectories: false)
        try Data("kept".utf8).write(to: taken.appendingPathComponent("note.txt"))
    }
    let before = try inventory(root, skipping: [".restore-staging"])
    try BackupRestore.arm(restore, dataRoot: root, now: armDate, timeZone: utcZone)
    let marker = try BackupJSON.decoder.decode(
        BackupRestore.Marker.self, from: Data(contentsOf: root.appendingPathComponent(".restore-staging/restore.json")))
    #expect(marker.setAside == (preexistingSetAside ? setAsideName + " 2" : setAsideName))
    #expect(marker.items == restore.items)
    return ArmedTemplate(root: root, setAside: marker.setAside, before: before, beforeFiles: meetingFileHashes(root))
}

private func copyOf(_ root: URL) throws -> URL {
    let copy = try makeTempRoot().appendingPathComponent("Blaise")
    try fm.copyItem(at: root, to: copy)
    return copy
}

/// TP1's final state: the snapshot's database and items; its files where none were; nothing lost.
private func expectRestored(
    _ root: URL, _ template: ArmedTemplate, tables: [String: String], items: [String: String],
    files: [String: String], sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let after = try inventory(root)
    for (path, digest) in template.before {
        let kept = path.hasPrefix("meetings/") || path.hasPrefix(setAsideName)
            ? after[path] == digest : (after[path] == digest || after["\(template.setAside)/\(path)"] == digest)
        #expect(kept, "lost: \(path)", sourceLocation: sourceLocation)
    }
    #expect(!fm.fileExists(atPath: root.appendingPathComponent(".restore-staging").path), sourceLocation: sourceLocation)
    let database = try BlaiseDatabase(rootURL: root)
    defer { try? database.pool.close() }
    let state = try await libraryState(database)
    #expect(state.tables == tables, sourceLocation: sourceLocation)
    #expect(state.items == items, sourceLocation: sourceLocation)
    for (file, digest) in files {
        #expect(state.files[file] == (template.beforeFiles[file] ?? digest), "\(file)", sourceLocation: sourceLocation)
    }
    for (file, digest) in template.beforeFiles { #expect(state.files[file] == digest, sourceLocation: sourceLocation) }
}

private func manifestFiles(_ snapshot: RestoreSnapshot) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (snapshot.manifest?.files ?? []).map { ("\($0.meeting)/\($0.name)", $0.sha256) })
}

/// Every folder that received an entry (a move into it or a new folder in it) is flushed after
/// that and before any delete, across a crashed run and the run that resumes it.
private func expectFlushedBeforeDeletes(
    _ runs: [[RestoreFileOp]], _ label: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    var owed = Set<String>()
    for op in runs.joined() {
        switch op {
        case .move(_, let to): owed.insert((to as NSString).deletingLastPathComponent)
        case .makeDirectory(let path): owed.insert((path as NSString).deletingLastPathComponent)
        case .flush(let path): owed.remove(path)
        case .delete(let path):
            guard owed.isEmpty else {
                Issue.record("\(label): \(path) deleted before flushing \(owed.sorted())", sourceLocation: sourceLocation)
                return
            }
        default: break
        }
    }
}

@Suite(.serialized) struct BackupRestoreSwapTests {
    @Test func swapConvergesFromEveryCrashPoint() async throws {
        let lib = try await RestoreLibrary()
        let e = try await libraryState(lib.database)
        let (_, full) = try await lib.backUp()

        let stoplist = lib.root.appendingPathComponent("stoplist_user.txt")
        let voice = lib.root.appendingPathComponent("voice_profile")
        let side = try makeTempRoot()
        try fm.moveItem(at: stoplist, to: side.appendingPathComponent("stoplist_user.txt"))
        try fm.moveItem(at: voice, to: side.appendingPathComponent("voice_profile"))
        let bareItems = itemHashes(lib.root)
        let (_, bare) = try await lib.backUp()
        try fm.moveItem(at: side.appendingPathComponent("stoplist_user.txt"), to: stoplist)
        try fm.moveItem(at: side.appendingPathComponent("voice_profile"), to: voice)

        let glossary = Data("# Glossary\n- Quoll Harbor\n".utf8)
        let profile = Data("{\"v\":2}".utf8)
        let craftedInstall = try makeTempRoot().appendingPathComponent("Blaise Backups/\(restoreInstallID)")
        let noDirectoryEntry = try craftSnapshot(install: craftedInstall, entries: [
            .init(path: "blaise.sqlite", data: try databaseCopy(lib.database)),
            .init(path: "Glossary.md", data: glossary),
            .init(path: "voice_profile/profile.json", data: profile),
        ])
        try lib.close()

        let variants: [(RestoreSnapshot, [String: String], Bool)] = [
            (full, e.items, true),
            (bare, bareItems, false),
            (noDirectoryEntry, ["Glossary.md": sha(glossary), "voice_profile/profile.json": sha(profile)], false),
        ]
        for (snapshot, items, preexisting) in variants {
            let template = try await armedTemplate(lib, snapshot, preexistingSetAside: preexisting)

            let reference = try copyOf(template.root)
            let log = Locked<[RestoreFileOp]>([])
            try BackupRestore.applyPendingRestore(dataRoot: reference, hook: { op in log.m.withLock { $0.append(op) } })
            let ops = log.m.withLock { $0 }
            let expected = try inventory(reference)
            try await expectRestored(reference, template, tables: e.tables, items: items, files: manifestFiles(snapshot))

            // Every flush comes before the first delete; the marker is deleted last, then its folder.
            let flushes = ops.indices.filter { if case .flush = ops[$0] { return true }; return false }
            let deletes = ops.compactMap { op -> String? in if case .delete(let p) = op { return p }; return nil }
            let firstDelete = try #require(ops.firstIndex { if case .delete = $0 { return true }; return false })
            #expect(flushes.allSatisfy { $0 < firstDelete })
            let staging = template.root.path.replacingOccurrences(of: template.root.path, with: reference.path) + "/.restore-staging"
            #expect(deletes.suffix(2) == [staging + "/restore.json", staging])
            expectFlushedBeforeDeletes([ops], "uncrashed")

            #expect(ops.count > 10)
            print("TP5| \(snapshot.name): \(ops.count) crash points")
            for k in 0..<ops.count {
                let run = try copyOf(template.root)
                let count = Locked(0)
                let crashed = Locked<[RestoreFileOp]>([]), resumed = Locked<[RestoreFileOp]>([])
                #expect(throws: TestFailure.self) {
                    try BackupRestore.applyPendingRestore(dataRoot: run, hook: { op in
                        if count.m.withLock({ $0 += 1; return $0 }) == k + 1 { throw TestFailure() }
                        crashed.m.withLock { $0.append(op) }
                    })
                }
                try BackupRestore.applyPendingRestore(dataRoot: run, hook: { op in resumed.m.withLock { $0.append(op) } })
                #expect(try inventory(run) == expected, "crash before op \(k): \(ops[k])")
                expectFlushedBeforeDeletes(
                    [crashed.m.withLock { $0 }, resumed.m.withLock { $0 }], "crash before op \(k): \(ops[k])")
            }
        }
    }

    @Test func stagedButUnconfirmedNeverSwaps() async throws {
        let lib = try await RestoreLibrary()
        let (_, snapshot) = try await lib.backUp()
        try lib.close()
        let root = try lib.copyRoot()
        try fm.removeItem(at: root.appendingPathComponent("stoplist_user.txt"))
        let target = try RestoreTarget(root: root, secrets: lib.secrets)
        _ = try staged(await target.stage(snapshot))
        try target.database.pool.close()
        let before = try inventory(root, skipping: [".restore-staging"])
        try BackupRestore.applyPendingRestore(dataRoot: root)
        #expect(!fm.fileExists(atPath: target.staging.path))
        #expect(try inventory(root) == before)
    }

    @Test func noStagingCostsOneExistenceCheck() throws {
        let root = try makeTempRoot()
        let log = Locked<[RestoreFileOp]>([])
        try BackupRestore.applyPendingRestore(dataRoot: root, hook: { op in log.m.withLock { $0.append(op) } })
        #expect(log.m.withLock { $0 }.isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func unreadableMarkerFailsClosed() throws {
        let root = try makeTempRoot()
        let staging = root.appendingPathComponent(".restore-staging")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("{\"snapshot\": 1}".utf8).write(to: staging.appendingPathComponent("restore.json"))
        try Data("x".utf8).write(to: root.appendingPathComponent("blaise.sqlite"))
        #expect(throws: BackupRestoreError.invalidMarker) { try BackupRestore.applyPendingRestore(dataRoot: root) }
        let marker = BackupRestore.Marker(
            snapshot: "s", sourceName: "", createdAt: armDate, items: ["blaise.sqlite"], setAside: "../elsewhere")
        try BackupJSON.encoder.encode(marker).write(to: staging.appendingPathComponent("restore.json"))
        #expect(throws: BackupRestoreError.invalidMarker) { try BackupRestore.applyPendingRestore(dataRoot: root) }
        #expect(try Data(contentsOf: root.appendingPathComponent("blaise.sqlite")) == Data("x".utf8))
    }
}

// MARK: - Swap and staging under file-system faults

@Suite(.serialized) struct BackupRestoreFaultTests {
    /// An armed restore with staged meeting files, and the inventory an uninterrupted swap reaches.
    private func armed() async throws -> (root: URL, expected: [String: String], setAside: String) {
        let lib = try await RestoreLibrary()
        let (_, snapshot) = try await lib.backUp()
        try lib.close()
        let template = try await armedTemplate(lib, snapshot)
        let reference = try copyOf(template.root)
        try BackupRestore.applyPendingRestore(dataRoot: reference)
        return (template.root, try inventory(reference), template.setAside)
    }

    /// A marker that cannot be examined is not a missing marker; the fault clears before staging
    /// would be deleted.
    @Test func transientMarkerStatErrorKeepsTheRestore() async throws {
        let (root, expected, _) = try await armed()
        let staging = root.appendingPathComponent(".restore-staging")
        let before = try inventory(staging)
        chmod(staging.path, 0o600)
        #expect(throws: (any Error).self) {
            try BackupRestore.applyPendingRestore(dataRoot: root, hook: { op in
                if case .delete = op { chmod(staging.path, 0o755) }
            })
        }
        chmod(staging.path, 0o755)
        #expect(try inventory(staging) == before)
        try BackupRestore.applyPendingRestore(dataRoot: root)
        #expect(try inventory(root) == expected)
    }

    /// A staged meeting folder that cannot be listed is not an empty one; the fault clears before
    /// staging would be deleted.
    @Test func transientListingErrorKeepsTheStagedFiles() async throws {
        let (root, expected, _) = try await armed()
        let staging = root.appendingPathComponent(".restore-staging")
        let meetings = staging.appendingPathComponent("meetings")
        let name = try #require(try fm.contentsOfDirectory(atPath: meetings.path).sorted().first)
        let folder = meetings.appendingPathComponent(name)
        let before = try inventory(staging).filter { $0.key.hasPrefix("meetings/\(name)/") }
        #expect(!before.isEmpty)
        chmod(folder.path, 0o300)
        #expect(throws: (any Error).self) {
            try BackupRestore.applyPendingRestore(dataRoot: root, hook: { op in
                if case .flush = op { chmod(folder.path, 0o755) }
            })
        }
        chmod(folder.path, 0o755)
        #expect(fm.fileExists(atPath: staging.appendingPathComponent("restore.json").path))
        let after = try inventory(staging)
        for (path, digest) in before { #expect(after[path] == digest, "lost: \(path)") }
        try BackupRestore.applyPendingRestore(dataRoot: root)
        #expect(try inventory(root) == expected)
    }

    /// A name already in the set-aside folder fails the move into it; nothing is replaced.
    @Test func setAsideCollisionReplacesNothing() async throws {
        let (root, expected, setAside) = try await armed()
        let planted = root.appendingPathComponent("\(setAside)/Glossary.md")
        let plantedBytes = Data("# Glossary\n- Kelp Lighthouse, kept aside\n".utf8)
        try plantedBytes.write(to: planted)
        let current = try Data(contentsOf: root.appendingPathComponent("Glossary.md"))
        #expect(throws: Errno.fileExists) { try BackupRestore.applyPendingRestore(dataRoot: root) }
        #expect(try Data(contentsOf: planted) == plantedBytes)
        #expect(try Data(contentsOf: root.appendingPathComponent("Glossary.md")) == current)
        #expect(fm.fileExists(atPath: root.appendingPathComponent(".restore-staging/restore.json").path))
        try fm.removeItem(at: planted)
        try BackupRestore.applyPendingRestore(dataRoot: root)
        #expect(try inventory(root) == expected)
    }

    /// A meeting file that appears after the existence check fails the move; nothing is replaced,
    /// and the resumed swap keeps it.
    @Test func meetingFileCollisionReplacesNothing() async throws {
        let (root, expected, _) = try await armed()
        let meetings = root.appendingPathComponent("meetings").path + "/"
        let plantedBytes = Data("written meanwhile".utf8)
        let planted = Locked<(from: String, to: String)?>(nil)
        #expect(throws: Errno.fileExists) {
            try BackupRestore.applyPendingRestore(dataRoot: root, hook: { op in
                guard case .move(let from, let to) = op, to.hasPrefix(meetings), planted.m.withLock({ $0 == nil })
                else { return }
                try plantedBytes.write(to: URL(fileURLWithPath: to))
                planted.m.withLock { $0 = (from, to) }
            })
        }
        let (from, to) = try #require(planted.m.withLock { $0 })
        #expect(try Data(contentsOf: URL(fileURLWithPath: to)) == plantedBytes)
        let rel = String(to.dropFirst(root.path.count + 1))
        #expect(try sha(Data(contentsOf: URL(fileURLWithPath: from))) == expected[rel])
        #expect(fm.fileExists(atPath: root.appendingPathComponent(".restore-staging/restore.json").path))
        try BackupRestore.applyPendingRestore(dataRoot: root)
        var kept = expected
        kept[rel] = sha(plantedBytes)
        #expect(try inventory(root) == kept)
    }

    /// A meeting file on this Mac that cannot be examined fails staging instead of counting as absent.
    @Test func dataRootMetadataErrorFailsStaging() async throws {
        let lib = try await RestoreLibrary()
        let (_, snapshot) = try await lib.backUp()
        try lib.close()
        let root = try lib.copyRoot()
        let target = try RestoreTarget(root: root, secrets: lib.secrets)
        try target.database.pool.close()
        let meeting = try #require(snapshot.manifest?.files.first).meeting
        let folder = root.appendingPathComponent("meetings/\(meeting)")
        chmod(folder.path, 0o600)
        defer { chmod(folder.path, 0o755) }
        #expect(await target.stage(snapshot) == .refused("The restore could not be prepared: Permission denied"))
        #expect(!fm.fileExists(atPath: target.staging.path))
    }
}

// MARK: - TP8 Encryption, read side

@Suite struct BackupRestoreEncryptionTests {
    @Test func passwordFromKeychainTypedOrRefused() async throws {
        let lib = try await RestoreLibrary()
        let (_, snapshot) = try await lib.backUp(encrypted: true)
        let password = try #require(try lib.secrets.get(key: BackupEngine.passwordKey))
        try lib.close()
        let root = try lib.copyRoot()
        let gone = try #require(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("meetings").path).filter(ULID.isValid).sorted().first)
        try fm.removeItem(at: root.appendingPathComponent("meetings/\(gone)"))

        let empty = try RestoreTarget(root: root, secrets: InMemorySecretStore())
        #expect(await empty.stage(snapshot) == .needsPassword)
        #expect(!fm.fileExists(atPath: empty.staging.path))
        #expect(await empty.stage(snapshot, password: "00000-00000-00000-00000-00000-00000") == .passwordIncorrect)
        #expect(!fm.fileExists(atPath: empty.staging.path))
        #expect(await empty.stage(snapshot, password: "short") == .passwordIncorrect)
        #expect(!fm.fileExists(atPath: empty.staging.path))
        #expect(BackupRestore.passwordIncorrectMessage == "Password incorrect")

        let otherKey = InMemorySecretStore()
        try otherKey.set(key: BackupEngine.passwordKey, value: try BackupEngine.generatePassword())
        try empty.database.pool.close()
        let wrongKeychain = try RestoreTarget(root: root, secrets: otherKey)
        #expect(await wrongKeychain.stage(snapshot) == .needsPassword)

        let typed = try staged(await wrongKeychain.stage(snapshot, password: password))
        #expect(typed.damagedCount == 0)
        let restoredFiles = try inventory(wrongKeychain.staging.appendingPathComponent("meetings"))
        #expect(!restoredFiles.isEmpty && restoredFiles.keys.allSatisfy { $0.hasPrefix(gone + "/") })
        for (file, digest) in restoredFiles { #expect(manifestFiles(snapshot)[file] == digest) }
        try wrongKeychain.database.pool.close()

        let keychain = try RestoreTarget(root: root, secrets: lib.secrets)
        _ = try staged(await keychain.stage(snapshot))
    }

    @Test func storeFileUnderAnotherKeyIsDamaged() async throws {
        let lib = try await RestoreLibrary()
        let (dest, snapshot) = try await lib.backUp(encrypted: true)
        try lib.close()
        let manifest = try #require(snapshot.manifest)
        let victim = try #require(manifest.files.first { $0.name == "audio.m4a" })
        let install = dest.appendingPathComponent("Blaise Backups/\(restoreInstallID)")
        let plain = try makeTempRoot().appendingPathComponent("plain")
        try bytes(1_000).write(to: plain)
        let (rc, _) = try runTool("/usr/bin/aea", [
            "encrypt", "-profile", "5", "-password-value", try BackupEngine.generatePassword(),
            "-i", plain.path, "-o", plain.path + ".aea"])
        #expect(rc == 0)
        try fm.removeItem(at: install.appendingPathComponent(victim.stored))
        try fm.copyItem(at: URL(fileURLWithPath: plain.path + ".aea"), to: install.appendingPathComponent(victim.stored))

        let root = try lib.copyRoot()
        try fm.removeItem(at: root.appendingPathComponent("meetings/\(victim.meeting)"))
        let target = try RestoreTarget(root: root, secrets: lib.secrets)
        let restore = try staged(await target.stage(snapshot))
        #expect(restore.damagedCount == 1)
        #expect(!fm.fileExists(atPath: target.staging.appendingPathComponent("meetings/\(victim.meeting)/audio.m4a").path))
    }
}

private func runTool(_ tool: String, _ args: [String]) throws -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: out, as: UTF8.self))
}

// MARK: - TP11 Hostile folder

@Suite struct BackupRestoreHostileTests {
    private struct Setup {
        let target: RestoreTarget
        let install: URL
        let database: Data
        let bait: URL
    }

    /// A small library to restore into, a snapshot install folder beside it, and a bait file
    /// at `<install>/../../x` that no restore may read.
    private func setup() async throws -> Setup {
        let root = try makeTempRoot()
        let db = try BlaiseDatabase(rootURL: root)
        try await DemoSeeder.seed(database: db, now: armDate)
        let data = try databaseCopy(db)
        try db.pool.close()
        let top = try makeTempRoot()
        let install = top.appendingPathComponent("Blaise Backups/\(restoreInstallID)")
        let bait = top.appendingPathComponent("x")
        try Data("bait".utf8).write(to: bait)
        return Setup(target: try RestoreTarget(root: root), install: install, database: data, bait: bait)
    }

    private func expectRefused(
        _ s: Setup, _ snapshot: RestoreSnapshot, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try? s.target.database.pool.close()
        s.target.log.m.withLock { $0 = [] }
        let before = try inventory(s.target.root)
        #expect(await s.target.stage(snapshot) == .refused(BackupRestore.damagedMessage), sourceLocation: sourceLocation)
        #expect(try inventory(s.target.root) == before, sourceLocation: sourceLocation)
        #expect(!fm.fileExists(atPath: s.target.staging.path), sourceLocation: sourceLocation)
        for op in s.target.ops {
            switch op {
            case .read(let path):
                #expect(path.hasPrefix(snapshot.folder.path + "/"), "read outside the snapshot: \(path)", sourceLocation: sourceLocation)
            case .write(let path), .makeDirectory(let path):
                #expect(path.hasPrefix(s.target.staging.path), "wrote outside staging: \(path)", sourceLocation: sourceLocation)
            case .move(_, let to):
                #expect(to.hasPrefix(s.target.staging.path), sourceLocation: sourceLocation)
            default: break
            }
        }
        #expect(try Data(contentsOf: s.bait) == Data("bait".utf8), sourceLocation: sourceLocation)
    }

    @Test func archiveEntriesOutsideTheAllowlistAreRefused() async throws {
        let s = try await setup()
        let db = CraftedEntry(path: "blaise.sqlite", data: s.database)
        let cases: [[CraftedEntry]] = [
            [db, .init(path: "../evil", data: Data("e".utf8))],
            [db, .init(path: "voice_profile/../x", data: Data("e".utf8))],
            [db, .init(path: "extra.txt", data: Data("e".utf8))],
            [db, .init(path: "meetings/01J0000000000000000000000A/audio.m4a", data: Data("e".utf8))],
            [db, .init(path: "Glossary.md", type: .link, data: nil)],
            [db, .init(path: "voice_profile", type: .directory), .init(path: "voice_profile/other.json", data: Data("e".utf8))],
            [db, .init(path: "meetings", type: .directory)],
            [db, db],
            [db, .init(path: "voice_profile", type: .directory), .init(path: "voice_profile", type: .directory)],
            [.init(path: "Glossary.md", data: Data("g".utf8))],
        ]
        for entries in cases {
            try await expectRefused(s, try craftSnapshot(install: s.install, entries: entries))
        }
        #expect(!fm.fileExists(atPath: s.target.root.deletingLastPathComponent().appendingPathComponent("evil").path))
    }

    @Test func manifestPathsOutsideTheirPatternsAreRefused() async throws {
        let s = try await setup()
        let meeting = ULID.generate()
        let good = try storeFile(install: s.install, meeting: meeting, name: "audio.m4a", data: bytes(500))
        let hash16 = String(good.sha256.prefix(16))
        func entry(_ edit: (inout BackupManifest.FileEntry) -> Void) -> BackupManifest.FileEntry {
            var e = good
            edit(&e)
            return e
        }
        let fileCases: [[BackupManifest.FileEntry]] = [
            [entry { $0.meeting = "not-a-ulid" }],
            [entry { $0.meeting = "../../x" }],
            [entry { $0.meeting = "01J0000000000000000000000\u{212A}" }],
            [entry { $0.name = "audio/../x.m4a" }],
            [entry { $0.name = "capture_/../x.caf" }],
            [entry { $0.name = "notes.md" }],
            [entry { $0.name = "handoff/../../x.json" }],
            [entry { $0.stored = "../../x" }],
            [entry { $0.stored = "files/\(meeting)/../../../../x" }],
            [entry { $0.stored = "files-00000000/\(meeting)/\(hash16)-audio.m4a" }],
            [entry { $0.stored = "files/\(meeting)/\(hash16.uppercased())-audio.m4a" }],
            [entry { $0.stored = "files/\(ULID.generate())/\(hash16)-audio.m4a" }],
            [entry { $0.stored = "files/\(meeting)/\(hash16)-audio_mic.m4a" }],
        ]
        // 26 bytes with a `stored` path built to match, so only the ULID check can refuse them. The
        // traversal one has the right bytes waiting where its path leads, outside the snapshot.
        let traversal = "../../01VEXATRNQ0000000000"
        let outsideStore = s.install.appendingPathComponent("files/\(traversal)/\(hash16)-audio.m4a").standardizedFileURL
        try fm.createDirectory(at: outsideStore.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: s.install.appendingPathComponent(good.stored), to: outsideStore)
        let notCrockford = "01J" + String(repeating: "0", count: 20) + "U00"
        let nonULIDCases: [[BackupManifest.FileEntry]] = [traversal, notCrockford].map { id in
            #expect(id.utf8.count == 26)
            return [entry { $0.meeting = id; $0.stored = "files/\(id)/\(hash16)-audio.m4a" }]
        }
        for files in fileCases + nonULIDCases {
            let snapshot = try craftSnapshot(install: s.install, entries: [.init(path: "blaise.sqlite", data: s.database)], files: files)
            try await expectRefused(s, snapshot)
        }
        let manifestCases: [(inout BackupManifest) -> Void] = [
            { $0.data.file = "../x" },
            { $0.data.file = "data.aea" },
            { $0.encrypted = true; $0.keyID = "../../.."; $0.data.file = "data.aea" },
            { $0.encrypted = true; $0.keyID = nil; $0.data.file = "data.aea" },
            { $0.data.sha256 = String(repeating: "0", count: 64) },
            { $0.files = [good, good] },
            { $0.format = 2 },
        ]
        for edit in manifestCases {
            let snapshot = try craftSnapshot(
                install: s.install, entries: [.init(path: "blaise.sqlite", data: s.database)], files: [good], edit: edit)
            try await expectRefused(s, snapshot)
        }
        // The valid entry itself stages.
        let fine = try craftSnapshot(install: s.install, entries: [.init(path: "blaise.sqlite", data: s.database)], files: [good])
        let restore = try staged(await s.target.stage(fine))
        #expect(restore.damagedCount == 0)
        #expect(fm.fileExists(atPath: s.target.staging.appendingPathComponent("meetings/\(meeting)/audio.m4a").path))
    }

    @Test func mismatchedAndMissingFilesAreSkippedAsDamaged() async throws {
        let s = try await setup()
        let good = try storeFile(install: s.install, meeting: ULID.generate(), name: "audio.m4a", data: bytes(800))
        let rotted = try storeFile(install: s.install, meeting: ULID.generate(), name: "diarization.json", data: bytes(800))
        var flipped = try Data(contentsOf: s.install.appendingPathComponent(rotted.stored))
        flipped[400] ^= 0xff
        try flipped.write(to: s.install.appendingPathComponent(rotted.stored))
        let missing = try storeFile(install: s.install, meeting: ULID.generate(), name: "handoff/\(String(repeating: "ab", count: 32)).json", data: bytes(80))
        try fm.removeItem(at: s.install.appendingPathComponent(missing.stored))
        let snapshot = try craftSnapshot(
            install: s.install, entries: [.init(path: "blaise.sqlite", data: s.database)], files: [good, rotted, missing])
        let restore = try staged(await s.target.stage(snapshot))
        #expect(restore.damagedCount == 2)
        #expect(Set(try inventory(s.target.staging).keys) == ["blaise.sqlite", "meetings/\(good.meeting)/audio.m4a"])
        try s.target.database.pool.close()
        try BackupRestore.arm(restore, dataRoot: s.target.root, now: armDate, timeZone: utcZone)
        try BackupRestore.applyPendingRestore(dataRoot: s.target.root)
        let files = meetingFileHashes(s.target.root)
        #expect(files["\(good.meeting)/audio.m4a"] == good.sha256)
        #expect(files["\(rotted.meeting)/diarization.json"] == nil && files["\(missing.meeting)/\(missing.name)"] == nil)
    }

    @Test func linksInAStoreAreNeverFollowed() async throws {
        let s = try await setup()
        let linked = ULID.generate(), linkedDir = ULID.generate(), plain = ULID.generate()
        let a = try storeFile(install: s.install, meeting: linked, name: "audio.m4a", data: Data("bait".utf8))
        try fm.removeItem(at: s.install.appendingPathComponent(a.stored))
        try fm.createSymbolicLink(at: s.install.appendingPathComponent(a.stored), withDestinationURL: s.bait)
        let b = try storeFile(install: s.install, meeting: linkedDir, name: "diarization.json", data: Data("bait".utf8))
        let realDir = s.install.appendingPathComponent("files/\(linkedDir)")
        let moved = s.bait.deletingLastPathComponent().appendingPathComponent("elsewhere")
        try fm.moveItem(at: realDir, to: moved)
        try fm.createSymbolicLink(at: realDir, withDestinationURL: moved)
        let c = try storeFile(install: s.install, meeting: plain, name: "capture_facts.json", data: bytes(300))
        let snapshot = try craftSnapshot(
            install: s.install, entries: [.init(path: "blaise.sqlite", data: s.database)], files: [a, b, c])
        let restore = try staged(await s.target.stage(snapshot))
        #expect(restore.damagedCount == 2)
        let stagedFiles = try inventory(s.target.staging.appendingPathComponent("meetings"))
        #expect(Set(stagedFiles.keys) == ["\(plain)/capture_facts.json"])
        #expect(try Data(contentsOf: s.bait) == Data("bait".utf8))
    }

    /// `work`'s result. If it has not finished within 5 s it is blocked opening `pipe`: that is
    /// recorded, and the pipe is opened for writing once so the blocked open returns.
    private func unblocked<T: Sendable>(_ pipe: URL, _ work: @escaping @Sendable () async -> T) async throws -> T {
        let done = Locked(false)
        let task = Task {
            let result = await work()
            done.m.withLock { $0 = true }
            return result
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !done.m.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if !done.m.withLock({ $0 }) {
            Issue.record("blocked opening the named pipe \(pipe.lastPathComponent)")
            let fd = open(pipe.path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }
        }
        return await task.value
    }

    @Test func namedPipesAreNeverWaitedOn() async throws {
        let s = try await setup()
        let entry = try storeFile(install: s.install, meeting: ULID.generate(), name: "audio.m4a", data: bytes(300))
        let storePipe = s.install.appendingPathComponent(entry.stored)
        try fm.removeItem(at: storePipe)
        #expect(mkfifo(storePipe.path, 0o644) == 0)
        let snapshot = try craftSnapshot(
            install: s.install, entries: [.init(path: "blaise.sqlite", data: s.database)], files: [entry])
        let target = s.target
        let restore = try staged(try await unblocked(storePipe) { await target.stage(snapshot) })
        #expect(restore.damagedCount == 1)

        let folder = s.install.appendingPathComponent("snapshots/2026-01-01T00-00-00Z-0000000f")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifestPipe = folder.appendingPathComponent("manifest.json")
        #expect(mkfifo(manifestPipe.path, 0o644) == 0)
        let install = s.install
        let rows = try await unblocked(manifestPipe) { BackupRestore.listSnapshots(in: install) }
        let row = try #require(rows.first { $0.name == folder.lastPathComponent })
        #expect(row.manifest == nil)
    }

    @Test func aLinkedInstallFolderIsNotListed() throws {
        let top = try makeTempRoot()
        let elsewhere = try makeTempRoot().appendingPathComponent("aaaaaaaaaaaaaaaa")
        _ = try craftSnapshot(install: elsewhere, entries: [.init(path: "blaise.sqlite", data: Data("x".utf8))])
        try fm.createDirectory(at: top.appendingPathComponent("Blaise Backups"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: top.appendingPathComponent("Blaise Backups/aaaaaaaaaaaaaaaa"), withDestinationURL: elsewhere)
        #expect(BackupRestore.listSnapshots(in: top).isEmpty)
        #expect(BackupRestore.listSnapshots(in: elsewhere).count == 1)
    }

    /// A linked `meetings`, meeting or `handoff` folder in the data root would redirect where a
    /// missing meeting file is looked up and written: staging refuses it, and so does the swap
    /// when the link appears after staging.
    @Test(arguments: ["meetings", "meeting", "handoff"]) func linkedFoldersInTheDataRootAreNeverFollowed(
        component: String
    ) async throws {
        let lib = try await RestoreLibrary()
        let (_, snapshot) = try await lib.backUp()
        try lib.close()
        let meeting = try #require(snapshot.manifest?.files.first { $0.name.hasPrefix("handoff/") }).meeting

        /// A copy of the library without `meeting`'s folder, and the outside folder a link would reach.
        func prepare() throws -> (root: URL, outside: URL) {
            let root = try lib.copyRoot()
            try fm.removeItem(at: root.appendingPathComponent("meetings/\(meeting)"))
            return (root, try makeTempRoot())
        }
        func plantLink(_ root: URL, _ outside: URL) throws {
            let meetings = root.appendingPathComponent("meetings")
            switch component {
            case "meetings":
                try fm.moveItem(at: meetings, to: outside.appendingPathComponent("meetings"))
                try fm.createSymbolicLink(at: meetings, withDestinationURL: outside.appendingPathComponent("meetings"))
            case "meeting":
                try fm.createSymbolicLink(at: meetings.appendingPathComponent(meeting), withDestinationURL: outside)
            default:
                try fm.createDirectory(at: meetings.appendingPathComponent(meeting), withIntermediateDirectories: false)
                try fm.createSymbolicLink(at: meetings.appendingPathComponent("\(meeting)/handoff"), withDestinationURL: outside)
            }
        }

        // Staging.
        let (root, outside) = try prepare()
        try plantLink(root, outside)
        let target = try RestoreTarget(root: root, secrets: lib.secrets)
        try target.database.pool.close()
        let outsideBefore = try inventory(outside)
        #expect(await target.stage(snapshot) == .refused("The restore could not be prepared: Not a directory"))
        #expect(try inventory(outside) == outsideBefore)

        // The swap.
        let (root2, outside2) = try prepare()
        let target2 = try RestoreTarget(root: root2, secrets: lib.secrets)
        let restore = try staged(await target2.stage(snapshot))
        try target2.database.pool.close()
        try BackupRestore.arm(restore, dataRoot: root2, now: armDate, timeZone: utcZone)
        try plantLink(root2, outside2)
        let outside2Before = try inventory(outside2)
        #expect(throws: Errno.notDirectory) { try BackupRestore.applyPendingRestore(dataRoot: root2) }
        #expect(try inventory(outside2) == outside2Before)
        #expect(fm.fileExists(atPath: root2.appendingPathComponent(".restore-staging/restore.json").path))
    }
}

// MARK: - TP13 Tombstones

@Suite struct BackupRestoreTombstoneTests {
    private func expectFoldersIntact(
        _ root: URL, _ before: [String: String], sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let database = try BlaiseDatabase(rootURL: root)
        defer { try? database.pool.close() }
        _ = await MeetingDeletion.sweepTombstones(database: database)
        let after = try inventory(root.appendingPathComponent("meetings"))
        for (path, digest) in before { #expect(after[path] == digest, "lost: \(path)", sourceLocation: sourceLocation) }
        let tombstones = try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meeting_tombstone") }
        #expect(tombstones == 0, sourceLocation: sourceLocation)
    }

    private func restore(_ target: RestoreTarget, _ snapshot: RestoreSnapshot, also: RestoreFileHook? = nil) async throws {
        let restore = try staged(await target.stage(snapshot, also: also))
        try target.database.pool.close()
        try BackupRestore.arm(restore, dataRoot: target.root, now: armDate, timeZone: utcZone)
        try BackupRestore.applyPendingRestore(dataRoot: target.root)
    }

    @Test func snapshotTakenMidDeletionKeepsTheFolder() async throws {
        let lib = try await RestoreLibrary()
        let doomed = try #require(try await lib.meetingIDs().first)
        try lib.close()
        let root = try lib.copyRoot()
        try lib.reopen()
        try await MeetingDeletion.eraseAndTombstone(database: lib.database, meetingID: doomed)
        #expect(try await lib.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meeting_tombstone") } == 1)
        let (_, snapshot) = try await lib.backUp()
        try lib.close()

        let target = try RestoreTarget(root: root, secrets: lib.secrets)
        let before = try inventory(root.appendingPathComponent("meetings"))
        #expect(before.keys.contains { $0.hasPrefix(doomed + "/") })
        try await restore(target, snapshot)
        try await expectFoldersIntact(root, before)
    }

    @Test(arguments: [false, true]) func craftedTombstoneForACurrentFolderIsCleared(wal: Bool) async throws {
        let lib = try await RestoreLibrary()
        let victim = try #require(try await lib.meetingIDs().last)
        let db = try databaseCopy(lib.database, wal: wal) { db in
            try MeetingTombstone(id: victim, audioDirPath: "meetings/\(victim)", deletedAt: armDate).insert(db)
        }
        #expect(db[18] == (wal ? 2 : 1))
        try lib.close()
        let root = try lib.copyRoot()
        let install = try makeTempRoot().appendingPathComponent("Blaise Backups/\(restoreInstallID)")
        let snapshot = try craftSnapshot(install: install, entries: [.init(path: "blaise.sqlite", data: db)])

        let target = try RestoreTarget(root: root)
        let before = try inventory(root.appendingPathComponent("meetings"))
        #expect(before.keys.contains { $0.hasPrefix(victim + "/") })
        let settledCopy = try makeTempRoot().appendingPathComponent("settled.sqlite")
        try await restore(target, snapshot, also: { op in
            if case .stagedDatabaseSettled(let path) = op {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: settledCopy)
            }
        })
        try await expectFoldersIntact(root, before)

        // The staged main file alone, copied before its queue closed, carries no tombstone.
        let copy = try DatabaseQueue(path: settledCopy.path)
        #expect(try await copy.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meeting_tombstone") } == 0)
        try copy.close()
    }

    /// A view named `meeting_tombstone` (one with rows now, or one that is empty now and fills from
    /// `meeting` later), a virtual table reading such a view, or a trigger that puts a deleted
    /// tombstone back, would survive the clearing and name a current folder to the launch sweep.
    @Test(arguments: ["view", "emptyView", "virtualTable", "trigger"])
    func craftedTombstoneObjectsAreRefused(shape: String) async throws {
        let lib = try await RestoreLibrary()
        let victim = try #require(try await lib.meetingIDs().last)
        let db = try databaseCopy(lib.database) { db in
            if shape == "view" {
                try db.execute(sql: "DROP TABLE meeting_tombstone")
                try db.execute(sql: """
                    CREATE VIEW meeting_tombstone AS SELECT '\(victim)' AS id,
                    'meetings/\(victim)' AS audio_dir_path, '2026-05-28 20:26:40.000' AS deleted_at
                    """)
            } else if shape == "emptyView" {
                try db.execute(sql: "DROP TABLE meeting_tombstone")
                try db.execute(sql: """
                    CREATE VIEW meeting_tombstone AS SELECT id, 'meetings/' || id AS audio_dir_path,
                    created_at AS deleted_at FROM meeting WHERE title = 'Quoll Harbor offsite'
                    """)
            } else if shape == "virtualTable" {
                try db.execute(sql: "DROP TABLE meeting_tombstone")
                try db.execute(sql: """
                    CREATE VIEW tombstone_source AS SELECT rowid AS rid, id, 'meetings/' || id AS audio_dir_path,
                    created_at AS deleted_at FROM meeting
                    WHERE last_processing_error = 'interrupted' AND id = '\(victim)'
                    """)
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE meeting_tombstone USING fts5(id, audio_dir_path, deleted_at,
                    content='tombstone_source', content_rowid='rid')
                    """)
                try db.execute(
                    sql: "UPDATE meeting SET status = 'processing', last_processing_error = NULL WHERE id = ?",
                    arguments: [victim])
            } else {
                try MeetingTombstone(id: victim, audioDirPath: "meetings/\(victim)", deletedAt: armDate).insert(db)
                try db.execute(sql: """
                    CREATE TRIGGER keep_tombstone AFTER DELETE ON meeting_tombstone BEGIN
                    INSERT INTO meeting_tombstone (id, audio_dir_path, deleted_at)
                    VALUES (old.id, old.audio_dir_path, old.deleted_at); END
                    """)
            }
        }
        try lib.close()
        let root = try lib.copyRoot()
        let install = try makeTempRoot().appendingPathComponent("Blaise Backups/\(restoreInstallID)")
        let snapshot = try craftSnapshot(install: install, entries: [.init(path: "blaise.sqlite", data: db)])

        let target = try RestoreTarget(root: root)
        try target.database.pool.close()
        let before = try inventory(root)
        #expect(before.keys.contains { $0.hasPrefix("meetings/\(victim)/") })
        #expect(await target.stage(snapshot) == .refused(BackupRestore.damagedMessage))
        #expect(try inventory(root) == before)
        #expect(!fm.fileExists(atPath: target.staging.path))
    }

    /// Any schema object a fresh migration would not create is refused, whatever it is named: a
    /// trigger on another table can fill the (real, empty) tombstone table after the restore.
    @Test(arguments: ["triggerOnAnotherTable", "rewrittenTrigger", "view", "virtualTable", "table", "index"])
    func craftedSchemaObjectsAreRefused(shape: String) async throws {
        let lib = try await RestoreLibrary()
        let victim = try #require(try await lib.meetingIDs().last)
        let db = try databaseCopy(lib.database) { db in
            switch shape {
            case "triggerOnAnotherTable":
                try db.execute(sql: """
                    CREATE TRIGGER harbor_sync AFTER UPDATE ON meeting WHEN new.id = '\(victim)' BEGIN
                    INSERT OR IGNORE INTO meeting_tombstone (id, audio_dir_path, deleted_at)
                    VALUES (new.id, 'meetings/' || new.id, new.updated_at); END
                    """)
                try db.execute(sql: "UPDATE meeting SET status = 'processing' WHERE id = ?", arguments: [victim])
                try db.execute(sql: "DELETE FROM meeting_tombstone")
            case "rewrittenTrigger":
                try db.execute(sql: "DROP TRIGGER notes_fts_ai")
                try db.execute(sql: """
                    CREATE TRIGGER notes_fts_ai AFTER INSERT ON meeting_notes BEGIN
                        INSERT INTO notes_fts(meeting_id, content) VALUES (new.meeting_id, new.markdown);
                        INSERT OR IGNORE INTO meeting_tombstone (id, audio_dir_path, deleted_at)
                        VALUES ('\(victim)', 'meetings/\(victim)', CURRENT_TIMESTAMP);
                    END
                    """)
            case "view":
                try db.execute(sql: "CREATE VIEW kelp_meetings AS SELECT id, title FROM meeting")
            case "virtualTable":
                try db.execute(sql: "CREATE VIRTUAL TABLE kelp_search USING fts5(body)")
            case "table":
                try db.execute(sql: "CREATE TABLE kelp_ledger (entry TEXT)")
            default:
                try db.execute(sql: "CREATE INDEX kelp_meeting_title ON meeting(title)")
            }
        }
        try lib.close()
        let root = try lib.copyRoot()
        let install = try makeTempRoot().appendingPathComponent("Blaise Backups/\(restoreInstallID)")
        let snapshot = try craftSnapshot(install: install, entries: [.init(path: "blaise.sqlite", data: db)])

        let target = try RestoreTarget(root: root)
        try target.database.pool.close()
        let before = try inventory(root)
        #expect(await target.stage(snapshot) == .refused(BackupRestore.damagedMessage))
        #expect(try inventory(root) == before)
        #expect(!fm.fileExists(atPath: target.staging.path))
    }
}

// MARK: - Listing and staging behaviour

@Suite struct BackupRestoreListingTests {
    @Test func listsFromEachFolderFormNewestFirst() async throws {
        let top = try makeTempRoot()
        let backups = top.appendingPathComponent("Blaise Backups")
        let a = backups.appendingPathComponent("aaaaaaaaaaaaaaaa"), b = backups.appendingPathComponent("bbbbbbbbbbbbbbbb")
        let db = CraftedEntry(path: "blaise.sqlite", data: Data("x".utf8))
        let a1 = try craftSnapshot(install: a, entries: [db]) { $0.createdAt = armDate.addingTimeInterval(-86_400) }
        let a2 = try craftSnapshot(install: a, entries: [db])
        let b1 = try craftSnapshot(install: b, entries: [db]) { $0.createdAt = armDate.addingTimeInterval(-3_600) }
        let damaged = a.appendingPathComponent("snapshots/2026-01-01T00-00-00Z-0badf00d")
        try fm.createDirectory(at: damaged, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: damaged.appendingPathComponent("manifest.json"))
        let future = a.appendingPathComponent("snapshots/2026-01-02T00-00-00Z-00000002")
        try fm.createDirectory(at: future, withIntermediateDirectories: true)
        try BackupJSON.encoder.encode(try #require(a1.manifest).with { $0.format = 2 }).write(to: future.appendingPathComponent("manifest.json"))
        let linked = a.appendingPathComponent("snapshots/2026-01-03T00-00-00Z-00000003")
        try fm.createDirectory(at: linked, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linked.appendingPathComponent("manifest.json"), withDestinationURL: a2.folder.appendingPathComponent("manifest.json"))
        try fm.createDirectory(at: a.appendingPathComponent("snapshots/.partial-2026-01-04T00-00-00Z-00000004"), withIntermediateDirectories: true)
        try fm.createDirectory(at: a.appendingPathComponent("snapshots/not-a-snapshot"), withIntermediateDirectories: true)

        let fromTop = BackupRestore.listSnapshots(in: top)
        #expect(fromTop.map(\.name) == [a2.name, b1.name, a1.name, linked.lastPathComponent, future.lastPathComponent, damaged.lastPathComponent])
        #expect(fromTop.filter { $0.manifest == nil }.count == 3)
        #expect(BackupRestore.listSnapshots(in: backups) == fromTop)
        #expect(BackupRestore.listSnapshots(in: b).map(\.name) == [b1.name])
        #expect(BackupRestore.listSnapshots(in: try makeTempRoot()).isEmpty)
    }

    @Test func configuredDestinationIsListed() async throws {
        let lib = try await RestoreLibrary()
        #expect(await lib.engine.restoreSnapshots().isEmpty)
        let (dest, snapshot) = try await lib.backUp()
        let listed = await lib.engine.restoreSnapshots()
        #expect(listed.map(\.name) == [snapshot.name] && listed.map(\.manifest) == [snapshot.manifest])
        #expect(snapshot.folder.path.hasPrefix(dest.path))
        #expect(snapshot.manifest?.meetingCount ?? 0 > 0)
    }

    @Test func recordingStopsStagingAndDiscardsIt() async throws {
        let lib = try await RestoreLibrary()
        let (_, snapshot) = try await lib.backUp()
        try lib.close()
        let root = try lib.copyRoot()
        try fm.removeItem(at: root.appendingPathComponent("meetings"))
        let target = try RestoreTarget(root: root, recordingAfterChecks: 5)
        try target.database.pool.close()
        let before = try inventory(root)
        #expect(await target.stage(snapshot) == .recordingStarted)
        #expect(try inventory(root) == before)
        #expect(BackupRestore.recordingStartedMessage == "Stopped because a recording started. Try again when it ends.")
    }

    @Test func cancelDiscardsStaging() async throws {
        let lib = try await RestoreLibrary()
        let (_, snapshot) = try await lib.backUp()
        try lib.close()
        let root = try lib.copyRoot()
        let target = try RestoreTarget(root: root)
        let outcome = await target.stage(snapshot, also: { op in
            if case .makeDirectory = op { withUnsafeCurrentTask { $0?.cancel() } }
        })
        #expect(outcome == .cancelled)
        #expect(!fm.fileExists(atPath: target.staging.path))
    }

    /// A recording or Cancel that arrives during the database checks of a snapshot with no meeting
    /// files still stops staging.
    @Test(arguments: ["recording", "cancel"]) func stopDuringTheLastStepDiscardsStaging(stop: String) async throws {
        let root = try makeTempRoot()
        let db = try BlaiseDatabase(rootURL: root)
        try await DemoSeeder.seed(database: db, now: armDate)
        let data = try databaseCopy(db)
        try db.pool.close()
        let install = try makeTempRoot().appendingPathComponent("Blaise Backups/\(restoreInstallID)")
        let snapshot = try craftSnapshot(install: install, entries: [.init(path: "blaise.sqlite", data: data)])
        let target = try RestoreTarget(root: root)
        let recording = target.recording
        let outcome = await target.stage(snapshot, also: { op in
            guard case .stagedDatabaseSettled = op else { return }
            if stop == "recording" { recording.m.withLock { $0 = true } } else { withUnsafeCurrentTask { $0?.cancel() } }
        })
        #expect(outcome == (stop == "recording" ? .recordingStarted : .cancelled))
        #expect(!fm.fileExists(atPath: target.staging.path))
    }

    @Test func stagingHoldsTheBusyFlag() async throws {
        let lib = try await RestoreLibrary()
        let (_, snapshot) = try await lib.backUp()
        let first = Locked(true)
        let engine = BackupEngine(
            database: lib.database, secrets: lib.secrets,
            isRecording: {
                if first.m.withLock({ let f = $0; $0 = false; return f }) { try? await Task.sleep(for: .milliseconds(500)) }
                return false
            },
            timeZone: { utcZone }, installID: restoreInstallID)
        async let staging = engine.stageRestore(snapshot)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await engine.backUpNow() == .busy)
        #expect(await engine.stageRestore(snapshot) == .busy)
        _ = try staged(await staging)
        try BackupRestore.discardStaging(dataRoot: lib.root)
        #expect(!fm.fileExists(atPath: lib.root.appendingPathComponent(".restore-staging").path))
    }
}

extension BackupManifest {
    func with(_ edit: (inout BackupManifest) -> Void) -> BackupManifest {
        var copy = self
        edit(&copy)
        return copy
    }
}

// MARK: - Performance 2: launch open with no pending restore

@Suite(.serialized) struct BackupRestoreLaunchTests {
    @Test func launchOpenCostWithNoPendingRestore() async throws {
        let lib = try await RestoreLibrary(syntheticMeetings: 100)
        try lib.close()
        let clock = ContinuousClock()
        var plain: [Duration] = [], withCheck: [Duration] = [], checkAlone: [Duration] = []
        for _ in 0..<15 {
            plain.append(try clock.measure { try BlaiseDatabase(rootURL: lib.root).pool.close() })
            withCheck.append(try clock.measure {
                try BackupRestore.applyPendingRestore(dataRoot: lib.root)
                try BlaiseDatabase(rootURL: lib.root).pool.close()
            })
        }
        for _ in 0..<1_000 {
            checkAlone.append(try clock.measure { try BackupRestore.applyPendingRestore(dataRoot: lib.root) })
        }
        func median(_ d: [Duration]) -> Duration { d.sorted()[d.count / 2] }
        print("PERF| open without restore check: median \(median(plain)), max \(plain.max()!)")
        print("PERF| open with restore check:    median \(median(withCheck)), max \(withCheck.max()!)")
        print("PERF| restore check alone:        median \(median(checkAlone)), max \(checkAlone.max()!)")
        #expect(median(checkAlone) < .milliseconds(1))
    }
}
