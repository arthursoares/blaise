import AppKit
import BlaiseCore
import SwiftUI

// Settings → Backup: the folder, the status line, Back Up Now, encryption and restore.
// Recording and paused state are read only in leaf views (the Restore row and the Quit button),
// so a capture state change never re-renders the tab.

struct BackupSettingsTab: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var model: BackupSettingsModel?

    var body: some View {
        Form {
            if let model {
                BackupSection(model: model)
            }
        }
        .formStyle(.grouped)
        .sheet(
            isPresented: Binding(
                get: { model?.pendingPassword != nil },
                set: { if !$0 { model?.cancelEncryption() } })
        ) {
            if let model { PasswordSheet(model: model) }
        }
        .sheet(
            isPresented: Binding(
                get: { model?.restoreStep != nil },
                set: { if !$0, let model { Task { await model.cancelRestore() } } })
        ) {
            if let model { RestoreSheet(model: model) }
        }
        .task {
            let model = self.model ?? BackupSettingsModel(
                engine: appEnv.backupEngine, database: appEnv.database,
                confirmRestore: { [appEnv] in appEnv.confirmRestoreAndQuit($0) })
            self.model = model
            await model.refresh(checkDisk: true)
            // The hourly tick can start a run while the tab is open; Back Up Now and Restore
            // follow it.
            await model.poll(every: .seconds(2))
        }
    }
}

private struct BackupSection: View {
    @Bindable var model: BackupSettingsModel

    var body: some View {
        Section("Backup") {
            Text("A daily copy of your meetings, glossary and recordings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Folder") {
                Text(model.folderPath ?? "None chosen")
                    .foregroundStyle(model.folderPath == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("Choose Folder…") { chooseFolder() }
                .accessibilityLabel("Choose backup folder")
            if let error = model.folderError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }

            Text(model.statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.onSameDisk {
                Text(BackupSettingsModel.sameDiskLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(model.isBackingUp ? "Backing up…" : "Back Up Now") {
                Task { await model.backUpNow() }
            }
            .disabled(!model.canBackUpNow)
            if let notice = model.backUpNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }

            Toggle(
                "Encrypt backups",
                isOn: Binding(
                    get: { model.state.isEncrypted },
                    set: { on in
                        Task {
                            if on { await model.beginEnableEncryption() } else { await model.disableEncryption() }
                        }
                    }))
            if let error = model.encryptionError, model.pendingPassword == nil {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }

            RestoreRow(model: model)

            Text(LocalizedStringKey(BackupSettingsModel.helpText))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder Blaise backs up to."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            await model.chooseFolder(url)
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }
}

/// Reads the recording state, so it re-renders alone when a recording starts or stops; it also
/// tells the model when a recording ends.
private struct RestoreRow: View {
    let model: BackupSettingsModel
    @Environment(AppEnvironment.self) private var appEnv

    var body: some View {
        let isRecording = appEnv.captureStatus.isRecording
        let reason = model.restoreUnavailableReason(isRecording: isRecording)
        HStack {
            Button("Restore from Backup…") { Task { await model.beginRestore() } }
                .disabled(reason != nil)
            if let reason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        // `initial`: a recording that ended while the tab was off screen clears the refusal too.
        .onChange(of: isRecording, initial: true) { _, recording in
            if !recording { model.recordingEnded() }
        }
    }
}

// MARK: - Password sheet

private struct PasswordSheet: View {
    let model: BackupSettingsModel
    @Environment(AppEnvironment.self) private var appEnv
    @State private var window: NSWindow?

    var body: some View {
        let password = model.pendingPassword ?? ""
        VStack(alignment: .leading, spacing: 14) {
            Text("Encrypt backups").font(.headline)
            Text(password)
                .font(.title3.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                .accessibilityLabel("Generated backup password")
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(password, forType: .string)
                }
                Button("Print…") {
                    guard let window else { return }
                    // One print operation per thread: wait for any PDF export's.
                    model.printPassword { password in
                        await appEnv.pdfExporter.withPrintGate { await printPassword(password, on: window) }
                    }
                }
                .disabled(window == nil || !model.canPrint)
            }
            Text(BackupSettingsModel.savePasswordLine)
            if model.showsUnencryptedNotice {
                Text(BackupSettingsModel.unencryptedNotice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = model.encryptionError {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelEncryption() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSavingEncryption || model.isPrinting)
                Button("Encrypt Backups") { Task { await model.confirmEncryption() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConfirmEncryption)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(WindowAccessor { if window !== $0 { window = $0 } })
    }

    private func printPassword(_ password: String, on window: NSWindow) async {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 160))
        view.string = "Blaise backup password\n\n\(password)\n\n\(BackupSettingsModel.savePasswordLine)\n"
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        _ = await PDFExporter.runPrint(NSPrintOperation(view: view), for: window)
    }
}

// MARK: - Restore sheets

private struct RestoreSheet: View {
    @Bindable var model: BackupSettingsModel
    @State private var selection: RestoreSnapshot.ID?
    @State private var typedPassword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore from Backup").font(.headline)
            switch model.restoreStep {
            case .pick?: pick
            case .verifying?: verifying
            case .password(let incorrect)?: passwordPrompt(incorrect: incorrect)
            case .confirm(let staged, let after)?: confirm(staged, meetingsAfter: after)
            case .message(let text)?: message(text)
            case nil: EmptyView()
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var pick: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isListing {
                ProgressView().controlSize(.small)
            } else if model.snapshots.isEmpty {
                Text("No backups found in this folder.").foregroundStyle(.secondary)
            } else {
                List(model.snapshots, selection: $selection) { snapshot in
                    HStack {
                        Image(systemName: snapshot.manifest?.encrypted == true ? "lock.fill" : "lock.open")
                            .opacity(snapshot.manifest?.encrypted == true ? 1 : 0)
                            .accessibilityHidden(snapshot.manifest?.encrypted != true)
                            .accessibilityLabel("Encrypted")
                        Text(model.rowText(snapshot))
                            .foregroundStyle(snapshot.manifest == nil ? .secondary : .primary)
                    }
                    .selectionDisabled(snapshot.manifest == nil)
                }
                .frame(minHeight: 180)
            }
            HStack {
                Button("Choose Other Folder…") { chooseOtherFolder() }
                Spacer()
                Button("Cancel") { Task { await model.cancelRestore() } }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    if let picked = model.snapshots.first(where: { $0.id == selection }) { model.verify(picked) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.snapshots.first(where: { $0.id == selection })?.manifest == nil)
            }
        }
    }

    private var verifying: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProgressView().controlSize(.small)
                Text("Verifying the backup…")
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelVerify() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func passwordPrompt(incorrect: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This backup is encrypted. Enter its password.")
            SecureField("Password", text: $typedPassword)
                .font(.body.monospaced())
            if incorrect {
                Text(BackupRestore.passwordIncorrectMessage).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { Task { await model.cancelRestore() } }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    if let picked = model.pickedSnapshot { model.verify(picked, password: typedPassword) }
                    typedPassword = ""
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func confirm(_ staged: StagedRestore, meetingsAfter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.confirmLines(staged, meetingsAfter: meetingsAfter), id: \.self) { line in
                Text(line).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { Task { await model.cancelRestore() } }
                    .keyboardShortcut(.cancelAction)
                QuitAndRestoreButton(model: model)
            }
        }
    }

    private func message(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK") { Task { await model.cancelRestore() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func chooseOtherFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds your Blaise backups."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selection = nil
        Task { await model.listSnapshots(in: url) }
    }
}

/// Reads the recording and paused state, so it re-renders alone when either changes.
struct QuitAndRestoreButton: View {
    let model: BackupSettingsModel
    @Environment(AppEnvironment.self) private var appEnv

    /// A paused meeting counts even while the indicator shows another meeting's grace window,
    /// processing or alarm.
    static func captureState(_ status: CaptureStatusHolder) -> (isRecording: Bool, isPaused: Bool) {
        (status.isRecording, status.pausedMeetingID != nil)
    }

    var body: some View {
        let (isRecording, isPaused) = Self.captureState(appEnv.captureStatus)
        Button("Quit Blaise and Restore") {
            model.quitAndRestore(isRecording: isRecording, isPaused: isPaused)
        }
        .disabled(!BackupSettingsModel.canQuitAndRestore(isRecording: isRecording, isPaused: isPaused))
    }
}
