import AppleArchive
import CryptoKit
import Foundation
import GRDB
import OSLog
import System

/// A file operation of restore staging or the launch swap; the test seam sees (and may fail) each one.
public enum RestoreFileOp: Sendable, Equatable {
    case makeDirectory(String)
    /// A new file is created.
    case write(String)
    /// A file of the snapshot folder is opened.
    case read(String)
    case flush(String)
    case move(from: String, to: String)
    case delete(String)
    /// The staged database is in `journal_mode=DELETE` and its queue is about to close.
    case stagedDatabaseSettled(String)
}

public typealias RestoreFileHook = @Sendable (RestoreFileOp) throws -> Void

/// One row of the restore list: a complete snapshot folder. `manifest` is nil when it does not
/// parse or is damaged; such a row cannot be picked.
public struct RestoreSnapshot: Sendable, Equatable, Identifiable {
    /// `<install>/snapshots/<name>`.
    public let folder: URL
    public let manifest: BackupManifest?

    public var id: String { folder.path }
    public var name: String { folder.lastPathComponent }
    public var date: Date? { manifest?.createdAt ?? BackupSnapshotName.date(of: name) }
    var install: URL { folder.deletingLastPathComponent().deletingLastPathComponent() }
}

/// A verified restore in `<root>/.restore-staging/`. Inert until the quit handler arms it.
public struct StagedRestore: Sendable, Equatable {
    public let snapshot: String
    public let sourceName: String
    public let createdAt: Date
    public let appVersion: String
    /// The swap units staged, in swap order.
    public let items: [String]
    /// Meeting files of the snapshot that were missing or failed their hash; skipped.
    public let damagedCount: Int
}

public enum RestoreStageOutcome: Sendable, Equatable {
    case staged(StagedRestore)
    /// Encrypted, and the Keychain password is absent or does not open it.
    case needsPassword
    /// The typed password does not open it.
    case passwordIncorrect
    /// Refused or failed; the message is shown to the user.
    case refused(String)
    case recordingStarted
    case busy
    case cancelled
}

public enum BackupRestoreError: Error, Equatable {
    /// `.restore-staging/restore.json` exists but is not a marker this version wrote.
    case invalidMarker
}

/// Restore: listing, verify and stage, arming at quit, and the swap at launch.
public enum BackupRestore {
    public static let passwordIncorrectMessage = "Password incorrect"
    public static let recordingStartedMessage = "Stopped because a recording started. Try again when it ends."
    public static let damagedMessage = "This backup is damaged and cannot be restored."
    public static let migrateFailedMessage = "This backup could not be updated to this version of Blaise."

    public static func newerVersionMessage(_ appVersion: String) -> String {
        "This backup was made by a newer version of Blaise (\(appVersion)). Update Blaise, then restore it."
    }

    static let stagingName = ".restore-staging"
    static let markerName = "restore.json"
    static let migrateCheckName = "migrate-check.sqlite"
    static let setAsidePrefix = "Set Aside Before Restore "
    static let databaseName = BlaiseDatabase.databaseFileName
    /// Swap units, in swap order.
    static let swapUnits = [databaseName, "Glossary.md", "stoplist_user.txt", "voice_profile"]
    /// The only regular-file entries a snapshot archive may hold; `voice_profile` is the only directory.
    static let archiveFiles: Set<String> = [
        databaseName, "Glossary.md", "stoplist_user.txt",
        "voice_profile/profile.json", "voice_profile/candidates.json",
    ]

    private static let logger = Logger(subsystem: BlaiseBundle.identifier, category: "backup")

    // MARK: - Listing

    /// Complete snapshots under `folder`, newest first. `folder` may hold `Blaise Backups`, be
    /// `Blaise Backups` itself, or be one install folder inside it.
    public static func listSnapshots(in folder: URL) -> [RestoreSnapshot] {
        let installs: [URL]
        if (try? lstatKind(folder.appendingPathComponent("snapshots"))) == S_IFDIR {
            installs = [folder]
        } else {
            let holder = folder.appendingPathComponent("Blaise Backups")
            let base = (try? lstatKind(holder)) == S_IFDIR ? holder : folder
            installs = ((try? entries(of: base)) ?? []).map { base.appendingPathComponent($0) }
                .filter {
                    (try? lstatKind($0)) == S_IFDIR && (try? lstatKind($0.appendingPathComponent("snapshots"))) == S_IFDIR
                }
        }
        var rows: [RestoreSnapshot] = []
        for install in installs {
            let snapshots = install.appendingPathComponent("snapshots")
            for name in (try? entries(of: snapshots)) ?? [] where BackupSnapshotName.date(of: name) != nil {
                let folder = snapshots.appendingPathComponent(name)
                guard (try? lstatKind(folder)) == S_IFDIR else { continue }
                let manifest = (try? readSmallFile(folder.appendingPathComponent("manifest.json"), io: RestoreIO(hook: nil)))
                    .flatMap { try? BackupManifest.decode($0) }
                rows.append(RestoreSnapshot(folder: folder, manifest: manifest))
            }
        }
        return rows.sorted { ($0.date ?? .distantPast, $0.id) > ($1.date ?? .distantPast, $1.id) }
    }

    // MARK: - Verify and stage

    private enum Stop: Error {
        case refused(String)
        case needsPassword, passwordIncorrect, recording, cancelled
    }

    /// Verifies `snapshot` and stages it into `<root>/.restore-staging/` (emptied first). Anything
    /// but `.staged` leaves no staging folder behind. The caller holds the engine's busy flag.
    static func stage(
        _ snapshot: RestoreSnapshot, dataRoot: URL, password: String?, keychainPassword: String?,
        isRecording: @escaping @Sendable () async -> Bool, hook: RestoreFileHook?
    ) async -> RestoreStageOutcome {
        let io = RestoreIO(hook: hook)
        var stager = Stager(
            snapshot: snapshot, dataRoot: dataRoot, io: io, typedPassword: password,
            keychainPassword: keychainPassword, isRecording: isRecording)
        do {
            let staged = try await stager.run()
            let (copied, kept) = (stager.copied, stager.kept)
            logger.info("restore staged: \(copied) files copied, \(kept) kept, \(staged.damagedCount) damaged")
            return .staged(staged)
        } catch {
            try? io.removeTree(stager.staging)
            switch error as? Stop {
            case .refused(let message)?:
                logger.error("restore refused")
                return .refused(message)
            case .needsPassword?: return .needsPassword
            case .passwordIncorrect?: return .passwordIncorrect
            case .recording?: return .recordingStarted
            case .cancelled?: return .cancelled
            case nil:
                logger.error("restore staging failed: \(String(describing: type(of: error)), privacy: .public)")
                return .refused("The restore could not be prepared: \(describe(error))")
            }
        }
    }

    /// Deletes a staged restore that was not confirmed.
    public static func discardStaging(dataRoot: URL) throws {
        try RestoreIO(hook: nil).removeTree(dataRoot.appendingPathComponent(stagingName))
    }

    private struct Stager {
        let snapshot: RestoreSnapshot
        let dataRoot: URL
        let io: RestoreIO
        let typedPassword: String?
        let keychainPassword: String?
        let isRecording: @Sendable () async -> Bool
        var copied = 0
        var kept = 0

        var staging: URL { dataRoot.appendingPathComponent(BackupRestore.stagingName) }

        init(
            snapshot: RestoreSnapshot, dataRoot: URL, io: RestoreIO, typedPassword: String?,
            keychainPassword: String?, isRecording: @escaping @Sendable () async -> Bool
        ) {
            self.snapshot = snapshot
            self.dataRoot = dataRoot
            self.io = io
            self.typedPassword = typedPassword
            self.keychainPassword = keychainPassword
            self.isRecording = isRecording
        }

        private func checkpoint() async throws {
            if await isRecording() { throw Stop.recording }
            if Task.isCancelled { throw Stop.cancelled }
        }

        mutating func run() async throws -> StagedRestore {
            try io.removeTree(staging)
            // 2a: every path the manifest names is validated before anything is read through it.
            guard let manifestData = try readSmallFile(snapshot.folder.appendingPathComponent("manifest.json"), io: io),
                let manifest = try? BackupManifest.decode(manifestData)
            else { throw Stop.refused(damagedMessage) }
            let store = try BackupRestore.validate(manifest)
            try await checkpoint()
            let dataURL = snapshot.folder.appendingPathComponent(manifest.data.file)
            guard try hashFile(dataURL) == manifest.data.sha256 else { throw Stop.refused(damagedMessage) }

            // 2b
            let password = manifest.encrypted ? try choosePassword(dataURL) : nil
            try await checkpoint()

            // 2c
            try io.makeDirectory(staging)
            let extracted = try extract(dataURL, password: password)
            try await checkpoint()

            // 2d
            try checkDatabase(appVersion: manifest.appVersion)
            try migrateCheck()

            // 2e
            var damaged = 0
            for entry in manifest.files {
                try await checkpoint()
                if try !stageFile(entry, store: store, password: password) { damaged += 1 }
            }
            try flushTree(staging)
            try io.flush(dataRoot)
            try await checkpoint()

            let items = BackupRestore.swapUnits.filter { unit in
                unit == "voice_profile"
                    ? extracted.contains { $0.hasPrefix("voice_profile/") } : extracted.contains(unit)
            }
            return StagedRestore(
                snapshot: snapshot.name, sourceName: manifest.sourceName, createdAt: manifest.createdAt,
                appVersion: manifest.appVersion, items: items, damagedCount: damaged)
        }

        /// SHA-256 of a regular file of the snapshot folder; nil when it is missing or not a regular file.
        private func hashFile(_ url: URL) throws -> String? {
            guard let fd = try io.openRead(url) else { return nil }
            defer { close(fd) }
            var hasher = SHA256()
            try readAll(fd) { hasher.update(bufferPointer: $0) }
            return hasher.finalize().hexString
        }

        private func choosePassword(_ dataURL: URL) throws -> String {
            if let typedPassword {
                guard try opens(dataURL, typedPassword) else { throw Stop.passwordIncorrect }
                return typedPassword
            }
            if let keychainPassword, try opens(dataURL, keychainPassword) { return keychainPassword }
            throw Stop.needsPassword
        }

        private func opens(_ url: URL, _ password: String) throws -> Bool {
            guard let fd = try io.openRead(url) else { throw Stop.refused(damagedMessage) }
            guard let file = ArchiveByteStream.fileStream(fd: FileDescriptor(rawValue: fd), automaticClose: true)
            else { close(fd); throw Stop.refused(damagedMessage) }
            defer { try? file.close() }
            guard let context = ArchiveEncryptionContext(from: file) else { throw Stop.refused(damagedMessage) }
            do { try context.setPassword(password) } catch { return false }
            guard let stream = ArchiveByteStream.decryptionStream(readingFrom: file, encryptionContext: context)
            else { return false }
            try? stream.close()
            return true
        }

        /// Extracts the allowlisted entries; any other entry refuses the snapshot.
        private func extract(_ url: URL, password: String?) throws -> Set<String> {
            guard let fd = try io.openRead(url) else { throw Stop.refused(damagedMessage) }
            guard let file = ArchiveByteStream.fileStream(fd: FileDescriptor(rawValue: fd), automaticClose: true)
            else { close(fd); throw Stop.refused(damagedMessage) }
            defer { try? file.close() }
            let plain: ArchiveByteStream?
            if let password {
                let context = ArchiveEncryptionContext(from: file)
                try? context?.setPassword(password)
                plain = context.flatMap { ArchiveByteStream.decryptionStream(readingFrom: file, encryptionContext: $0) }
            } else {
                plain = ArchiveByteStream.decompressionStream(readingFrom: file)
            }
            guard let plain else { throw Stop.refused(damagedMessage) }
            defer { try? plain.close() }
            guard let decoder = ArchiveStream.decodeStream(readingFrom: plain) else { throw Stop.refused(damagedMessage) }
            defer { try? decoder.close() }

            let pathKey = ArchiveHeader.FieldKey("PAT")
            let dataKey = ArchiveHeader.FieldKey("DAT")
            let voice = staging.appendingPathComponent("voice_profile")
            var extracted = Set<String>()
            var seen = Set<String>()
            while true {
                let header: ArchiveHeader?
                do { header = try decoder.readHeader() } catch { throw Stop.refused(damagedMessage) }
                guard let header else { break }
                guard case .string(_, let path)? = header.field(forKey: pathKey), let type = header.entryType,
                    seen.insert(path).inserted
                else { throw Stop.refused(damagedMessage) }
                if type == .directory, path == "voice_profile" {
                    try io.makeDirectory(voice)
                    continue
                }
                guard type == .regularFile, BackupRestore.archiveFiles.contains(path)
                else { throw Stop.refused(damagedMessage) }
                var size: UInt64 = 0
                if case .blob(_, let blobSize, _)? = header.field(forKey: dataKey) { size = blobSize }
                if path.hasPrefix("voice_profile/") { try io.makeDirectory(voice) }
                let out = try io.create(staging.appendingPathComponent(path))
                defer { close(out) }
                let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: BackupEngine.chunkSize, alignment: 16)
                defer { buffer.deallocate() }
                var left = size
                while left > 0 {
                    let chunk = UnsafeMutableRawBufferPointer(rebasing: buffer[..<Int(min(left, UInt64(buffer.count)))])
                    do { try decoder.readBlob(key: dataKey, into: chunk) } catch { throw Stop.refused(damagedMessage) }
                    try writeAll(out, UnsafeRawBufferPointer(chunk))
                    left -= UInt64(chunk.count)
                }
                try io.sync(out, staging.appendingPathComponent(path))
                extracted.insert(path)
            }
            guard extracted.contains(BackupRestore.databaseName) else { throw Stop.refused(damagedMessage) }
            return extracted
        }

        /// 2d on the staged file: integrity, newer-schema refusal, deletion intents cleared, one
        /// self-contained file.
        private func checkDatabase(appVersion: String) throws {
            let path = staging.appendingPathComponent(BackupRestore.databaseName).path
            do {
                let queue = try DatabaseQueue(path: path)
                do {
                    let check = try queue.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") }
                    guard check == ["ok"] else { throw Stop.refused(damagedMessage) }
                    if try queue.read({ try BlaiseDatabase.migrator.hasBeenSuperseded($0) }) {
                        throw Stop.refused(newerVersionMessage(appVersion))
                    }
                    try queue.write { db in
                        if try db.tableExists(MeetingTombstone.databaseTableName) {
                            try db.execute(sql: "DELETE FROM meeting_tombstone")
                        }
                    }
                    let mode = try queue.writeWithoutTransaction {
                        try String.fetchOne($0, sql: "PRAGMA journal_mode=DELETE")
                    }
                    guard mode == "delete" else { throw Stop.refused(damagedMessage) }
                    try io.op(.stagedDatabaseSettled(path))
                    try queue.close()
                } catch {
                    try? queue.close()
                    throw error
                }
            } catch let error as DatabaseError where Self.isLocalFailure(error) {
                throw error
            } catch is DatabaseError {
                throw Stop.refused(damagedMessage)
            }
        }

        /// Runs the migrator on a throwaway copy; the staged file itself is never migrated. The
        /// migrated schema must hold no object a fresh migration would not create (a trigger,
        /// view or table of its own could put tombstones back after the clearing), and must hold
        /// `meeting_tombstone` as an empty ordinary table: a view, a virtual table (which
        /// `sqlite_master` also lists as a table) or a trigger by that name would keep tombstones
        /// past the clearing. The copy must be deleted for staging to succeed; after another
        /// failure its deletion is best effort.
        private func migrateCheck() throws {
            let source = staging.appendingPathComponent(BackupRestore.databaseName)
            let copy = staging.appendingPathComponent(BackupRestore.migrateCheckName)
            let copyFiles = ["", "-wal", "-shm", "-journal"].map { URL(fileURLWithPath: copy.path + $0) }
            do {
                try io.op(.write(copy.path))
                try FileManager.default.copyItem(at: source, to: copy)
                let accepted: Bool
                do {
                    let queue = try DatabaseQueue(path: copy.path)
                    defer { try? queue.close() }
                    try BlaiseDatabase.migrator.migrate(queue)
                    let fresh = try DatabaseQueue()
                    try BlaiseDatabase.migrator.migrate(fresh)
                    let expected = try fresh.read(Self.schemaObjects)
                    accepted = try queue.read { db in
                        try Self.schemaObjects(db).isSubset(of: expected)
                            && Int.fetchOne(db, sql: """
                                SELECT COUNT(*) FROM pragma_table_list
                                WHERE schema = 'main' AND name = 'meeting_tombstone' AND type = 'table'
                                """) == 1
                            && Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_tombstone") == 0
                    }
                } catch let error as DatabaseError where Self.isLocalFailure(error) {
                    throw error
                } catch {
                    throw Stop.refused(migrateFailedMessage)
                }
                guard accepted else { throw Stop.refused(damagedMessage) }
            } catch {
                for file in copyFiles { try? io.remove(file) }
                throw error
            }
            for file in copyFiles { try io.remove(file) }
        }

        /// Every schema object as kind, name and owning table, plus the whitespace-normalized SQL
        /// of triggers and views (an expected name with a rewritten body must not pass). A table's
        /// kind comes from `pragma_table_list`, which tells ordinary, virtual and shadow tables and
        /// views apart.
        private static func schemaObjects(_ db: Database) throws -> Set<String> {
            let tables = try Row.fetchAll(db, sql: "SELECT type, name FROM pragma_table_list WHERE schema = 'main'")
                .map { "\($0["type"] as String) \($0["name"] as String)" }
            let others = try Row.fetchAll(db, sql: """
                SELECT type, name, tbl_name, sql FROM sqlite_master WHERE type IN ('index', 'trigger', 'view')
                """).map { row -> String in
                    let type: String = row["type"]
                    let key = "\(type) \(row["name"] as String) on \(row["tbl_name"] as String)"
                    guard type != "index" else { return key }
                    let sql = (row["sql"] as String?) ?? ""
                    return key + ": " + sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                }
            return Set(tables + others)
        }

        private static func isLocalFailure(_ error: DatabaseError) -> Bool {
            error.resultCode == .SQLITE_FULL || error.resultCode == .SQLITE_IOERR
                || error.resultCode == .SQLITE_CANTOPEN
        }

        /// Stages one meeting file unless the library already has it. False when it is damaged.
        private mutating func stageFile(
            _ entry: BackupManifest.FileEntry, store: String, password: String?
        ) throws -> Bool {
            let current = dataRoot.appendingPathComponent("meetings/\(entry.meeting)/\(entry.name)")
            if try BackupRestore.foldersExist(holding: entry.name, of: entry.meeting, in: dataRoot),
                try lstatKind(current) != nil
            {
                kept += 1
                return true
            }
            let storeDir = snapshot.install.appendingPathComponent(store)
            guard try lstatKind(storeDir) == S_IFDIR,
                try lstatKind(storeDir.appendingPathComponent(entry.meeting)) == S_IFDIR,
                let fd = try io.openRead(snapshot.install.appendingPathComponent(entry.stored))
            else { return false }
            let temp = staging.appendingPathComponent(".tmp-" + UUID().uuidString)
            let out: Int32
            do { out = try io.create(temp) } catch { close(fd); throw error }
            var hasher = SHA256()
            var readable = true
            do {
                defer { close(out) }
                let write: (UnsafeRawBufferPointer) throws -> Void = { chunk in
                    hasher.update(bufferPointer: chunk)
                    try writeAll(out, chunk)
                }
                if let password {
                    readable = try decrypt(fd, password: password, write)
                } else {
                    defer { close(fd) }
                    try readAll(fd, write)
                }
                try io.sync(out, temp)
            }
            guard readable, hasher.finalize().hexString == entry.sha256 else {
                try io.remove(temp)
                return false
            }
            var dir = staging
            for component in ["meetings", entry.meeting] + entry.name.split(separator: "/").dropLast().map(String.init) {
                dir.appendPathComponent(component)
                try io.makeDirectory(dir)
            }
            try io.move(temp, staging.appendingPathComponent("meetings/\(entry.meeting)/\(entry.name)"))
            copied += 1
            return true
        }

        /// Streams a per-file AEA container through `write`; false when it cannot be opened or
        /// authenticated. Closes `fd`.
        private func decrypt(
            _ fd: Int32, password: String, _ write: (UnsafeRawBufferPointer) throws -> Void
        ) throws -> Bool {
            guard let file = ArchiveByteStream.fileStream(fd: FileDescriptor(rawValue: fd), automaticClose: true)
            else { close(fd); return false }
            defer { try? file.close() }
            guard let context = ArchiveEncryptionContext(from: file), (try? context.setPassword(password)) != nil,
                let stream = ArchiveByteStream.decryptionStream(readingFrom: file, encryptionContext: context)
            else { return false }
            defer { try? stream.close() }
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: BackupEngine.chunkSize, alignment: 16)
            defer { buffer.deallocate() }
            while true {
                let n: Int
                do { n = try stream.read(into: buffer) } catch { return false }
                if n == 0 { return true }
                try write(UnsafeRawBufferPointer(rebasing: buffer[..<n]))
            }
        }

        private func flushTree(_ dir: URL) throws {
            for name in try BackupRestore.entries(of: dir) {
                let child = dir.appendingPathComponent(name)
                if try lstatKind(child) == S_IFDIR { try flushTree(child) }
            }
            try io.flush(dir)
        }
    }

    /// Checks every name and path the manifest would have restore build; returns the snapshot's store.
    static func validate(_ manifest: BackupManifest) throws -> String {
        let damaged = Stop.refused(damagedMessage)
        guard manifest.data.file == (manifest.encrypted ? "data.aea" : "data.aar") else { throw damaged }
        let store: String
        if manifest.encrypted {
            guard let keyID = manifest.keyID, keyID.utf8.count == 8, isLowerHex(keyID) else { throw damaged }
            store = "files-\(keyID)"
        } else {
            store = "files"
        }
        for entry in manifest.files {
            // Byte comparisons throughout: String equality is canonical equivalence, not identity.
            guard ULID.isValid(entry.meeting), entry.meeting.utf8.count == 26,
                BackupAllowlist.isMeetingFileName(entry.name)
            else { throw damaged }
            let base = entry.name.split(separator: "/").last.map(String.init) ?? entry.name
            let prefix = Array("\(store)/\(entry.meeting)/".utf8)
            let suffix = Array(("-\(base)" + (manifest.encrypted ? ".aea" : "")).utf8)
            let stored = Array(entry.stored.utf8)
            guard stored.count == prefix.count + 16 + suffix.count, stored.starts(with: prefix),
                stored.suffix(suffix.count).elementsEqual(suffix),
                stored[prefix.count..<prefix.count + 16].allSatisfy(isLowerHexByte)
            else { throw damaged }
        }
        return store
    }

    // MARK: - Arm (quit handler)

    struct Marker: Codable, Equatable {
        var snapshot: String
        var sourceName: String
        var createdAt: Date
        var items: [String]
        var setAside: String
    }

    /// Arms a confirmed restore: creates the set-aside folder, then writes the marker once by temp
    /// file, flush, rename, flush. Called by the quit handler after in-flight encodes finish.
    public static func arm(
        _ staged: StagedRestore, dataRoot: URL, now: Date = Date(), timeZone: TimeZone = .current,
        hook: RestoreFileHook? = nil
    ) throws {
        let io = RestoreIO(hook: hook)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let base = setAsidePrefix + formatter.string(from: now)
        var setAside = base
        var n = 1
        while true {
            let url = dataRoot.appendingPathComponent(setAside)
            try io.op(.makeDirectory(url.path))
            if mkdir(url.path, 0o755) == 0 { break }
            guard errno == EEXIST else { throw Errno(rawValue: errno) }
            n += 1
            setAside = "\(base) \(n)"
        }
        try io.flush(dataRoot)

        let staging = dataRoot.appendingPathComponent(stagingName)
        let marker = Marker(
            snapshot: staged.snapshot, sourceName: staged.sourceName, createdAt: staged.createdAt,
            items: staged.items, setAside: setAside)
        let data = try BackupJSON.encoder.encode(marker)
        let temp = staging.appendingPathComponent(".tmp-" + UUID().uuidString)
        let fd = try io.create(temp)
        do {
            defer { close(fd) }
            try data.withUnsafeBytes { try writeAll(fd, $0) }
            try io.sync(fd, temp)
        }
        try io.move(temp, staging.appendingPathComponent(markerName))
        try io.flush(staging)
        logger.info("restore armed: \(staged.items.count) items")
    }

    // MARK: - Swap (launch)

    /// Called before anything opens the database. No staging: one `fileExists`. Staging without a
    /// marker: deleted. With a marker: the swap, which re-runs safely from any point.
    public static func applyPendingRestore(dataRoot: URL, hook: RestoreFileHook? = nil) throws {
        let staging = dataRoot.appendingPathComponent(stagingName)
        guard FileManager.default.fileExists(atPath: staging.path) else { return }
        let io = RestoreIO(hook: hook)
        let markerURL = staging.appendingPathComponent(markerName)
        guard try lstatKind(markerURL) != nil else {
            try io.removeTree(staging)
            return
        }
        guard let data = try? Data(contentsOf: markerURL),
            let marker = try? BackupJSON.decoder.decode(Marker.self, from: data),
            marker.setAside.hasPrefix(setAsidePrefix), !marker.setAside.contains("/"),
            marker.items.contains(databaseName), marker.items.allSatisfy(swapUnits.contains)
        else { throw BackupRestoreError.invalidMarker }

        // a
        let setAside = dataRoot.appendingPathComponent(marker.setAside)
        try io.makeDirectory(setAside)

        // b
        for unit in swapUnits {
            let staged = staging.appendingPathComponent(unit)
            let current = unit == databaseName ? [unit, unit + "-wal", unit + "-shm"] : [unit]
            let restoring = marker.items.contains(unit)
            if restoring, try lstatKind(staged) == nil { continue }
            for name in current where try lstatKind(dataRoot.appendingPathComponent(name)) != nil {
                try io.move(dataRoot.appendingPathComponent(name), setAside.appendingPathComponent(name))
            }
            if restoring { try io.move(staged, dataRoot.appendingPathComponent(unit)) }
        }

        // c
        let stagedMeetings = staging.appendingPathComponent("meetings")
        let meetings = try entries(of: stagedMeetings).filter(ULID.isValid).sorted()
        for meeting in meetings {
            let from = stagedMeetings.appendingPathComponent(meeting)
            var names = try entries(of: from)
            names += try entries(of: from.appendingPathComponent("handoff")).map { "handoff/" + $0 }
            for name in names.sorted() where BackupAllowlist.isMeetingFileName(name) {
                if try !foldersExist(holding: name, of: meeting, in: dataRoot) {
                    for dir in folders(holding: name, of: meeting, in: dataRoot) where try lstatKind(dir) == nil {
                        try io.makeDirectory(dir)
                    }
                }
                let target = dataRoot.appendingPathComponent("meetings/\(meeting)/\(name)")
                guard try lstatKind(target) == nil else { continue }
                try io.move(from.appendingPathComponent(name), target)
            }
        }

        // d: the receiving folders follow from the staged tree, which stays until staging is
        // deleted, so a resumed swap also flushes what an interrupted one moved.
        var received = [dataRoot, setAside]
        if !meetings.isEmpty { received.append(dataRoot.appendingPathComponent("meetings")) }
        for meeting in meetings {
            let dir = dataRoot.appendingPathComponent("meetings/\(meeting)")
            received.append(dir)
            if try lstatKind(stagedMeetings.appendingPathComponent("\(meeting)/handoff")) == S_IFDIR {
                received.append(dir.appendingPathComponent("handoff"))
            }
        }
        for dir in received { try io.flush(dir) }
        for name in try entries(of: staging).sorted() where name != markerName {
            try io.removeTree(staging.appendingPathComponent(name))
        }
        try io.removeTree(markerURL)
        try io.removeTree(staging)
        logger.info("restore applied: \(marker.items.count) items")
    }

    // MARK: - Helpers

    /// The folders under `root` that hold meeting file `name`, outermost first:
    /// `meetings`, `meetings/<meeting>`, and `handoff` for a handoff payload.
    static func folders(holding name: String, of meeting: String, in root: URL) -> [URL] {
        var dir = root
        return (["meetings", meeting] + name.split(separator: "/").dropLast().map(String.init)).map {
            dir.appendPathComponent($0)
            return dir
        }
    }

    /// Whether all of `folders(holding:of:in:)` exist. One that exists but is not a real folder
    /// (a link included) throws: nothing is read or written through it.
    static func foldersExist(holding name: String, of meeting: String, in root: URL) throws -> Bool {
        for dir in folders(holding: name, of: meeting, in: root) {
            switch try lstatKind(dir) {
            case nil: return false
            case S_IFDIR?: continue
            default: throw Errno.notDirectory
            }
        }
        return true
    }

    /// The names in `dir`; empty only when `dir` does not exist. Any other error throws.
    static func entries(of dir: URL) throws -> [String] {
        guard let stream = opendir(dir.path) else {
            if errno == ENOENT { return [] }
            throw Errno(rawValue: errno)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw Errno(rawValue: errno) }
                return names
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    /// The file type at `url`, a link not followed; nil only when nothing is there. Any other
    /// error throws.
    static func lstatKind(_ url: URL) throws -> mode_t? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            if errno == ENOENT { return nil }
            throw Errno(rawValue: errno)
        }
        return st.st_mode & S_IFMT
    }

    static func isLowerHex(_ s: String) -> Bool { s.utf8.allSatisfy(isLowerHexByte) }

    static func isLowerHexByte(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) || (0x61...0x66).contains(b) }

    /// Reads a small regular file without following a link; nil when missing.
    static func readSmallFile(_ url: URL, io: RestoreIO) throws -> Data? {
        guard let fd = try io.openRead(url) else { return nil }
        defer { close(fd) }
        var data = Data()
        try readAll(fd) { data.append(contentsOf: $0) }
        return data
    }

    static func readAll(_ fd: Int32, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: BackupEngine.chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let n = read(fd, buffer.baseAddress, buffer.count)
            if n < 0 { throw Errno(rawValue: errno) }
            if n == 0 { return }
            try body(UnsafeRawBufferPointer(rebasing: buffer[..<n]))
        }
    }

    static func writeAll(_ fd: Int32, _ buffer: UnsafeRawBufferPointer) throws {
        var done = 0
        while done < buffer.count {
            let n = write(fd, buffer.baseAddress! + done, buffer.count - done)
            guard n > 0 else { throw Errno(rawValue: errno) }
            done += n
        }
    }

    private static func describe(_ error: Error) -> String {
        if let errno = error as? Errno { return errno.description }
        return (error as NSError).localizedDescription
    }
}

/// File operations through the restore seam. Moves never replace; flushes use F_FULLFSYNC,
/// falling back to `fsync`.
struct RestoreIO {
    let hook: RestoreFileHook?

    func op(_ op: RestoreFileOp) throws { try hook?(op) }

    func makeDirectory(_ url: URL) throws {
        guard try BackupRestore.lstatKind(url) != S_IFDIR else { return }
        try op(.makeDirectory(url.path))
        guard mkdir(url.path, 0o755) == 0 else { throw Errno(rawValue: errno) }
    }

    func move(_ from: URL, _ to: URL) throws {
        try op(.move(from: from.path, to: to.path))
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else { throw Errno(rawValue: errno) }
    }

    func flush(_ url: URL) throws {
        try op(.flush(url.path))
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Errno(rawValue: errno) }
        defer { close(fd) }
        try Self.fullSync(fd)
    }

    /// Flushes an open file to the media.
    func sync(_ fd: Int32, _ url: URL) throws {
        try op(.flush(url.path))
        try Self.fullSync(fd)
    }

    func removeTree(_ url: URL) throws {
        guard try BackupRestore.lstatKind(url) != nil else { return }
        try op(.delete(url.path))
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {}
    }

    func remove(_ url: URL) throws { try removeTree(url) }

    /// A new file, never replacing one.
    func create(_ url: URL) throws -> Int32 {
        try op(.write(url.path))
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw Errno(rawValue: errno) }
        return fd
    }

    /// Opens a regular file for reading without following a final link; nil when it is missing,
    /// a link, or not a regular file. The open does not block: a named pipe would otherwise wait
    /// for a writer before its type is checked.
    func openRead(_ url: URL) throws -> Int32? {
        try op(.read(url.path))
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT || errno == ELOOP || errno == ENOTDIR { return nil }
            throw Errno(rawValue: errno)
        }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            return nil
        }
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK) == 0 else {
            let error = Errno(rawValue: errno)
            close(fd)
            throw error
        }
        return fd
    }

    static func fullSync(_ fd: Int32) throws {
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard fsync(fd) == 0 else { throw Errno(rawValue: errno) }
    }
}

extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
