import Foundation
import GRDB
import Testing

@testable import BlaiseCore
@testable import BlaiseMCPServer

private func run(_ tool: String, _ arguments: [String], stdin: Data? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let input = Pipe()
    process.standardInput = input
    try process.run()
    if let stdin { input.fileHandleForWriting.write(stdin) }
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

@Suite struct MCPReadOnlyTests {
    // T5
    @Test func conformanceRunLeavesTheLibraryUnchanged() async throws {
        let library = try await Library.seeded()
        let aurora = try library.id("Aurora Drift — post-launch sync")
        try await ActionItemStateRepository(database: library.database)
            .markDone(meetingID: aurora, itemText: "Confirm OrbitVR staffing with Carlos Mendes by Friday.")
        try library.execute(
            #"UPDATE meeting_notes SET structured = replace(structured, '"user_action_items"', '"ric_action_items"') WHERE meeting_id = ?"#,
            [try library.id("Tidewatch — prototype review")])
        try library.database.pool.close()

        let checksum = try libraryChecksum(library.dbPath)
        let files = fileNames(under: library.root)

        let helper = try HelperProcess(root: library.root)
        _ = try helper.request("initialize", ["protocolVersion": "2025-11-25"])
        try helper.sendLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        _ = try helper.request("ping")
        _ = try helper.request("tools/list")
        _ = try helper.pages("search_meetings", ["limit": 3])
        _ = try helper.json("search_meetings", ["query": "decisão", "person": "Carlos", "from": "2026-01-01", "to": "2026-12-31"])
        _ = try helper.json("search_meetings", ["query": "freeze"])
        for id in try helper.pages("search_meetings", ["limit": 25]).flatMap({ $0["meetings"] as? [[String: Any]] ?? [] })
            .compactMap({ $0["meeting_id"] as? String })
        {
            _ = try helper.json("get_meeting", ["meeting_id": id])
            _ = try helper.json("get_transcript", ["meeting_id": id])
            _ = try helper.json("get_transcript", ["meeting_id": id, "contains": "the", "speaker": "a", "context": 2])
        }
        for state in ["open", "done", "all"] {
            _ = try helper.pages("list_action_items", ["owner": "*", "state": state, "limit": 5])
        }
        for (line, _, _) in invalidEnvelopes { _ = try helper.exchange(line) }
        for (tool, arguments, _) in invalidArguments(validID: aurora) { _ = try helper.call(tool, arguments) }
        #expect(try helper.finish() == 0)

        #expect(try libraryChecksum(library.dbPath) == checksum)
        #expect(fileNames(under: library.root) == files)

        let writer = try DatabaseQueue(path: library.dbPath)
        try await writer.write { db in
            try db.execute(sql: "UPDATE meeting SET title = title || '.' WHERE id = ?", arguments: [aurora])
        }
        try writer.close()
        #expect(try libraryChecksum(library.dbPath) != checksum)
    }

    // T5: the helper's connection refuses writes
    @Test func connectionRefusesWrites() async throws {
        let library = try await Library.seeded()
        let queue = try BlaiseMCPServer.openReadOnly(path: library.dbPath)
        defer { try? queue.close() }
        do {
            try queue.inDatabase { db in
                try db.execute(sql: "INSERT INTO app_setting(key, value) VALUES ('probe', '1')")
            }
            Issue.record("a write on the helper's connection succeeded")
        } catch let error as DatabaseError {
            #expect(error.resultCode.primaryResultCode == .SQLITE_READONLY)
            #expect(error.resultCode.primaryResultCode.rawValue == 8)
        }
    }

    // T8
    @Test func noNetworkingOrSpawnSymbols() throws {
        let deny = try NSRegularExpression(
            pattern: #"^_(socket|connect|getaddrinfo|gethostbyname|sendto|sendmsg|bind|listen|accept|posix_spawnp?|execv[pe]?|execl[pe]?|system|popen|fork|vfork)$|URLSession|NSURLConnection|NSStream|CFStream|CFSocket|CFHost|CFHTTP|_nw_|init\(contentsOf:|NSTask"#)
        let undefined = try run("/usr/bin/nm", ["-u", helperURL.path])
        let symbols = try run("/usr/bin/xcrun", ["swift-demangle", "--simplified"], stdin: Data(undefined.utf8))
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(symbols.count > 50)
        let hits = symbols.filter { deny.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        #expect(hits.isEmpty, "denylisted symbols: \(hits)")

        let linked = try run("/usr/bin/otool", ["-L", helperURL.path])
        #expect(linked.contains("Foundation"))
        for framework in ["CFNetwork", "Network", "CoreML", "AVFAudio", "AVFoundation"] {
            #expect(!linked.contains("/\(framework).framework/"), "\(framework) is linked")
        }
    }

    // T12
    @Test func actionItemKeyMatchesTheApp() {
        let corpus = [
            "Revisar as ações do trimestre com a Quoll Harbor.",
            "Revisar as acoes do trimestre com a Quoll Harbor.",
            "REVISAR AS AÇÕES DO TRIMESTRE COM A QUOLL HARBOR.",
            "Send Wren Quill’s build to the Vexatron team.",
            "Send Wren Quill's build to the Vexatron team.",
            "tabs\tand  double  spaces\n and a newline",
            "Ship the Nimbus patch 🚀 before the tide 🌊",
            "",
            "   ",
            "Çedilha, ñandú, Ærø, straße",
        ]
        for text in corpus {
            #expect(BlaiseMCPServer.actionItemKey(text) == ActionItemKey.key(for: text), "\(text)")
        }
    }

    // T13
    @Test func schemaPinMatchesTheLastMigration() {
        #expect(BlaiseDatabase.migrator.migrations.last == BlaiseMCPServer.expectedSchema)
    }
}
