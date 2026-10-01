import AppleArchive
import CryptoKit
import Foundation
import GRDB
import OSLog
import Synchronization
import System

/// A file operation the engine is about to perform; the test seam sees (and may fail) each one.
public enum BackupFileOp: Sendable, Equatable {
    case makeDirectory(String)
    case write(String, bytes: Int)
    case flush(String)
    case rename(from: String, to: String)
    case delete(String)
    /// A local copy into `.backup-staging` (the database copy or an archive item).
    case stage(String)
}

public typealias BackupFileHook = @Sendable (BackupFileOp) throws -> Void

/// Daily snapshot of the library to a user-chosen folder. One operation at a time (`isBusy`),
/// set synchronously at each entry point before its first `await`.
public actor BackupEngine {
    public enum RunOutcome: Equatable, Sendable {
        case notConfigured, notDue, busy, recording, interrupted, succeeded
        case failed(BackupFailureReason)
    }

    public static let passwordKey = "backup.password"
    static let stateFileName = ".backup-state.json"
    static let stagingName = ".backup-staging"
    static let chunkSize = 1 << 20

    private let database: BlaiseDatabase
    private let secrets: SecretStore
    private let isRecording: @Sendable () async -> Bool
    private let now: @Sendable () -> Date
    /// The Mac's time zone, read at each due decision and each prune.
    private let timeZone: @Sendable () -> TimeZone
    private let installIDOverride: String?
    private let hook: BackupFileHook?
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "backup")

    public private(set) var isBusy = false {
        didSet { busyMirror.withLock { $0 = isBusy } }
    }
    private let busyMirror = Mutex(false)
    /// `isBusy`, readable without waiting for the actor, which can sit in one long synchronous
    /// file step.
    public nonisolated var isBusyNow: Bool { busyMirror.withLock { $0 } }

    public init(
        database: BlaiseDatabase,
        secrets: SecretStore,
        isRecording: @escaping @Sendable () async -> Bool,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent },
        installID: String? = nil,
        fileHook: BackupFileHook? = nil
    ) {
        self.database = database
        self.secrets = secrets
        self.isRecording = isRecording
        self.now = now
        self.timeZone = timeZone
        self.installIDOverride = installID
        self.hook = fileHook
    }

    private var root: URL { database.rootURL }
    private var stateURL: URL { root.appendingPathComponent(Self.stateFileName) }

    // MARK: - Settings entry points (never wait for `isBusy`)

    public func state() -> BackupState {
        guard let data = try? Data(contentsOf: stateURL),
            let state = try? BackupJSON.decoder.decode(BackupState.self, from: data)
        else { return BackupState() }
        return state
    }

    /// Stores the folder, clears the success/failure record, and kicks a run. A failed flush after
    /// the state replace is logged, not thrown.
    public func chooseFolder(_ url: URL) async throws -> RunOutcome {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let at = now()
        try writeSettingsState {
            $0.destinationBookmark = bookmark
            $0.configuredAt = at
            $0.lastSuccessAt = nil
            $0.lastFailure = nil
        }
        return await run(ignoreDue: false)
    }

    /// Stores the password in the secret store and starts a new key; the next run to start encrypts.
    /// A state write that fails before the state file is replaced puts the previous password back,
    /// so the stored password always belongs to the state's key. A failed flush after the replace
    /// is logged, not thrown.
    public func enableEncryption(password: String) throws {
        let previous = try secrets.get(key: Self.passwordKey)
        try secrets.set(key: Self.passwordKey, value: password)
        let keyID = BackupSnapshotName.randomHex(8)
        var replaced = false
        do {
            try writeState(replaced: &replaced) {
                $0.encrypted = true
                $0.keyID = keyID
            }
        } catch {
            // Only the flush after the replace failed: the new key is in force with this password,
            // so encryption is on and the caller must not report a failure.
            if replaced {
                logger.error("backup state flush failed: \(Self.describe(error), privacy: .public)")
                return
            }
            if let previous {
                try? secrets.set(key: Self.passwordKey, value: previous)
            } else {
                try? secrets.delete(key: Self.passwordKey)
            }
            throw error
        }
    }

    /// New snapshots are plaintext; the stored password stays so older snapshots remain restorable.
    /// A failed flush after the state replace is logged, not thrown.
    public func disableEncryption() throws {
        try writeSettingsState { $0.encrypted = false }
    }

    public static func generatePassword() throws -> String {
        try ArchiveEncryptionContext(
            profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: .none
        ).generatePassword()
    }

    /// Runs when due. Called at launch and then hourly.
    public func tick() async -> RunOutcome { await run(ignoreDue: false) }

    /// Runs regardless of "due"; still refuses while recording.
    public func backUpNow() async -> RunOutcome { await run(ignoreDue: true) }

    // MARK: - Restore entry points

    /// Complete snapshots under `folder`, or under the configured destination when nil.
    public func restoreSnapshots(in folder: URL? = nil) -> [RestoreSnapshot] {
        if let folder { return BackupRestore.listSnapshots(in: folder) }
        var stale = false
        guard let bookmark = state().destinationBookmark,
            let dest = try? URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return [] }
        let scoped = dest.startAccessingSecurityScopedResource()
        defer { if scoped { dest.stopAccessingSecurityScopedResource() } }
        return BackupRestore.listSnapshots(in: dest)
    }

    /// Whether this install's namespace at the configured destination holds a complete snapshot
    /// whose manifest says it is not encrypted. Other namespaces are not checked.
    public func hasUnencryptedSnapshots() -> Bool {
        var stale = false
        guard let bookmark = state().destinationBookmark,
            let installID = installIDOverride ?? Self.installID(dataRoot: root),
            let dest = try? URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return false }
        let scoped = dest.startAccessingSecurityScopedResource()
        defer { if scoped { dest.stopAccessingSecurityScopedResource() } }
        let install = dest.appendingPathComponent("Blaise Backups").appendingPathComponent(installID)
        return BackupRestore.listSnapshots(in: install).contains { $0.manifest?.encrypted == false }
    }

    /// Verifies and stages a snapshot, holding `isBusy` so no run prunes it meanwhile. With no
    /// typed password, an encrypted snapshot is tried with the stored one.
    public func stageRestore(
        _ snapshot: RestoreSnapshot, password: String? = nil, hook: RestoreFileHook? = nil
    ) async -> RestoreStageOutcome {
        guard !isBusy else { return .busy }
        isBusy = true
        defer { isBusy = false }
        let stored = password == nil ? (try? secrets.get(key: Self.passwordKey)) ?? nil : nil
        return await BackupRestore.stage(
            snapshot, dataRoot: root, password: password, keychainPassword: stored,
            isRecording: isRecording, hook: hook)
    }

    // MARK: - The run

    private struct RunConfig {
        let bookmark: Data
        let encrypted: Bool
        let keyID: String?
        let password: String?

        func matches(_ s: BackupState) -> Bool {
            s.destinationBookmark == bookmark && s.isEncrypted == encrypted && s.keyID == keyID
        }
    }

    private struct Failure: Error {
        let reason: BackupFailureReason
        let detail: String
    }

    private func run(ignoreDue: Bool) async -> RunOutcome {
        guard !isBusy else { return .busy }
        isBusy = true
        defer { isBusy = false }
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .background, reason: "Blaise backup")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        if await isRecording() { return .recording }

        // Step 1: one synchronous read of the state and the password.
        let current = state()
        guard let bookmark = current.destinationBookmark else { return .notConfigured }
        if !ignoreDue && !current.isDue(now: now(), calendar: localCalendar) { return .notDue }
        let password = current.isEncrypted ? (try? secrets.getWithoutUI(key: Self.passwordKey)) ?? nil : nil
        let config = RunConfig(
            bookmark: bookmark, encrypted: current.isEncrypted, keyID: current.keyID, password: password)
        if config.encrypted && (password == nil || config.keyID == nil) {
            return recordFailure(.init(reason: .passwordUnavailable, detail: "no password"), config)
        }

        var stale = false
        guard let dest = try? URL(
            resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return recordFailure(.init(reason: .notConnected, detail: "bookmark"), config) }
        let scoped = dest.startAccessingSecurityScopedResource()
        defer { if scoped { dest.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue
        else { return recordFailure(.init(reason: .notConnected, detail: "folder missing"), config) }

        let published: (install: URL, name: String)
        do {
            guard let published0 = try await writeSnapshot(dest: dest, config: config) else {
                logger.info("backup interrupted by a recording")
                return .interrupted
            }
            published = published0
        } catch let failure as Failure {
            return recordFailure(failure, config)
        } catch {
            return recordFailure(.init(reason: .localError, detail: "\(type(of: error))"), config)
        }

        // After the rename the run is a success; a later failure ends the run and records nothing.
        let snapshots = published.install.appendingPathComponent("snapshots")
        do {
            try flush(snapshots, local: false)
            let at = now()
            try writeState(skipsNoOp: true) { if config.matches($0) { $0.lastSuccessAt = at; $0.lastFailure = nil } }
            try checkConfined(
                [published.install.deletingLastPathComponent(), published.install, snapshots], under: dest)
            try prune(snapshots, keeping: published.name)
            try collectGarbage(published.install)
        } catch {
            logger.error("backup post-publish step failed: \(Self.describe(error), privacy: .public)")
        }
        return .succeeded
    }

    private func recordFailure(_ failure: Failure, _ config: RunConfig) -> RunOutcome {
        logger.error("backup failed: \(failure.reason.rawValue, privacy: .public) (\(failure.detail, privacy: .public))")
        let at = now()
        do {
            try writeState(skipsNoOp: true) { if config.matches($0) { $0.lastFailure = .init(reason: failure.reason, at: at) } }
        } catch {
            logger.error("backup state write failed: \(Self.describe(error), privacy: .public)")
        }
        return .failed(failure.reason)
    }

    /// Reason and errno for the log; the type name for anything else. Never a path.
    private static func describe(_ error: Error) -> String {
        guard let failure = error as? Failure else { return String(describing: type(of: error)) }
        return "\(failure.reason.rawValue) (\(failure.detail))"
    }

    private var localCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone()
        return c
    }

    /// Steps 2-7. Returns nil when a recording interrupted the run.
    private func writeSnapshot(dest: URL, config: RunConfig) async throws -> (install: URL, name: String)? {
        guard let installID = installIDOverride ?? Self.installID(dataRoot: root) else {
            throw Failure(reason: .localError, detail: "host uuid")
        }
        let backups = dest.appendingPathComponent("Blaise Backups")
        let install = backups.appendingPathComponent(installID)
        let snapshots = install.appendingPathComponent("snapshots")
        let staging = root.appendingPathComponent(Self.stagingName)
        let storeName = config.encrypted ? "files-\(config.keyID!)" : "files"
        let store = install.appendingPathComponent(storeName)
        try checkConfined([backups, install, snapshots, store], under: dest)

        // Step 2: this install's leftovers.
        try cleanLeftovers(install: install, staging: staging)

        // Step 3.
        for dir in [backups, install, snapshots] { try makeDirectory(dir, local: false) }
        let name = BackupSnapshotName.make(now())
        let partial = snapshots.appendingPathComponent(".partial-" + name)
        try makeDirectory(partial, local: false)

        // Step 4: database copy on the local disk, checked before it leaves.
        try makeDirectory(staging, local: true)
        let meetingCount = try stageDatabase(into: staging)

        // Step 5: archive.
        try stageArchiveItems(into: staging)
        let dataFile = try writeArchive(of: staging, into: partial, config: config)
        try local { try hookThrow(.delete(staging.path)); try FileManager.default.removeItem(at: staging) }

        // Step 6: meeting files.
        let previous = previousManifest(snapshots)
        guard let files = try await copyMeetingFiles(
            install: install, store: store, storeName: storeName, previous: previous, config: config)
        else { return nil }

        // Step 7: publish.
        let manifest = BackupManifest(
            format: BackupManifest.currentFormat, createdAt: now(),
            sourceName: Host.current().localizedName ?? "",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            encrypted: config.encrypted, keyID: config.encrypted ? config.keyID : nil,
            data: dataFile, meetingCount: meetingCount, files: files)
        let manifestData = try local { try manifest.encoded() }
        let sink = try Sink(url: partial.appendingPathComponent("manifest.json"), hook: hook)
        try sink.writeAll(manifestData)
        try sink.finish()
        try flush(partial, local: false)
        try rename(partial, snapshots.appendingPathComponent(name), local: false)
        logger.info("backup published: \(files.count) files, \(meetingCount) meetings")
        return (install, name)
    }

    /// Refuses the run when a namespace folder is a link or not a folder, or resolves outside the
    /// chosen folder: nothing is written or deleted through a link. Absent folders pass.
    private func checkConfined(_ dirs: [URL], under dest: URL) throws {
        func resolved(_ url: URL) -> String? {
            guard let p = realpath(url.path, nil) else { return nil }
            defer { free(p) }
            return String(cString: p)
        }
        guard let base = resolved(dest) else { throw Failure(reason: .notWritable, detail: "realpath") }
        for dir in dirs {
            switch Self.lstatKind(dir) {
            case nil:
                continue
            case .some(S_IFDIR):
                guard let real = resolved(dir), real.hasPrefix(base + "/") else {
                    throw Failure(reason: .notWritable, detail: "outside the folder")
                }
            default:
                throw Failure(reason: .notWritable, detail: "not a folder")
            }
        }
    }

    private func cleanLeftovers(install: URL, staging: URL) throws {
        let snapshots = install.appendingPathComponent("snapshots")
        let partials = try listDirectory(snapshots, local: false).filter { $0.hasPrefix(".partial-") }
        // A `.partial-` may be a retired snapshot whose rename never reached the media.
        if !partials.isEmpty { try flush(snapshots, local: false) }
        for entry in partials {
            try remove(snapshots.appendingPathComponent(entry), local: false)
        }
        for store in try stores(install) {
            for meeting in try listDirectory(store, local: false) {
                let dir = store.appendingPathComponent(meeting)
                guard Self.lstatKind(dir) == S_IFDIR else { continue }
                for entry in try listDirectory(dir, local: false) where entry.hasPrefix(".tmp-") {
                    try remove(dir.appendingPathComponent(entry), local: false)
                }
            }
        }
        if FileManager.default.fileExists(atPath: staging.path) { try remove(staging, local: true) }
    }

    private func stores(_ install: URL) throws -> [URL] {
        try listDirectory(install, local: false)
            .filter { $0 == "files" || $0.hasPrefix("files-") }
            .map { install.appendingPathComponent($0) }
            .filter { Self.lstatKind($0) == S_IFDIR }
    }

    private func stageDatabase(into staging: URL) throws -> Int {
        let copyURL = staging.appendingPathComponent(BlaiseDatabase.databaseFileName)
        do {
            try hookThrow(.stage(copyURL.path))
            let copy = try DatabaseQueue(path: copyURL.path)
            try database.pool.backup(to: copy)
            let check = try copy.read { try String.fetchAll($0, sql: "PRAGMA quick_check") }
            guard check == ["ok"] else {
                try? copy.close()
                throw Failure(reason: .databaseCheck, detail: "quick_check")
            }
            let count = try copy.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meeting") } ?? 0
            let mode = try copy.writeWithoutTransaction { try String.fetchOne($0, sql: "PRAGMA journal_mode=DELETE") }
            try copy.close()
            guard mode == "delete" else { throw Failure(reason: .localError, detail: "journal mode") }
            return count
        } catch let error as DatabaseError where error.resultCode == .SQLITE_FULL {
            throw Failure(reason: .localDiskFull, detail: "database copy")
        } catch let error as DatabaseError {
            throw Failure(reason: .localError, detail: "database copy \(error.resultCode.rawValue)")
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Self.classify(error, local: true, detail: "database copy")
        }
    }

    /// Copies the glossary, stoplist and voice print next to the database copy, when present.
    private func stageArchiveItems(into staging: URL) throws {
        let paths = database.paths
        let voice = paths.voiceProfileDirectory
        let items: [(URL, String)] = [
            (paths.glossaryURL, "Glossary.md"),
            (paths.userStoplistURL, "stoplist_user.txt"),
            (voice.appendingPathComponent("profile.json"), "voice_profile/profile.json"),
            (voice.appendingPathComponent("candidates.json"), "voice_profile/candidates.json"),
        ]
        for (source, name) in items where FileManager.default.fileExists(atPath: source.path) {
            let target = staging.appendingPathComponent(name)
            try local {
                try hookThrow(.stage(target.path))
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try FileManager.default.copyItem(at: source, to: target)
                } catch CocoaError.fileReadNoSuchFile {}
            }
        }
    }

    /// The only entries a snapshot archive may hold.
    static let archiveEntries: Set<String> = [
        BlaiseDatabase.databaseFileName, "Glossary.md", "stoplist_user.txt", "voice_profile",
        "voice_profile/profile.json", "voice_profile/candidates.json",
    ]

    private func writeArchive(of staging: URL, into partial: URL, config: RunConfig) throws -> BackupManifest.DataFile {
        let fileName = config.encrypted ? "data.aea" : "data.aar"
        let url = partial.appendingPathComponent(fileName)
        let sink = try Sink(url: url, hook: hook)
        do {
            guard let raw = ArchiveByteStream.customStream(instance: sink) else { throw Errno.ioError }
            let middle: ArchiveByteStream?
            if config.encrypted {
                let context = ArchiveEncryptionContext(
                    profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: .lzfse)
                try context.setPassword(config.password!)
                middle = ArchiveByteStream.encryptionStream(writingTo: raw, encryptionContext: context)
            } else {
                middle = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: raw)
            }
            guard let middle, let encoder = ArchiveStream.encodeStream(writingTo: middle) else {
                throw Errno.ioError
            }
            try encoder.writeDirectoryContents(
                archiveFrom: FilePath(staging.path), keySet: ArchiveHeader.FieldKeySet("TYP,PAT,DAT,MOD")!,
                selectUsing: { _, path, _ in Self.archiveEntries.contains(path.string) ? .ok : .skip })
            try encoder.close()
            try middle.close()
            try raw.close()
        } catch {
            throw sink.failure ?? Self.classify(error, local: true, detail: "archive")
        }
        try sink.finish()
        // The encryption stream writes its prologue last, at offset 0, so its hash is read back.
        let sha = try sink.sequentialDigest ?? hashFile(url)
        return .init(file: fileName, size: sink.size, sha256: sha)
    }

    private func hashFile(_ url: URL) throws -> String {
        var hasher = SHA256()
        _ = try readLocalFile(url, local: false) { hasher.update(bufferPointer: $0) }
        return hasher.finalize().hex
    }

    /// The newest complete snapshot of this install whose manifest reads.
    private func previousManifest(_ snapshots: URL) -> BackupManifest? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? [])
            .filter { BackupSnapshotName.date(of: $0) != nil }.sorted(by: >)
        for name in names {
            let url = snapshots.appendingPathComponent(name).appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: url), let manifest = try? BackupManifest.decode(data) {
                return manifest
            }
        }
        return nil
    }

    private func copyMeetingFiles(
        install: URL, store: URL, storeName: String, previous: BackupManifest?, config: RunConfig
    ) async throws -> [BackupManifest.FileEntry]? {
        var reusable: [String: BackupManifest.FileEntry] = [:]
        for entry in previous?.files ?? [] where entry.stored.hasPrefix(storeName + "/") {
            reusable[entry.meeting + "/" + entry.name] = entry
        }
        let meetingsDir = database.paths.meetingsDirectory
        var entries: [BackupManifest.FileEntry] = []
        var copiedBytes: Int64 = 0
        for meeting in try listDirectory(meetingsDir, local: true).sorted() where ULID.isValid(meeting) {
            let dir = meetingsDir.appendingPathComponent(meeting)
            guard try Self.sourceInfo(dir)?.kind == S_IFDIR else { continue }
            var names = try listDirectory(dir, local: true)
            if try Self.sourceInfo(dir.appendingPathComponent("handoff"))?.kind == S_IFDIR {
                names += try listDirectory(dir.appendingPathComponent("handoff"), local: true)
                    .map { "handoff/" + $0 }
            }
            for name in names.sorted() where BackupAllowlist.isMeetingFileName(name) {
                if await isRecording() { return nil }
                let source = dir.appendingPathComponent(name)
                guard let info = try Self.sourceInfo(source), info.kind == S_IFREG else { continue }
                if let old = reusable[meeting + "/" + name], old.size == info.size, old.mtime == info.mtime,
                    Self.lstatKind(store.appendingPathComponent(meeting)) == S_IFDIR,
                    Self.lstatInfo(install.appendingPathComponent(old.stored))?.size == old.storedSize
                {
                    entries.append(old)
                    continue
                }
                guard let entry = try copyFile(
                    source, meeting: meeting, name: name, mtime: info.mtime,
                    store: store, storeName: storeName, config: config)
                else { continue }
                copiedBytes += entry.size
                entries.append(entry)
            }
        }
        logger.info("backup meeting files: \(entries.count) listed, \(copiedBytes) bytes copied")
        return entries
    }

    /// Copies one meeting file into the store under its content name; nil when the source is gone.
    private func copyFile(
        _ source: URL, meeting: String, name: String, mtime: Double,
        store: URL, storeName: String, config: RunConfig
    ) throws -> BackupManifest.FileEntry? {
        let dir = store.appendingPathComponent(meeting)
        try makeDirectory(store, local: false)
        try makeDirectory(dir, local: false)
        let temp = dir.appendingPathComponent(".tmp-" + UUID().uuidString)
        let sink = try Sink(url: temp, hook: hook)
        var hasher = SHA256()
        let size: Int64?
        do {
            if config.encrypted {
                let context = ArchiveEncryptionContext(
                    profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: .none)
                context.paddingSize = 0
                try context.setPassword(config.password!)
                guard let raw = ArchiveByteStream.customStream(instance: sink),
                    let enc = ArchiveByteStream.encryptionStream(writingTo: raw, encryptionContext: context)
                else { throw Errno.ioError }
                size = try readLocalFile(source, local: true) { buffer in
                    hasher.update(bufferPointer: buffer)
                    var offset = 0
                    while offset < buffer.count {
                        offset += try enc.write(from: UnsafeRawBufferPointer(rebasing: buffer[offset...]))
                    }
                }
                try enc.close()
                try raw.close()
            } else {
                size = try readLocalFile(source, local: true) { buffer in
                    hasher.update(bufferPointer: buffer)
                    try sink.write(buffer)
                }
            }
        } catch let failure as Failure {
            throw sink.failure ?? failure
        } catch {
            throw sink.failure ?? Self.classify(error, local: false, detail: "file copy")
        }
        try sink.finish()
        guard let size else {
            try remove(temp, local: false)
            return nil
        }
        let sha = hasher.finalize().hex
        let base = (name as NSString).lastPathComponent
        let storedName = "\(sha.prefix(16))-\(base)" + (config.encrypted ? ".aea" : "")
        let target = dir.appendingPathComponent(storedName)
        if Self.lstatInfo(target)?.size == sink.size {
            try remove(temp, local: false)
        } else {
            try rename(temp, target, local: false)
            try flush(dir, local: false)
        }
        return .init(
            meeting: meeting, name: name, size: size, mtime: mtime, sha256: sha,
            stored: "\(storeName)/\(meeting)/\(storedName)", storedSize: sink.size)
    }

    // MARK: - Retention and garbage collection

    private func prune(_ snapshots: URL, keeping published: String) throws {
        let names = try listDirectory(snapshots, local: false).filter { BackupSnapshotName.date(of: $0) != nil }
        let keep = BackupRetention.kept(names, now: now(), timeZone: timeZone()).union([published])
        let doomed = names.filter { !keep.contains($0) }
        guard !doomed.isEmpty else { return }
        for name in doomed {
            try rename(snapshots.appendingPathComponent(name), snapshots.appendingPathComponent(".partial-" + name), local: false)
        }
        // The renames are on the media before anything they hid is deleted.
        try flush(snapshots, local: false)
        for name in doomed { try remove(snapshots.appendingPathComponent(".partial-" + name), local: false) }
    }

    /// Deletes store files no complete snapshot references; skipped when any manifest is unreadable.
    private func collectGarbage(_ install: URL) throws {
        let snapshots = install.appendingPathComponent("snapshots")
        var references = Set<String>()
        for name in try listDirectory(snapshots, local: false) where BackupSnapshotName.date(of: name) != nil {
            let url = snapshots.appendingPathComponent(name).appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: url), let manifest = try? BackupManifest.decode(data) else {
                logger.error("backup GC skipped: a manifest is unreadable")
                return
            }
            references.formUnion(manifest.files.map(\.stored))
        }
        var deleted = 0
        for store in try stores(install) {
            let storeName = store.lastPathComponent
            for entry in try listDirectory(store, local: false) {
                let url = store.appendingPathComponent(entry)
                switch Self.lstatKind(url) {
                case .some(S_IFREG) where !references.contains("\(storeName)/\(entry)"):
                    try remove(url, local: false)
                    deleted += 1
                case .some(S_IFDIR):
                    for file in try listDirectory(url, local: false)
                    where Self.lstatKind(url.appendingPathComponent(file)) == S_IFREG
                        && !references.contains("\(storeName)/\(entry)/\(file)")
                    {
                        try remove(url.appendingPathComponent(file), local: false)
                        deleted += 1
                    }
                    if try listDirectory(url, local: false).isEmpty { try remove(url, local: false) }
                default:
                    continue
                }
            }
            if try listDirectory(store, local: false).isEmpty { try remove(store, local: false) }
        }
        logger.info("backup GC: \(deleted) files deleted")
    }

    // MARK: - State file (the engine is its only writer)

    /// `skipsNoOp`: a change that leaves the state as read writes nothing, so a run's outcome
    /// never replaces a file it could not read.
    private func writeState(skipsNoOp: Bool = false, _ change: (inout BackupState) -> Void) throws {
        var replaced = false
        try writeState(replaced: &replaced, skipsNoOp: skipsNoOp, change)
    }

    /// A Settings write: once the state file is replaced the change is in force, so a failure only
    /// in the flush after it is logged, not thrown.
    private func writeSettingsState(_ change: (inout BackupState) -> Void) throws {
        var replaced = false
        do {
            try writeState(replaced: &replaced, change)
        } catch {
            guard replaced else { throw error }
            logger.error("backup state flush failed: \(Self.describe(error), privacy: .public)")
        }
    }

    /// Re-reads the file and changes only the caller's keys, with no suspension in between.
    /// `replaced` is true once the new file is in place, even when the flush after it throws.
    private func writeState(
        replaced: inout Bool, skipsNoOp: Bool = false, _ change: (inout BackupState) -> Void
    ) throws {
        var state = state()
        let read = state
        change(&state)
        if skipsNoOp && state == read { return }
        let data = try BackupJSON.encoder.encode(state)
        let temp = root.appendingPathComponent(".backup-state.json.tmp-" + UUID().uuidString)
        do {
            let sink = try Sink(url: temp, hook: hook, local: true)
            try sink.writeAll(data)
            try sink.finish()
            try rename(temp, stateURL, local: true)
            replaced = true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        try flush(root, local: true)
    }

    // MARK: - File operations

    fileprivate func hookThrow(_ op: BackupFileOp) throws { try hook?(op) }

    private func local<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let failure as Failure { throw failure } catch {
            throw Self.classify(error, local: true, detail: "local")
        }
    }

    private func makeDirectory(_ url: URL, local: Bool) throws {
        guard Self.lstatKind(url) != S_IFDIR else { return }
        do {
            try hookThrow(.makeDirectory(url.path))
            if mkdir(url.path, 0o755) != 0 {
                let code = errno
                // An existing entry that is not a real folder (a link, a file) is never written through.
                guard code == EEXIST, Self.lstatKind(url) == S_IFDIR else {
                    throw Errno(rawValue: code == EEXIST ? ENOTDIR : code)
                }
            }
        } catch {
            throw Self.classify(error, local: local, detail: "mkdir")
        }
        try flush(url.deletingLastPathComponent(), local: local)
    }

    private func rename(_ from: URL, _ to: URL, local: Bool) throws {
        do {
            try hookThrow(.rename(from: from.path, to: to.path))
            guard Darwin.rename(from.path, to.path) == 0 else { throw Errno(rawValue: errno) }
        } catch {
            throw Self.classify(error, local: local, detail: "rename")
        }
    }

    private func remove(_ url: URL, local: Bool) throws {
        do {
            try hookThrow(.delete(url.path))
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            throw Self.classify(error, local: local, detail: "delete")
        }
    }

    /// Flushes a directory's entries to the media.
    private func flush(_ url: URL, local: Bool) throws {
        do {
            try hookThrow(.flush(url.path))
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { throw Errno(rawValue: errno) }
            defer { close(fd) }
            try Self.fullSync(fd)
        } catch {
            throw Self.classify(error, local: local, detail: "flush")
        }
    }

    fileprivate static func fullSync(_ fd: Int32) throws {
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard fsync(fd) == 0 else { throw Errno(rawValue: errno) }
    }

    /// Entry names of a directory; empty when it does not exist.
    private func listDirectory(_ url: URL, local: Bool) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            throw Self.classify(error, local: local, detail: "list")
        }
    }

    /// Streams a file in chunks; returns the byte count, or nil when the file is gone.
    private func readLocalFile(
        _ url: URL, local: Bool, _ body: (UnsafeRawBufferPointer) throws -> Void
    ) throws -> Int64? {
        let fd = open(url.path, O_RDONLY)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw Self.classify(Errno(rawValue: errno), local: local, detail: "open")
        }
        defer { close(fd) }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        var total: Int64 = 0
        while true {
            let n = read(fd, buffer.baseAddress, Self.chunkSize)
            if n < 0 { throw Self.classify(Errno(rawValue: errno), local: local, detail: "read") }
            if n == 0 { return total }
            try body(UnsafeRawBufferPointer(rebasing: buffer[..<n]))
            total += Int64(n)
        }
    }

    private static func classify(_ error: Error, local: Bool, detail: String) -> Failure {
        if let failure = error as? Failure { return failure }
        let code: Int32
        if let e = error as? Errno {
            code = e.rawValue
        } else if let e = error as? POSIXError {
            code = e.code.rawValue
        } else if let e = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError, e.domain == NSPOSIXErrorDomain {
            code = Int32(e.code)
        } else if (error as NSError).code == NSFileWriteOutOfSpaceError {
            code = ENOSPC
        } else {
            code = EIO
        }
        let reason: BackupFailureReason
        if local {
            reason = code == ENOSPC ? .localDiskFull : .localError
        } else {
            reason = code == ENOSPC || code == EDQUOT ? .full : .notWritable
        }
        return Failure(reason: reason, detail: "\(detail) errno \(code)")
    }

    private static func lstatKind(_ url: URL) -> mode_t? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return st.st_mode & S_IFMT
    }

    /// Kind, size and mtime of a library entry (never through a link); nil when it is gone.
    /// Any other error fails the run.
    private static func sourceInfo(_ url: URL) throws -> (kind: mode_t, size: Int64, mtime: Double)? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw classify(Errno(rawValue: code), local: true, detail: "lstat")
        }
        return (st.st_mode & S_IFMT, Int64(st.st_size),
                Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
    }

    /// Size and mtime of a regular file (never through a link).
    private static func lstatInfo(_ url: URL) -> (size: Int64, mtime: Double)? {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return (Int64(st.st_size), Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
    }

    /// SHA-256 of the hardware UUID, a newline and the data root path; first 16 hex characters.
    static func installID(dataRoot: URL) -> String? {
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var wait = timespec(tv_sec: 0, tv_nsec: 0)
        let rc = withUnsafeMutableBytes(of: &uuid) {
            gethostuuid($0.baseAddress!.assumingMemoryBound(to: UInt8.self), &wait)
        }
        guard rc == 0 else { return nil }
        let text = UUID(uuid: uuid).uuidString + "\n" + dataRoot.path
        return String(SHA256.hash(data: Data(text.utf8)).hex.prefix(16))
    }

    /// A new file written through the hook seam, flushed on `finish()`.
    fileprivate final class Sink: ArchiveByteStreamProtocol {
        let url: URL
        let fd: Int32
        let hook: BackupFileHook?
        let local: Bool
        private(set) var size: Int64 = 0
        private(set) var failure: Error?
        private var hasher = SHA256()
        private var sequential = true
        private var closed = false

        init(url: URL, hook: BackupFileHook?, local: Bool = false) throws {
            self.url = url
            self.hook = hook
            self.local = local
            do {
                try hook?(.write(url.path, bytes: 0))
                let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o644)
                guard fd >= 0 else { throw Errno(rawValue: errno) }
                self.fd = fd
            } catch {
                throw BackupEngine.classify(error, local: local, detail: "create")
            }
        }

        deinit { if !closed { Darwin.close(fd) } }

        /// SHA-256 of the bytes when they were all written in order; nil otherwise.
        var sequentialDigest: String? { sequential ? hasher.finalize().hex : nil }

        func writeAll(_ data: Data) throws {
            try data.withUnsafeBytes { try write($0) }
        }

        func write(_ buffer: UnsafeRawBufferPointer) throws {
            _ = try put(buffer, at: nil)
        }

        /// Flushes the file to the media, then closes it.
        func finish() throws {
            guard !closed else { return }
            do {
                try hook?(.flush(url.path))
                try BackupEngine.fullSync(fd)
            } catch {
                throw BackupEngine.classify(error, local: local, detail: "flush")
            }
            closed = true
            Darwin.close(fd)
        }

        private func put(_ buffer: UnsafeRawBufferPointer, at offset: Int64?) throws -> Int {
            do {
                try hook?(.write(url.path, bytes: buffer.count))
                var done = 0
                while done < buffer.count {
                    let base = buffer.baseAddress! + done
                    let n = offset.map { pwrite(fd, base, buffer.count - done, $0 + Int64(done)) }
                        ?? Darwin.write(fd, base, buffer.count - done)
                    guard n > 0 else { throw Errno(rawValue: errno) }
                    done += n
                }
            } catch {
                let failure = BackupEngine.classify(error, local: local, detail: "write")
                self.failure = failure
                throw failure
            }
            if let offset {
                sequential = false
                size = max(size, offset + Int64(buffer.count))
            } else {
                hasher.update(bufferPointer: buffer)
                size += Int64(buffer.count)
            }
            return buffer.count
        }

        // ArchiveByteStreamProtocol
        func write(from buffer: UnsafeRawBufferPointer) throws -> Int { try put(buffer, at: nil) }
        func write(from buffer: UnsafeRawBufferPointer, atOffset offset: Int64) throws -> Int {
            try put(buffer, at: offset)
        }
        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int { throw Errno.notSupported }
        func read(into buffer: UnsafeMutableRawBufferPointer, atOffset offset: Int64) throws -> Int {
            let n = pread(fd, buffer.baseAddress, buffer.count, offset)
            guard n >= 0 else { throw Errno(rawValue: errno) }
            return n
        }
        func seek(toOffset offset: Int64, relativeTo origin: FileDescriptor.SeekOrigin) throws -> Int64 {
            throw Errno.notSupported
        }
        func cancel() {}
        func close() throws {}
    }
}

extension SHA256.Digest {
    fileprivate var hex: String { map { String(format: "%02x", $0) }.joined() }
}
