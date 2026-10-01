import Foundation
import Testing

@testable import BlaiseApp

private func run(_ tool: String, _ arguments: [String], environment: [String: String]? = nil)
    throws -> (status: Int32, output: String)
{
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    if let environment { process.environment = environment }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("connect-claude-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// Serialized: every bundle is written to the same temporary path.
@Suite(.serialized) struct ConnectClaudeTests {
    private let helper = "/Applications/Blaise.app/Contents/Helpers/blaise-mcp"

    // T9
    @Test func bundleHasExactlyTheLauncherAndManifest() throws {
        let bundle = try ClaudeConnection.writeBundle(helperPath: helper, version: "1.9.2", dataRoot: nil)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let listing = try run("/usr/bin/unzip", ["-Z", bundle.path]).output
            .split(separator: "\n").filter { $0.hasPrefix("d") || $0.hasPrefix("-") }
        let entries = listing.map { ($0.split(separator: " ").last.map(String.init) ?? "", String($0.prefix(10))) }
        #expect(entries.map(\.0).sorted() == ["manifest.json", "server/", "server/blaise-meetings"])
        #expect(entries.first { $0.0 == "server/blaise-meetings" }?.1 == "-rwxr-xr-x")
        #expect(!listing.contains { $0.contains("__MACOSX") })

        let unpacked = try scratch()
        defer { try? FileManager.default.removeItem(at: unpacked) }
        #expect(try run("/usr/bin/unzip", ["-q", bundle.path, "-d", unpacked.path]).status == 0)
        let data = try Data(contentsOf: unpacked.appendingPathComponent("manifest.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let server = try #require(manifest["server"] as? [String: Any])
        let config = try #require(server["mcp_config"] as? [String: Any])
        let entryPoint = try #require(server["entry_point"] as? String)
        #expect(server["type"] as? String == "binary")
        #expect((config["command"] as? String)?.hasSuffix("/" + entryPoint) == true)
        #expect(config["command"] as? String == "${__dirname}/server/blaise-meetings")
        #expect((config["env"] as? [String: Any])?.isEmpty == true)
        #expect((manifest["author"] as? [String: Any])?["name"] as? String == "Blaise")
        #expect(manifest["manifest_version"] as? String == "0.3")
        #expect(manifest["name"] as? String == "blaise-meetings")
        #expect(manifest["version"] as? String == "1.9.2")
        #expect((manifest["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
            == ["search_meetings", "get_meeting", "get_transcript", "list_action_items"])
        #expect((manifest["compatibility"] as? [String: Any])?["platforms"] as? [String] == ["darwin"])
        let launcher = try String(contentsOf: unpacked.appendingPathComponent(entryPoint), encoding: .utf8)
        #expect(launcher == ClaudeConnection.launcher(helperPath: helper))
    }

    // T9, AC10
    @Test func overrideRootTravelsIntoTheBundleAbsolute() throws {
        let rootURL = try AppEnvironment.dataRoot(environment: ["BLAISE_DATA_ROOT": "quoll-harbor/dev root"])
        let root = try #require(ClaudeConnection.dataRootOverride(
            environment: ["BLAISE_DATA_ROOT": "quoll-harbor/dev root"], rootURL: rootURL))
        #expect(root.hasPrefix("/"))
        #expect(root.hasSuffix("/quoll-harbor/dev root"))
        #expect(ClaudeConnection.dataRootOverride(environment: [:], rootURL: rootURL) == nil)

        let data = try ClaudeConnection.manifest(version: "1.9.2", dataRoot: root)
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let config = try #require((manifest["server"] as? [String: Any])?["mcp_config"] as? [String: Any])
        #expect(config["env"] as? [String: String] == ["BLAISE_DATA_ROOT": root])
    }

    // T9: the launcher reaches exactly the helper path, with nothing expanded
    @Test func launcherQuotesHostilePaths() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appDir = dir.appendingPathComponent("Quoll's $(touch pwned) `touch pwned` App")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let fakeHelper = appDir.appendingPathComponent("blaise-mcp")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$0\" \"$@\" > \"$RECORD\"\n".utf8).write(to: fakeHelper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeHelper.path)

        let bundle = try ClaudeConnection.writeBundle(helperPath: fakeHelper.path, version: "0", dataRoot: nil)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let unpacked = dir.appendingPathComponent("unpacked")
        #expect(try run("/usr/bin/unzip", ["-q", bundle.path, "-d", unpacked.path]).status == 0)
        let record = dir.appendingPathComponent("record.txt")
        let launched = try run(
            unpacked.appendingPathComponent("server/blaise-meetings").path, ["one", "two words"],
            environment: ["RECORD": record.path, "PATH": "/usr/bin:/bin"])
        #expect(launched.status == 0, "\(launched.output)")
        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded == [fakeHelper.path, "one", "two words"].joined(separator: "\n") + "\n")
        let created = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!created.contains("pwned"))
        #expect(!FileManager.default.fileExists(atPath: appDir.appendingPathComponent("pwned").path))

        try FileManager.default.removeItem(at: fakeHelper)
        let missing = try run(unpacked.appendingPathComponent("server/blaise-meetings").path, [])
        #expect(missing.status == 1)
        #expect(missing.output == "Blaise is not installed at \(fakeHelper.path). Open Blaise and use Connect to Claude… again.\n")
    }

    // T10
    @Test func claudeCodeCommand() throws {
        #expect(ClaudeConnection.command(helperPath: helper, dataRoot: nil)
            == "claude mcp add --scope user blaise-meetings -- '/Applications/Blaise.app/Contents/Helpers/blaise-mcp'")
        #expect(ClaudeConnection.command(helperPath: helper, dataRoot: "/private/tmp/quoll root")
            == "claude mcp add --scope user blaise-meetings --env BLAISE_DATA_ROOT='/private/tmp/quoll root' -- '/Applications/Blaise.app/Contents/Helpers/blaise-mcp'")
        #expect(ClaudeConnection.command(helperPath: "/Apps/Quoll's Blaise.app/blaise-mcp", dataRoot: nil)
            == #"claude mcp add --scope user blaise-meetings -- '/Apps/Quoll'\''s Blaise.app/blaise-mcp'"#)

        let rootURL = try AppEnvironment.dataRoot(environment: ["BLAISE_DATA_ROOT": "vexatron-dev"])
        let root = try #require(ClaudeConnection.dataRootOverride(
            environment: ["BLAISE_DATA_ROOT": "vexatron-dev"], rootURL: rootURL))
        let command = ClaudeConnection.command(helperPath: helper, dataRoot: root)
        #expect(command == "claude mcp add --scope user blaise-meetings --env BLAISE_DATA_ROOT='\(root)' -- '\(helper)'")
        #expect(root.hasPrefix("/") && root.hasSuffix("/vexatron-dev"))
    }
}
