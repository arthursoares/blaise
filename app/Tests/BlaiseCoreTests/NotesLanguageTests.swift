import Foundation
import Testing
@testable import BlaiseCore

// The preferred notes language: the setting, the forRun rule, the prompt
// clause, and the pipeline split between the detected (transcript) language
// and the notes language. Mock engines and fictional data only.

private let overrideClauseVerbatim =
    "The language named at the start of this line was chosen by the user and overrides any instruction to write in the meeting's language or never to translate. Phrases quoted verbatim, and company and product terms, still stay in their original language."

private func setLanguage(_ value: NotesLanguage, _ harness: PipelineHarness) async throws {
    try await NotesLanguage.set(value, in: SettingsStore(database: harness.database))
}

private func storedNotes(_ harness: PipelineHarness, _ id: MeetingID) async throws -> MeetingNotes {
    try #require(try await NotesRepository(database: harness.database).fetch(meetingID: id))
}

private func jsonObject(at url: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func lastNotesRequest(_ harness: PipelineHarness) throws -> NotesRequest {
    try #require(harness.notesPrimary.state.withLock { $0.requests.last })
}

// MARK: - T-1, T-11: the setting and its rule

@Suite struct NotesLanguageSettingTests {
    @Test func resolveMapsEachCase() {
        #expect(NotesLanguage.automatic.resolve(detected: "pt") == "pt")
        #expect(NotesLanguage.automatic.resolve(detected: "en") == "en")
        #expect(NotesLanguage.english.resolve(detected: "pt") == "en")
        #expect(NotesLanguage.portuguese.resolve(detected: "en") == "pt")
    }

    @Test func absentOrUndecodableValueLoadsAsAutomatic() async throws {
        let store = SettingsStore(database: try makeDatabase())
        #expect(await NotesLanguage.load(from: store) == .automatic)
        try await store.set(NotesLanguage.key, to: "es")
        #expect(await NotesLanguage.load(from: store) == .automatic)
    }

    @Test func setLoadRoundTrip() async throws {
        let database = try makeDatabase()
        for value in NotesLanguage.allCases {
            try await NotesLanguage.set(value, in: SettingsStore(database: database))
            // A fresh store over the same database: what a relaunch reads.
            #expect(await NotesLanguage.load(from: SettingsStore(database: database)) == value)
        }
    }

    @Test func forRunKeepsStoredLanguageOnAutomaticRunsElseReadsTheSetting() async throws {
        let store = SettingsStore(database: try makeDatabase())
        try await NotesLanguage.set(.english, in: store)
        // Automatic run, notes exist: the stored language, the setting unread.
        #expect(
            await NotesLanguage.forRun(
                userStarted: false, storedNotesLanguage: "pt", detected: "pt", store: store) == "pt")
        // Automatic run, legacy empty stored language: the detected language.
        #expect(
            await NotesLanguage.forRun(
                userStarted: false, storedNotesLanguage: "", detected: "pt", store: store) == "pt")
        // Automatic run, no notes yet: the setting.
        #expect(
            await NotesLanguage.forRun(
                userStarted: false, storedNotesLanguage: nil, detected: "pt", store: store) == "en")
        // User-started run: the setting, whatever is stored.
        #expect(
            await NotesLanguage.forRun(
                userStarted: true, storedNotesLanguage: "pt", detected: "pt", store: store) == "en")
        try await NotesLanguage.set(.automatic, in: store)
        #expect(
            await NotesLanguage.forRun(
                userStarted: true, storedNotesLanguage: "en", detected: "pt", store: store) == "pt")
    }
}

// MARK: - T-13: the override clause

@Suite struct NotesLanguagePromptTests {
    private func notesRequest(overridden: Bool) -> NotesRequest {
        NotesRequest(
            meeting: makeMeeting(title: "Vexatron Labs sync"),
            transcript: [
                TranscriptSegment(
                    meetingID: "m", ord: 0, startSeconds: 0, endSeconds: 1,
                    text: "Vamos revisar o piloto de Quoll Harbor.")
            ],
            dominantLanguage: "en",
            vocabulary: ["Vexatron"],
            user: .onboardedUser,
            languageOverridden: overridden)
    }

    private func digestRequest(overridden: Bool) -> DigestRequest {
        DigestRequest(
            meeting: makeMeeting(title: "Vexatron Labs sync"),
            transcript: [
                TranscriptSegment(
                    meetingID: "m", ord: 0, startSeconds: 0, endSeconds: 1,
                    text: "Vamos revisar o piloto de Quoll Harbor.")
            ],
            notes: PipelineMockData.notesResult(engine: "mock").structured,
            dominantLanguage: "en",
            vocabulary: ["Vexatron"],
            user: .onboardedUser,
            languageOverridden: overridden)
    }

    @Test func clauseRidesTheDominantLanguageLineOnlyWhenOverridden() {
        let notesLine =
            "Dominant language: en — write every output field in this language."
        let notesOn = NotesPromptBuilder.userMessage(for: notesRequest(overridden: true))
        let notesOff = NotesPromptBuilder.userMessage(for: notesRequest(overridden: false))
        #expect(notesOn.contains(notesLine + " " + overrideClauseVerbatim + "\n"))
        #expect(!notesOff.contains(overrideClauseVerbatim))
        #expect(notesOff.contains(notesLine + "\n"))
        #expect(notesOn.replacingOccurrences(of: " " + overrideClauseVerbatim, with: "") == notesOff)

        let digestLine =
            "Dominant language: en — write the digest content in this language; keep the eight `##` headings and the bracket flags in English."
        let digestOn = DigestPromptBuilder.userMessage(for: digestRequest(overridden: true))
        let digestOff = DigestPromptBuilder.userMessage(for: digestRequest(overridden: false))
        #expect(digestOn.contains(digestLine + " " + overrideClauseVerbatim + "\n"))
        #expect(!digestOff.contains(overrideClauseVerbatim))
        #expect(digestOn.replacingOccurrences(of: " " + overrideClauseVerbatim, with: "") == digestOff)

        let auditOn = DigestPromptBuilder.combinedAuditUserMessage(
            for: digestRequest(overridden: true), draftDigest: "## HEADER")
        let auditOff = DigestPromptBuilder.combinedAuditUserMessage(
            for: digestRequest(overridden: false), draftDigest: "## HEADER")
        #expect(auditOn.contains(digestLine + " " + overrideClauseVerbatim))
        #expect(!auditOff.contains(overrideClauseVerbatim))
        #expect(auditOn.replacingOccurrences(of: " " + overrideClauseVerbatim, with: "") == auditOff)
    }

    @Test func notesRequestCodingCarriesTheFlagAndDefaultsItWhenAbsent() throws {
        let request = notesRequest(overridden: true)
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(NotesRequest.self, from: data) == request)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "language_overridden")
        let legacy = try JSONDecoder().decode(
            NotesRequest.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.languageOverridden == false)
    }
}

// MARK: - Pipeline (T-2, T-4 to T-9, T-12)

@Suite struct NotesLanguagePipelineTests {
    /// T-2 (AC-2): English set, a Portuguese meeting's first notes.
    @Test func englishOverPortugueseMeetingSplitsNotesFromTranscript() async throws {
        let harness = try await makePipelineHarness()
        try await setLanguage(.english, harness)
        let meeting = try await harness.importTestMeeting()
        let record = try await harness.pipeline.process(meetingID: meeting.id)

        let notesRequest = try lastNotesRequest(harness)
        #expect(notesRequest.dominantLanguage == "en")
        #expect(notesRequest.languageOverridden)
        let digestRequest = try #require(harness.notesPrimary.state.withLock { $0.digestRequests.last })
        #expect(digestRequest.dominantLanguage == "en")
        #expect(digestRequest.languageOverridden)

        let notes = try await storedNotes(harness, meeting.id)
        #expect(notes.language == "en")
        #expect(notes.markdown.contains("## Summary"))
        #expect(!notes.markdown.contains("## Resumo"))
        let payload = try jsonObject(
            at: harness.database.rootURL.appendingPathComponent(try #require(record.payloadPath)))
        #expect(payload["dominant_language"] as? String == "en")

        #expect(try await harness.meeting(meeting.id)?.dominantLanguage == "pt")
        let transcript = try jsonObject(at: harness.database.paths.transcriptURL(meeting.id))
        #expect(transcript["dominant_language"] as? String == "pt")
        #expect(record.dominantLanguage == "pt")
    }

    /// T-4: an override equal to the detected language is Automatic, byte for byte.
    @Test func overrideEqualToDetectedIsByteIdenticalToAutomatic() async throws {
        let english = [
            ASRSegment(startSeconds: 0.0, endSeconds: 0.9, text: "Hello, let's get started with the review."),
            ASRSegment(
                startSeconds: 1.0, endSeconds: 1.9,
                text: "The team will send the contract to the partner this week."),
        ]
        var messages: [String] = []
        for setting in [NotesLanguage.english, .automatic] {
            let harness = try await makePipelineHarness()
            harness.asr.state.withLock {
                $0.segments = english
                $0.detectedLanguage = "en"
            }
            try await setLanguage(setting, harness)
            let meeting = try await harness.importTestMeeting()
            _ = try await harness.pipeline.process(meetingID: meeting.id)
            let request = try lastNotesRequest(harness)
            #expect(request.dominantLanguage == "en")
            #expect(request.languageOverridden == false)
            messages.append(NotesPromptBuilder.userMessage(for: request))
        }
        #expect(messages.count == 2)
        #expect(messages[0] == messages[1])
    }

    /// T-5 (AC-4): a setting change runs nothing; a re-mint keeps the stored language.
    @Test func settingChangeAndRenameKeepStoredLanguage() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(try await storedNotes(harness, meeting.id).language == "pt")
        let callsBefore = harness.notesPrimary.state.withLock { $0.requests.count }
        let digestCallsBefore = harness.notesPrimary.state.withLock { $0.digestRequests.count }

        try await setLanguage(.english, harness)
        #expect(try await harness.pipeline.renameMeeting(meetingID: meeting.id, to: "Quoll Harbor review"))

        #expect(try await storedNotes(harness, meeting.id).language == "pt")
        #expect(harness.notesPrimary.state.withLock { $0.requests.count } == callsBefore)
        #expect(harness.notesPrimary.state.withLock { $0.digestRequests.count } == digestCallsBefore)
    }

    /// T-6 (AC-3): Regenerate Notes under English rewrites the notes, not the transcript.
    @Test func rewriteNotesUnderEnglishLeavesTranscriptByteIdentical() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(try await storedNotes(harness, meeting.id).language == "pt")
        let segmentsBefore = try await harness.segments(meeting.id)
        let transcriptURL = harness.database.paths.transcriptURL(meeting.id)
        let transcriptBefore = try Data(contentsOf: transcriptURL)

        try await setLanguage(.english, harness)
        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)

        let request = try lastNotesRequest(harness)
        #expect(request.dominantLanguage == "en")
        #expect(request.languageOverridden)
        let notes = try await storedNotes(harness, meeting.id)
        #expect(notes.language == "en")
        #expect(notes.markdown.contains("## Summary"))
        #expect(try await harness.segments(meeting.id) == segmentsBefore)
        #expect(try Data(contentsOf: transcriptURL) == transcriptBefore)
        #expect(try await harness.meeting(meeting.id)?.dominantLanguage == "pt")
    }

    /// T-7 (AC-5): the digest heal follows the stored notes language, never the setting.
    @Test func digestHealUsesStoredNotesLanguage() async throws {
        for (stored, setting, expected, overridden) in [
            ("en", NotesLanguage.portuguese, "en", true),
            ("", NotesLanguage.english, "pt", false),
        ] {
            let harness = try await makePipelineHarness()
            harness.notesPrimary.state.withLock { $0.digestError = .permanent("forced digest failure") }
            let meeting = try await harness.importTestMeeting()
            _ = try await harness.pipeline.process(meetingID: meeting.id)
            let pending = try #require(try await harness.meeting(meeting.id))
            #expect(DigestPendingClass.isPending(pending.lastProcessingError))
            #expect(pending.dominantLanguage == "pt")

            var notes = try await storedNotes(harness, meeting.id)
            notes.language = stored
            try await NotesRepository(database: harness.database).upsert(notes)
            try await setLanguage(setting, harness)
            harness.notesPrimary.state.withLock { $0.digestError = nil }

            #expect(try await harness.pipeline.processDigestOnly(meetingID: meeting.id))
            let request = try #require(harness.notesPrimary.state.withLock { $0.digestRequests.last })
            #expect(request.dominantLanguage == expected)
            #expect(request.languageOverridden == overridden)
        }
    }

    /// T-8: the resume-equals-stage-9 pin holds with English set on both sides.
    @Test func pendingResumeRequestMatchesStageNineUnderEnglish() async throws {
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        try await setLanguage(.english, harness)
        let meeting = try await harness.importTestMeeting()
        harness.notesPrimary.state.withLock { $0.error = .configurationMissing(key: "apiKey") }
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        harness.notesPrimary.state.withLock { $0.error = nil }
        _ = try await harness.pipeline.processNotesOnly(meetingID: meeting.id)

        let requests = harness.notesPrimary.state.withLock { $0.requests }
        #expect(requests.count == 2)
        let original = try #require(requests.first)
        let resumed = try #require(requests.last)
        #expect(resumed.dominantLanguage == "en")
        #expect(resumed.languageOverridden)
        #expect(resumed.dominantLanguage == original.dominantLanguage)
        #expect(resumed.languageOverridden == original.languageOverridden)
        #expect(
            NotesPromptBuilder.userMessage(for: resumed)
                == NotesPromptBuilder.userMessage(for: original))
        #expect(try await storedNotes(harness, meeting.id).language == "en")
    }

    /// T-9: a first-notes resume that applies name proposals under English
    /// re-persists the transcript with the detected language.
    @Test func resumeNameProposalsRepersistTranscriptInDetectedLanguage() async throws {
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        try await setLanguage(.english, harness)
        let meeting = try await harness.importTestMeeting()
        harness.notesPrimary.state.withLock { $0.error = .configurationMissing(key: "apiKey") }
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(try await harness.segments(meeting.id).allSatisfy { $0.speakerName == nil })

        harness.notesPrimary.state.withLock { state in
            state.error = nil
            state.mapping = [
                SpeakerNameProposal(
                    label: "S1", name: "Fábio", confidence: .high,
                    evidence: "O Fábio vai mandar o contrato.")
            ]
        }
        _ = try await harness.pipeline.processNotesOnly(meetingID: meeting.id)

        // The re-persist ran (a segment's speaker name changed) ...
        #expect(try await harness.segments(meeting.id).contains { $0.speakerName == "Fábio" })
        // ... and kept the detected language, while the notes took the setting.
        #expect(try await harness.meeting(meeting.id)?.dominantLanguage == "pt")
        let transcript = try jsonObject(at: harness.database.paths.transcriptURL(meeting.id))
        #expect(transcript["dominant_language"] as? String == "pt")
        #expect(try await storedNotes(harness, meeting.id).language == "en")
    }

    /// T-12 (a): a user-started run of a meeting with Portuguese notes reads the setting.
    @Test func userStartedRunReadsTheSetting() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(try await storedNotes(harness, meeting.id).language == "pt")

        try await setLanguage(.english, harness)
        _ = try await harness.pipeline.dispatchProcessing(meetingID: meeting.id, userStarted: true)
        let request = try lastNotesRequest(harness)
        #expect(request.dominantLanguage == "en")
        #expect(request.languageOverridden)
        #expect(try await storedNotes(harness, meeting.id).language == "en")
    }

    /// A captured meeting's first notes run automatically with no stored notes;
    /// that run reads the setting.
    @Test func automaticFirstNotesRunReadsTheSetting() async throws {
        let harness = try await makePipelineHarness()
        try await setLanguage(.english, harness)
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.dispatchProcessing(
            meetingID: meeting.id, refuseCancelled: true, userStarted: false)
        let request = try lastNotesRequest(harness)
        #expect(request.dominantLanguage == "en")
        #expect(request.languageOverridden)
        #expect(try await storedNotes(harness, meeting.id).language == "en")
    }

    /// T-12 (b): stored "en", detected "pt", set "pt" — automatic runs keep the
    /// stored language; a user-started run under Automatic takes the detected one.
    @Test func automaticRunsKeepStoredLanguage() async throws {
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        try await setLanguage(.english, harness)
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(try await storedNotes(harness, meeting.id).language == "en")
        #expect(try await harness.meeting(meeting.id)?.dominantLanguage == "pt")

        // An automatic full re-run.
        try await setLanguage(.portuguese, harness)
        _ = try await harness.pipeline.dispatchProcessing(
            meetingID: meeting.id, refuseCancelled: true, userStarted: false)
        var request = try lastNotesRequest(harness)
        #expect(request.dominantLanguage == "en")
        #expect(request.languageOverridden)
        #expect(try await storedNotes(harness, meeting.id).language == "en")

        // An automatic re-run that parks notes-pending, then the automatic resume
        // of a meeting that already had notes.
        harness.notesPrimary.state.withLock { $0.error = .configurationMissing(key: "apiKey") }
        _ = try await harness.pipeline.dispatchProcessing(
            meetingID: meeting.id, refuseCancelled: true, userStarted: false)
        let parked = try #require(try await harness.meeting(meeting.id))
        #expect(NotesPendingClass.isPending(parked.lastProcessingError))
        harness.notesPrimary.state.withLock { $0.error = nil }
        let callsBeforeResume = harness.notesPrimary.state.withLock { $0.requests.count }
        _ = try #require(try await harness.pipeline.processNotesOnly(meetingID: meeting.id))
        #expect(harness.notesPrimary.state.withLock { $0.requests.count } == callsBeforeResume + 1)
        request = try lastNotesRequest(harness)
        #expect(request.dominantLanguage == "en")
        #expect(request.languageOverridden)

        // A user-started run under Automatic follows the detected language.
        try await setLanguage(.automatic, harness)
        _ = try await harness.pipeline.dispatchProcessing(meetingID: meeting.id, userStarted: true)
        request = try lastNotesRequest(harness)
        #expect(request.dominantLanguage == "pt")
        #expect(request.languageOverridden == false)
        #expect(try await storedNotes(harness, meeting.id).language == "pt")
    }
}
