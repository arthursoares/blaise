import Foundation
import GRDB

/// State and decisions of the Settings Backup tab and its sheets. Every engine call runs in the
/// caller's task and suspends; the engine can hold its actor through a long file copy, so the
/// model sets its own flags before each call and never makes the main actor wait on it.
@MainActor @Observable
public final class BackupSettingsModel {
    /// Where the restore sheet is.
    public enum RestoreStep: Equatable {
        case pick
        case verifying
        /// Encrypted and the stored password did not open it; `incorrect` after a typed one failed.
        case password(incorrect: Bool)
        case confirm(StagedRestore, meetingsAfter: Bool)
        /// A refusal or a stop; the sheet shows the text and a close button.
        case message(String)
    }

    public static let recordingRefusal = "Not available while a meeting is recording."
    public static let backingUpRefusal = "Not available while a backup is running."
    public static let stagingBusyMessage = "A backup is running. Try again when it finishes."

    public private(set) var state = BackupState()
    /// The chosen folder's path as bookmarked; shown even while the folder is not reachable.
    public private(set) var folderPath: String?
    public private(set) var onSameDisk = false
    /// A run is in flight: one this tab started, or one the engine reports (the hourly tick).
    public var isBackingUp: Bool { localRuns > 0 || engineRunInFlight }
    /// The refusal of the last Back Up Now, when it was refused.
    public private(set) var backUpNotice: String?
    public private(set) var folderError: String?

    /// The generated password while its sheet is up; nil otherwise.
    public private(set) var pendingPassword: String?
    public private(set) var showsUnencryptedNotice = false
    public private(set) var encryptionError: String?
    /// Encrypt Backups was pressed and the engine has not answered yet; Cancel no longer applies.
    public private(set) var isSavingEncryption = false
    /// Whether the earlier-backups line applies is not known yet; Encrypt Backups waits for it.
    public private(set) var isCheckingUnencrypted = false
    /// Print… was pressed and its print has not finished (it may be waiting for another print).
    /// The print's panel is a sheet on this sheet, so this sheet stays up until it finishes.
    public private(set) var isPrinting = false
    public var canConfirmEncryption: Bool { !isSavingEncryption && !isCheckingUnencrypted && !isPrinting }
    /// A save can close the sheet under a print, so Print… waits for the save to finish.
    public var canPrint: Bool { !isPrinting && !isSavingEncryption }

    public var restoreStep: RestoreStep?
    public private(set) var snapshots: [RestoreSnapshot] = []
    public private(set) var isListing = false
    /// The snapshot being verified; a typed password retries it.
    public private(set) var pickedSnapshot: RestoreSnapshot?

    private var localRuns = 0
    private var engineRunInFlight = false
    private var isStaging = false
    private var stagingTask: Task<Void, Never>?

    private let engine: BackupEngine
    private let database: BlaiseDatabase
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    private let generatePassword: () throws -> String
    private let confirmRestore: (StagedRestore) -> Void

    public init(
        engine: BackupEngine,
        database: BlaiseDatabase,
        now: @escaping () -> Date = { Date() },
        timeZone: @escaping () -> TimeZone = { .autoupdatingCurrent },
        generatePassword: @escaping () throws -> String = { try BackupEngine.generatePassword() },
        confirmRestore: @escaping (StagedRestore) -> Void
    ) {
        self.engine = engine
        self.database = database
        self.now = now
        self.timeZone = timeZone
        self.generatePassword = generatePassword
        self.confirmRestore = confirmRestore
    }

    private var dataRoot: URL { database.rootURL }

    // MARK: - Status

    /// Reads whether a run is in flight, then the engine's state (which waits while the engine is
    /// in a synchronous step). `checkDisk` also re-checks the same-disk line (when the tab appears).
    public func refresh(checkDisk: Bool = false) async {
        engineRunInFlight = engine.isBusyNow && !isStaging
        let current = await engine.state()
        state = current
        engineRunInFlight = engine.isBusyNow && !isStaging
        folderPath = current.destinationBookmark.flatMap {
            URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: $0)?.path
        }
        if checkDisk { await updateSameDisk(current.destinationBookmark) }
    }

    /// Refreshes every `interval` until the calling task is cancelled; a cancelled wait
    /// refreshes nothing.
    public func poll(every interval: Duration) async {
        while true {
            do { try await Task.sleep(for: interval) } catch { return }
            await refresh()
        }
    }

    public var statusLine: String {
        Self.statusLine(state, now: now(), timeZone: timeZone())
    }

    /// "Last backup: today, 02:14" / "Last backup: 3 days ago" / "No backup yet"; from 7 days on,
    /// the stale wording with its reason.
    public static func statusLine(_ state: BackupState, now: Date, timeZone: TimeZone) -> String {
        if let stale = state.staleLine(now: now) { return stale }
        guard let last = state.lastSuccessAt else { return "No backup yet" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Calendar days, capped below the stale line's elapsed 7 days: 7 calendar days can be
        // less than 7 elapsed, and "7 days ago" must come with its reason.
        let days = min(abs(calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: now)
        ).day ?? 0), 6)
        switch days {
        case 0: return "Last backup: today, \(format(last, "HH:mm", timeZone))"
        case 1: return "Last backup: 1 day ago"
        default: return "Last backup: \(days) days ago"
        }
    }

    public static let sameDiskLine =
        "This folder is on the same disk as your library, so it won't protect you if that disk fails."

    /// Equal volume identifiers. A separate volume or partition on the same drive is not detected.
    public nonisolated static func isOnSameDisk(_ folder: URL, as dataRoot: URL) -> Bool {
        func volume(_ url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let a = volume(folder), let b = volume(dataRoot) else { return false }
        return a.isEqual(b)
    }

    private func updateSameDisk(_ bookmark: Data?) async {
        guard let bookmark else { onSameDisk = false; return }
        let root = dataRoot
        onSameDisk = await Task.detached {
            var stale = false
            guard let folder = try? URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &stale)
            else { return false }
            return Self.isOnSameDisk(folder, as: root)
        }.value
    }

    // MARK: - Folder and Back Up Now

    /// Stores the folder; the engine then backs up at once, so this returns when that run ends.
    public func chooseFolder(_ url: URL) async {
        folderError = nil
        folderPath = url.path
        let root = dataRoot
        onSameDisk = await Task.detached { Self.isOnSameDisk(url, as: root) }.value
        localRuns += 1
        do {
            _ = try await engine.chooseFolder(url)
        } catch {
            folderError = "Could not use this folder: \(error.localizedDescription)"
        }
        localRuns -= 1
        // The same-disk line follows the stored folder, which a failed choice did not replace.
        await refresh(checkDisk: true)
    }

    public var canBackUpNow: Bool { state.isConfigured && !isBackingUp }

    /// The recording refusal no longer applies once the recording ends.
    public func recordingEnded() {
        if backUpNotice == Self.recordingRefusal { backUpNotice = nil }
    }

    public func backUpNow() async {
        guard canBackUpNow else { return }
        backUpNotice = nil
        localRuns += 1
        let outcome = await engine.backUpNow()
        localRuns -= 1
        if outcome == .recording { backUpNotice = Self.recordingRefusal }
        await refresh()
    }

    // MARK: - Encryption

    /// Turning the toggle on: a generated password and its sheet; nothing is stored yet. A run in
    /// flight decides the earlier-backups line at once; otherwise Encrypt Backups waits for the
    /// namespace check, which can wait behind the engine.
    public func beginEnableEncryption() async {
        encryptionError = nil
        let password: String
        do {
            password = try generatePassword()
        } catch {
            encryptionError = "Could not generate a password: \(error.localizedDescription)"
            return
        }
        pendingPassword = password
        showsUnencryptedNotice = isBackingUp || (engine.isBusyNow && !isStaging)
        isCheckingUnencrypted = !showsUnencryptedNotice
        guard isCheckingUnencrypted else { return }
        let plaintext = await engine.hasUnencryptedSnapshots()
        // A sheet cancelled meanwhile, or opened again, is not this one.
        guard pendingPassword == password else { return }
        showsUnencryptedNotice = plaintext || (engine.isBusyNow && !isStaging)
        isCheckingUnencrypted = false
    }

    /// Encrypt Backups: the password goes to the Keychain and a new key starts.
    public func confirmEncryption() async {
        guard let password = pendingPassword, !isSavingEncryption, !isPrinting else { return }
        isSavingEncryption = true
        do {
            try await engine.enableEncryption(password: password)
            pendingPassword = nil
        } catch {
            encryptionError = "The password could not be saved: \(error.localizedDescription)"
        }
        isSavingEncryption = false
        await refresh()
    }

    /// Cancel stores nothing; once Encrypt Backups or Print… is pressed it no longer applies
    /// until that finishes.
    public func cancelEncryption() {
        guard !isSavingEncryption, !isPrinting else { return }
        pendingPassword = nil
        encryptionError = nil
    }

    /// Print…: `print` gets the password and returns when its print has finished. The flag is set
    /// before this returns, so a key press handled next already sees it.
    public func printPassword(_ print: @escaping @MainActor (String) async -> Void) {
        guard let password = pendingPassword, canPrint else { return }
        isPrinting = true
        Task {
            await print(password)
            isPrinting = false
        }
    }

    public func disableEncryption() async {
        do {
            try await engine.disableEncryption()
        } catch {
            encryptionError = "Could not turn encryption off: \(error.localizedDescription)"
        }
        await refresh()
    }

    public static let savePasswordLine =
        "Save this password in Passwords or your password manager — without it this backup cannot be restored."
    public static let unencryptedNotice =
        "Your earlier, unencrypted backups stay in the folder until they age out, usually after about a year of regular backups, longer if backups stop, except those from another Mac or an earlier library location, which stay until you delete them."

    // MARK: - Restore

    /// Restore from Backup… is unavailable, with this reason, while recording or backing up.
    public func restoreUnavailableReason(isRecording: Bool) -> String? {
        if isRecording { return Self.recordingRefusal }
        if isBackingUp { return Self.backingUpRefusal }
        return nil
    }

    /// Opens the pick step with the configured destination's snapshots.
    public func beginRestore() async {
        restoreStep = .pick
        snapshots = []
        isListing = true
        snapshots = await engine.restoreSnapshots()
        isListing = false
    }

    /// Choose Other Folder…: lists the snapshots under `folder` instead.
    public func listSnapshots(in folder: URL) async {
        isListing = true
        snapshots = await engine.restoreSnapshots(in: folder)
        isListing = false
    }

    /// Verify and stage in the background; `cancelVerify()` stops it and staging deletes itself.
    public func verify(_ snapshot: RestoreSnapshot, password: String? = nil) {
        guard snapshot.manifest != nil, !isStaging else { return }
        pickedSnapshot = snapshot
        restoreStep = .verifying
        isStaging = true
        stagingTask = Task {
            let outcome = await engine.stageRestore(snapshot, password: password)
            isStaging = false
            await show(outcome)
        }
    }

    /// Waits for the verify step started by `verify` to finish.
    public func waitForVerify() async { await stagingTask?.value }

    public func cancelVerify() { stagingTask?.cancel() }

    private func show(_ outcome: RestoreStageOutcome) async {
        switch outcome {
        case .staged(let staged):
            let after = await meetingsRecorded(after: staged.createdAt)
            restoreStep = .confirm(staged, meetingsAfter: after)
        case .needsPassword: restoreStep = .password(incorrect: false)
        case .passwordIncorrect: restoreStep = .password(incorrect: true)
        case .refused(let message): restoreStep = .message(message)
        case .recordingStarted: restoreStep = .message(BackupRestore.recordingStartedMessage)
        case .busy: restoreStep = .message(Self.stagingBusyMessage)
        case .cancelled: restoreStep = nil
        }
    }

    /// Whether the library has meetings created after `date`, which the restored one will not show.
    private func meetingsRecorded(after date: Date) async -> Bool {
        let count = try? await database.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meeting WHERE created_at > ?", arguments: [date]) ?? 0
        }
        return (count ?? 0) > 0
    }

    /// Closes the restore sheet; a staged restore that was not confirmed is deleted.
    public func cancelRestore() async {
        if case .confirm = restoreStep {
            let root = dataRoot
            await Task.detached { try? BackupRestore.discardStaging(dataRoot: root) }.value
        }
        restoreStep = nil
        pickedSnapshot = nil
    }

    /// Quit Blaise and Restore is unavailable while recording or while a meeting is paused.
    public static func canQuitAndRestore(isRecording: Bool, isPaused: Bool) -> Bool {
        !isRecording && !isPaused
    }

    /// Closes the sheet, then hands the confirmed restore on: the app cannot quit while the sheet
    /// is attached. The step is already cleared when the dismissal calls `cancelRestore()`, so the
    /// staging is kept.
    public func quitAndRestore(isRecording: Bool, isPaused: Bool) {
        guard Self.canQuitAndRestore(isRecording: isRecording, isPaused: isPaused),
            case .confirm(let staged, _) = restoreStep
        else { return }
        restoreStep = nil
        pickedSnapshot = nil
        confirmRestore(staged)
    }

    /// The confirm sheet's text, then the lines that apply.
    public func confirmLines(_ staged: StagedRestore, meetingsAfter: Bool) -> [String] {
        Self.confirmLines(staged, meetingsAfter: meetingsAfter, now: now(), timeZone: timeZone())
    }

    public static func confirmLines(
        _ staged: StagedRestore, meetingsAfter: Bool, now: Date, timeZone: TimeZone
    ) -> [String] {
        let when = format(staged.createdAt, "d MMMM yyyy, HH:mm", timeZone)
        let setAside = format(now, "yyyy-MM-dd", timeZone)
        var lines = [
            "Blaise will quit and restore the backup from \(when) when it opens again. Your current library will be moved to \"Set Aside Before Restore \(setAside)\" in the Blaise data folder. Nothing is deleted. Meeting files already on this Mac are kept as they are."
        ]
        if staged.damagedCount > 0 {
            lines.append("\(staged.damagedCount) files in this backup are damaged and will be skipped.")
        }
        if meetingsAfter {
            let date = format(staged.createdAt, "d MMMM yyyy", timeZone)
            lines.append("Meetings recorded after \(date) will not appear in the library; their recordings stay on disk.")
        }
        return lines
    }

    /// A restore-list row: date and time, source Mac, app version, meeting count.
    public func rowText(_ snapshot: RestoreSnapshot) -> String {
        let tz = timeZone()
        let when = snapshot.date.map { Self.format($0, "d MMMM yyyy, HH:mm", tz) } ?? snapshot.name
        guard let m = snapshot.manifest else { return "\(when) — damaged" }
        return "\(when) — \(m.sourceName), Blaise \(m.appVersion), \(m.meetingCount) meetings"
    }

    public static let helpText =
        "Restoring moves your current library into a \"Set Aside Before Restore\" folder in the Blaise data folder; Blaise never deletes it. To undo a restore: Quit Blaise. Move `blaise.sqlite`, `blaise.sqlite-wal`, `blaise.sqlite-shm`, `Glossary.md`, `stoplist_user.txt` and `voice_profile` out of the Blaise data folder into a new folder, and keep it. Then move everything in the Set Aside folder back into the data folder. A backup opens without Blaise: `aea decrypt -password-value … -i data.aea -o data.aar` (encrypted backups only), then `aa extract -i data.aar -d out`. A synced folder (Dropbox, Google Drive, iCloud Drive) uploads everything Blaise writes into it."

    static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
