import Foundation
import Synchronization
import Testing
@testable import BlaiseCore

// The anchoring call on the account engine: one attempt, a 120 s timeout at
// the call site, and a link of the engine's one shared chain. No subprocess:
// a fake runner plays the CLI. Fictional data only.

private final class HeldRunner: @unchecked Sendable {
    struct Call: Sendable {
        let timeout: TimeInterval
        let isAnchoring: Bool
    }

    private struct State {
        var calls: [Call] = []
        var returned: [Int] = []
        var holds: [Int: EditorGate] = [:]
        var responses: [Int: ClaudeCodeSummarizationEngine.SubprocessOutcomeLike] = [:]
    }
    private let state = Mutex(State())
    let fallback: ClaudeCodeSummarizationEngine.SubprocessOutcomeLike

    init(fallback: ClaudeCodeSummarizationEngine.SubprocessOutcomeLike) {
        self.fallback = fallback
    }

    func hold(call index: Int) -> EditorGate {
        let gate = EditorGate()
        state.withLock { $0.holds[index] = gate }
        return gate
    }

    func respond(call index: Int, with outcome: ClaudeCodeSummarizationEngine.SubprocessOutcomeLike) {
        state.withLock { $0.responses[index] = outcome }
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var returned: [Int] { state.withLock { $0.returned } }

    var runner: ClaudeCodeSummarizationEngine.CommandRunner {
        { [self] _, args, _, _, timeout in
            let systemPromptFile = args.firstIndex(of: "--system-prompt-file").map { args[$0 + 1] }
            let system = systemPromptFile.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            let (index, gate, response) = state.withLock { state in
                let index = state.calls.count
                state.calls.append(Call(
                    timeout: timeout, isAnchoring: system == TimecodeAnchoring.systemPrompt))
                return (index, state.holds[index], state.responses[index])
            }
            if let gate { await gate.enterAndWait() }
            state.withLock { $0.returned.append(index) }
            return response ?? fallback
        }
    }
}

private func envelope(structured: String) -> ClaudeCodeSummarizationEngine.SubprocessOutcomeLike {
    .init(
        stdout: Data(#"{"type":"result","subtype":"success","is_error":false,"result":"prose","structured_output":\#(structured)}"#.utf8),
        exitStatus: 0)
}

private let anchorAnswer = #"{"anchors":[{"item":1,"segment":0,"quote":null}]}"#

private let notesAnswer = """
    {"title":"Harbor","summary":"Harbor review.","meeting_type":"project_review",
     "detailed_notes":"Discussion.","decisions":["Row C only"],
     "action_items":[{"owner":"Dana Marsh","text":"book the inspector"}],
     "user_action_items":[],"speaker_name_mapping":[]}
    """

private func makeEngine(
    runner: HeldRunner
) async throws -> (ClaudeCodeSummarizationEngine, BlaiseDatabase) {
    let database = try makeDatabase()
    let settings = SettingsStore(database: database)
    let secrets = InMemorySecretStore()
    try secrets.set(
        key: "engine.\(ClaudeCodeSummarizationEngine.engineID).\(ClaudeCodeSummarizationEngine.oauthTokenConfigKey)",
        value: "oauth-test-token-not-real")
    let binary = FileManager.default.temporaryDirectory
        .appendingPathComponent("blaise-fake-claude-\(UUID().uuidString)")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    try await settings.set(
        "engine.\(ClaudeCodeSummarizationEngine.engineID).\(ClaudeCodeSummarizationEngine.binaryPathConfigKey)",
        to: binary.path)
    let engine = ClaudeCodeSummarizationEngine(
        configuration: EngineConfiguration(
            engineID: ClaudeCodeSummarizationEngine.engineID,
            descriptors: ClaudeCodeSummarizationEngine.descriptors,
            settings: settings, secrets: secrets),
        ledger: CloudSpendLedger(database: database),
        homeDirectory: URL(fileURLWithPath: "/Users/fictional-tester"),
        runner: runner.runner)
    return (engine, database)
}

private func prompt() throws -> TimecodeAnchoring.Prompt {
    try #require(TimecodeAnchoring.prompt(
        meetingID: TimecodeFixtures.meetingID, structured: TimecodeFixtures.notes,
        segments: TimecodeFixtures.segments))
}

private func notesRequest() -> NotesRequest {
    let meeting = Meeting(
        id: "01JTC000000000000000000002", title: "Quoll Harbor sync", startedAt: msDate(),
        source: .meet, status: .processing, attendees: [], createdAt: msDate(),
        updatedAt: msDate())
    return NotesRequest(
        meeting: meeting,
        transcript: [
            TranscriptSegment(
                meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 4,
                speakerLabel: "S0", speakerName: "Dana Marsh", text: "Row C only, then."),
        ],
        dominantLanguage: "en", vocabulary: [], user: UserIdentity.onboardedUser)
}

private func yieldBriefly() async {
    for _ in 0..<50 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(50))
}

@Suite struct TimecodeEngineTests {
    // T-4: the anchoring call hands the runner 120 s; every other call 480 s.
    @Test func anchoringUses120SecondsAndOtherCalls480() async throws {
        let runner = HeldRunner(fallback: envelope(structured: anchorAnswer))
        runner.respond(call: 1, with: envelope(structured: notesAnswer))
        let (engine, database) = try await makeEngine(runner: runner)
        let fixed = try prompt()
        let answer = try await engine.anchorTimecodes(
            meetingID: TimecodeFixtures.meetingID, purpose: .generation, prepare: { fixed })
        #expect(answer?.response.contains("anchors") == true)
        _ = try await engine.generateNotes(notesRequest(), purpose: .generation)
        #expect(runner.calls.map(\.timeout) == [120, 480])
        #expect(runner.calls.map(\.isAnchoring) == [true, false])
        // The existing $0 receipt, under the caller's purpose, on success only.
        let purposes = try await database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT purpose FROM cloud_spend_receipt ORDER BY timestamp")
        }
        #expect(purposes == ["generation", "generation"])
    }

    @Test func nothingToSendMakesNoCall() async throws {
        let runner = HeldRunner(fallback: envelope(structured: anchorAnswer))
        let (engine, _) = try await makeEngine(runner: runner)
        let answer = try await engine.anchorTimecodes(
            meetingID: TimecodeFixtures.meetingID, purpose: .generation, prepare: { nil })
        #expect(answer == nil)
        #expect(runner.calls.isEmpty)
    }

    // T-4: a timed-out anchoring call releases the chain when the runner
    // returns, not before; the call queued behind it then runs.
    @Test func aCallQueuedBehindATimedOutAnchoringWaitsForTheRunner() async throws {
        let runner = HeldRunner(fallback: envelope(structured: notesAnswer))
        runner.respond(call: 0, with: .init(
            stdout: Data(), exitStatus: nil, terminationReason: .uncaughtSignal, timedOut: true))
        let gate = runner.hold(call: 0)
        let (engine, _) = try await makeEngine(runner: runner)
        let fixed = try prompt()
        let anchoring = Task {
            try await engine.anchorTimecodes(
                meetingID: TimecodeFixtures.meetingID, purpose: .generation, prepare: { fixed })
        }
        await gate.waitUntilEntered()
        let notes = Task { try await engine.generateNotes(notesRequest(), purpose: .generation) }
        await yieldBriefly()
        #expect(runner.calls.count == 1, "the notes call waits for the anchoring link")
        gate.release()
        await #expect(throws: EngineError.self) { _ = try await anchoring.value }
        _ = try await notes.value
        #expect(runner.calls.count == 2, "a timed-out anchoring call is one spawn")
        #expect(runner.returned == [0, 1])
    }

    // T-4: FIFO — a notes call behind two held anchoring calls runs after both.
    @Test func twoAnchoringCallsAheadDelayANotesCallUntilBothReturn() async throws {
        let runner = HeldRunner(fallback: envelope(structured: anchorAnswer))
        runner.respond(call: 2, with: envelope(structured: notesAnswer))
        let first = runner.hold(call: 0)
        let second = runner.hold(call: 1)
        let (engine, _) = try await makeEngine(runner: runner)
        let fixed = try prompt()
        let a = Task {
            try await engine.anchorTimecodes(
                meetingID: TimecodeFixtures.meetingID, purpose: .regeneration, prepare: { fixed })
        }
        await first.waitUntilEntered()
        let b = Task {
            try await engine.anchorTimecodes(
                meetingID: TimecodeFixtures.meetingID, purpose: .regeneration, prepare: { fixed })
        }
        await yieldBriefly()
        let notes = Task { try await engine.generateNotes(notesRequest(), purpose: .generation) }
        await yieldBriefly()
        #expect(runner.calls.count == 1)
        first.release()
        await second.waitUntilEntered()
        await yieldBriefly()
        #expect(runner.calls.count == 2, "the notes call still waits behind the second")
        second.release()
        _ = try await a.value
        _ = try await b.value
        _ = try await notes.value
        #expect(runner.calls.map(\.isAnchoring) == [true, true, false])
        #expect(runner.returned == [0, 1, 2])
    }

    // T-4: one subprocess attempt, whatever the failure.
    @Test func aTransientFailureIsOneSpawn() async throws {
        let overloaded = ClaudeCodeSummarizationEngine.SubprocessOutcomeLike(
            stdout: Data(#"{"type":"result","subtype":"error","is_error":true,"api_error_status":529,"result":"overloaded"}"#.utf8),
            exitStatus: 1)
        let runner = HeldRunner(fallback: overloaded)
        let (engine, database) = try await makeEngine(runner: runner)
        let fixed = try prompt()
        await #expect(throws: EngineError.self) {
            _ = try await engine.anchorTimecodes(
                meetingID: TimecodeFixtures.meetingID, purpose: .generation, prepare: { fixed })
        }
        #expect(runner.calls.count == 1)
        let receipts = try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloud_spend_receipt") ?? -1
        }
        #expect(receipts == 0, "a failed attempt writes no receipt")
    }

    @Test func aTimedOutRunnerIsOneSpawn() async throws {
        let runner = HeldRunner(fallback: .init(
            stdout: Data(), exitStatus: nil, terminationReason: .uncaughtSignal, timedOut: true))
        let (engine, _) = try await makeEngine(runner: runner)
        let fixed = try prompt()
        await #expect(throws: EngineError.self) {
            _ = try await engine.anchorTimecodes(
                meetingID: TimecodeFixtures.meetingID, purpose: .generation, prepare: { fixed })
        }
        #expect(runner.calls.count == 1)
    }
}
