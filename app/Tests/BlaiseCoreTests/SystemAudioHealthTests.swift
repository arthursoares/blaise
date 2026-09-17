import AVFoundation
import Foundation
import Testing
@testable import BlaiseCore

@Suite("System audio frame delivery health")
struct SystemAudioHealthTests {
    #if DEBUG
    @Test("Hardware fault injection requires explicit opt-in, a temporary root, and a bounded count")
    func diagnosticFaultIsFailClosed() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "BLAISE_CAPTURE_TEST_OMIT_TAP_BUILDS"
        #expect(CaptureSession.diagnosticTapOmissionCount(environment: [:]) == 0)
        #expect(CaptureSession.diagnosticTapOmissionCount(environment: [key: "3"]) == 0)
        #expect(CaptureSession.diagnosticTapOmissionCount(environment: [
            key: "3", "BLAISE_DATA_ROOT": "/Users/example/Library/Application Support/Blaise"
        ]) == 0)
        #expect(CaptureSession.diagnosticTapOmissionCount(environment: [
            key: "3", "BLAISE_DATA_ROOT": root.path
        ]) == 3)
        for invalid in ["0", "-1", "4", "unbounded"] {
            #expect(CaptureSession.diagnosticTapOmissionCount(environment: [
                key: invalid, "BLAISE_DATA_ROOT": root.path
            ]) == 0)
        }
        #expect(CaptureSession.diagnosticTapOmissionCount(environment: [
            key: "3", "BLAISE_DATA_ROOT": "/private/tmp/../var/not-a-temp-root"
        ]) == 0)
        let microphoneKey = "BLAISE_CAPTURE_TEST_OMIT_MIC"
        #expect(!CaptureSession.diagnosticOmitsMicrophone(environment: [microphoneKey: "1"]))
        #expect(CaptureSession.diagnosticOmitsMicrophone(environment: [
            microphoneKey: "1", "BLAISE_DATA_ROOT": root.path
        ]))
        #expect(!CaptureSession.diagnosticOmitsMicrophone(environment: [
            microphoneKey: "0", "BLAISE_DATA_ROOT": root.path
        ]))
    }
    #endif

    @Test("Absent tap is unavailable immediately; frames, not graph creation, prove recovery")
    func absentThenRecovered() {
        var health = SystemAudioHealth()
        #expect(health.graphStarted(at: 10, hasSystemStream: false) == true)
        #expect(health.graphStarted(at: 11, hasSystemStream: true) == nil)
        #expect(health.unavailable)
        #expect(health.receivedFrames(at: 11.1) == false)
        #expect(!health.unavailable)
    }

    @Test("Healthy silent frames are accepted, but a stalled stream raises an episode")
    func framesVersusSilence() {
        var health = SystemAudioHealth()
        #expect(health.graphStarted(at: 0, hasSystemStream: true) == nil)
        #expect(health.poll(at: 2) == nil)
        #expect(health.receivedFrames(at: 2) == nil)
        #expect(health.poll(at: 4) == nil)
        #expect(health.poll(at: 5) == true)
        #expect(health.poll(at: 6) == nil)
        #expect(health.receivedFrames(at: 6.1) == false)
    }

    @Test("No callback at all is detectable and automatic retries are bounded across graphs")
    func boundedRecovery() {
        var health = SystemAudioHealth()
        _ = health.graphStarted(at: 0, hasSystemStream: true)
        #expect(health.poll(at: 3) == true)
        #expect(health.claimAutomaticRetry(at: 3) == true)
        #expect(health.claimAutomaticRetry(at: 3.1) == false)
        _ = health.graphStarted(at: 4, hasSystemStream: false)
        #expect(health.claimAutomaticRetry(at: 6) == true)
        _ = health.graphStarted(at: 7, hasSystemStream: false)
        #expect(health.claimAutomaticRetry(at: 100) == false)
        #expect(health.receivedFrames(at: 101) == false)
        #expect(health.claimAutomaticRetry(at: 105) == false)
        #expect(health.poll(at: 105) == true)
        #expect(health.claimAutomaticRetry(at: 106) == false)
    }

    @Test("A new recording resets retry bounds")
    func freshRecording() {
        var health = SystemAudioHealth()
        _ = health.graphStarted(at: 0, hasSystemStream: false)
        #expect(health.claimAutomaticRetry(at: 1) == true)
        #expect(health.claimAutomaticRetry(at: 4) == true)
        health = SystemAudioHealth()
        _ = health.graphStarted(at: 10, hasSystemStream: false)
        #expect(health.claimAutomaticRetry(at: 11) == true)
    }

    @Test("Recovered samples retain their microphone timeline position and existing audio")
    func recoveredAudioAlignment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("system.caf")
        let writer = try CaptureCAFWriter(url: url)
        func writeMarker(_ value: Int16) throws {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: CaptureCAFWriter.format, frameCapacity: 160))
            buffer.frameLength = 160
            buffer.int16ChannelData![0].update(repeating: value, count: 160)
            try writer.write(buffer)
        }
        try writeMarker(1000)
        // A 2-second outage follows the first 10 ms. The next marker must
        // start at the mic position, not immediately after the first marker.
        try CaptureSession.alignRecoveredSystemTrack(writer, toMicFrame: 32_160)
        try writeMarker(2000)
        #expect(writer.framesWritten == 32_320)
        // A system track already ahead must never be rewound/truncated.
        try CaptureSession.alignRecoveredSystemTrack(writer, toMicFrame: 160)
        #expect(writer.framesWritten == 32_320)
        writer.close()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        #expect(file.length == 32_320)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var samples: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            try #require(buffer.frameLength > 0)
            let pointer = try #require(buffer.int16ChannelData?[0])
            withExtendedLifetime(buffer) {
                samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength)))
            }
        }
        try #require(samples.count == 32_320)
        #expect(samples[0] == 1000)
        #expect(samples[159] == 1000)
        #expect((160..<32_160).allSatisfy { samples[$0] == 0 })
        #expect(samples[32_160] == 2000)
        #expect(samples[32_319] == 2000)
    }
}
