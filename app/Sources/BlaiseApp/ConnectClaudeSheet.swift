import AppKit
import SwiftUI

/// What the user needs to connect Claude to the bundled read-only helper:
/// a Claude Desktop bundle (`.mcpb`) and a Claude Code command. Blaise never
/// edits any client's configuration; the user completes every connection.
enum ClaudeConnection {
    static let disclosure =
        "Claude will be able to search and read all your meeting notes and transcripts. "
        + "What it reads is sent to Claude as part of your chat. If Claude can also use tools "
        + "that reach the web, e-mail or other apps, it could send what it reads there too. "
        + "What you connect, and what you let it do, is up to you."

    static let longDescription = """
        How to answer questions about meetings:

        1. Find the meeting(s): search_meetings with words, a date range, and/or a person. With no words it lists meetings newest first. Don't read transcripts to locate a meeting.
        2. Read get_meeting first. The notes, decisions, action items and (when present) the digest answer most questions: what was decided, who owns what, figures, next steps.
        3. Use get_transcript only for exact wording, who said what, or detail the notes missed. Filter with `contains`, `speaker`, or a time window, and add `context` around matches. Don't page through a whole transcript unless the user asks for it.
        4. For "my open action items" use list_action_items with no arguments. Only the user's own items have a done/open state.
        """

    static func helperPath(appBundle: URL) -> String {
        appBundle.appendingPathComponent("Contents/Helpers/blaise-mcp").path
    }

    /// The app's resolved absolute data root when it runs under a
    /// `BLAISE_DATA_ROOT` override, so a dev build never connects an agent to
    /// the production library; nil otherwise.
    static func dataRootOverride(environment: [String: String], rootURL: URL) -> String? {
        environment["BLAISE_DATA_ROOT"] == nil ? nil : rootURL.path
    }

    /// Single-quoted for `sh`, with `'` escaped.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `--env` takes several values, so it goes after the name and before `--`.
    static func command(helperPath: String, dataRoot: String?) -> String {
        var command = "claude mcp add --scope user blaise-meetings"
        if let dataRoot { command += " --env BLAISE_DATA_ROOT=" + shellQuoted(dataRoot) }
        return command + " -- " + shellQuoted(helperPath)
    }

    static func launcher(helperPath: String) -> String {
        """
        #!/bin/sh
        H=\(shellQuoted(helperPath))
        [ -x "$H" ] || { echo "Blaise is not installed at $H. Open Blaise and use Connect to Claude… again." >&2; exit 1; }
        exec "$H" "$@"

        """
    }

    static func manifest(version: String, dataRoot: String?) throws -> Data {
        let tools = [
            ("search_meetings", "Find meetings by words, dates, or person"),
            ("get_meeting", "Read one meeting's notes and action items"),
            ("get_transcript", "Read a meeting's transcript, filtered"),
            ("list_action_items", "List action items across meetings"),
        ]
        let manifest: [String: Any] = [
            "manifest_version": "0.3",
            "name": "blaise-meetings",
            "display_name": "Blaise Meetings",
            "version": version,
            "description": "Search and read your Blaise meetings: notes, action items, transcripts. Read-only.",
            "long_description": longDescription,
            "author": ["name": "Blaise"],
            "server": [
                "type": "binary",
                "entry_point": "server/blaise-meetings",
                "mcp_config": [
                    "command": "${__dirname}/server/blaise-meetings",
                    "args": [String](),
                    "env": dataRoot.map { ["BLAISE_DATA_ROOT": $0] } ?? [:],
                ] as [String: Any],
            ] as [String: Any],
            "tools": tools.map { ["name": $0.0, "description": $0.1] },
            "compatibility": ["platforms": ["darwin"]],
        ]
        return try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    struct ZipFailed: Error {}

    /// Writes `blaise-meetings.mcpb` (the manifest plus an executable launcher)
    /// into the temporary directory. `--norsrc` keeps the zip to exactly those
    /// files; extended attributes would otherwise add `__MACOSX/` entries.
    static func writeBundle(helperPath: String, version: String, dataRoot: String?) throws -> URL {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("blaise-meetings-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        let server = staging.appendingPathComponent("server")
        try fileManager.createDirectory(at: server, withIntermediateDirectories: true)
        try manifest(version: version, dataRoot: dataRoot).write(to: staging.appendingPathComponent("manifest.json"))
        let launcherURL = server.appendingPathComponent("blaise-meetings")
        try Data(launcher(helperPath: helperPath).utf8).write(to: launcherURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)

        let bundle = fileManager.temporaryDirectory.appendingPathComponent("blaise-meetings.mcpb")
        try? fileManager.removeItem(at: bundle)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--norsrc", staging.path, bundle.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw ZipFailed() }
        return bundle
    }
}

/// Blaise → Connect to Claude…: the disclosure note, the Claude Desktop
/// bundle button and the Claude Code command. Persists nothing.
struct ConnectClaudeSheet: View {
    @Environment(AppEnvironment.self) private var appEnv
    let onClose: () -> Void

    @State private var desktopMissing = false
    @State private var copied = false

    private var helperPath: String { ClaudeConnection.helperPath(appBundle: Bundle.main.bundleURL) }
    private var dataRoot: String? {
        ClaudeConnection.dataRootOverride(
            environment: ProcessInfo.processInfo.environment, rootURL: appEnv.database.rootURL)
    }
    private var command: String { ClaudeConnection.command(helperPath: helperPath, dataRoot: dataRoot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to Claude")
                .font(.title3.weight(.semibold))
            Text(ClaudeConnection.disclosure)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Claude Desktop or Cowork")
                    Spacer()
                    Button("Add to Claude Desktop") { addToClaudeDesktop() }
                }
                if desktopMissing {
                    Text("Claude Desktop isn't installed on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Code")
                HStack(alignment: .top) {
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") { copyCommand() }
                }
            }

            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onExitCommand { onClose() }
    }

    private func addToClaudeDesktop() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard
            let bundle = try? ClaudeConnection.writeBundle(
                helperPath: helperPath, version: version, dataRoot: dataRoot)
        else { return }
        guard NSWorkspace.shared.urlForApplication(toOpen: bundle) != nil else {
            try? FileManager.default.removeItem(at: bundle)
            desktopMissing = true
            return
        }
        NSWorkspace.shared.open(bundle)
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
