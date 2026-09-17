import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

@MainActor
struct MissingCallAudioSurfaceTests {
    @Test func silenceDoesNotShowMissingCallAudio() {
        let status = CaptureStatusHolder()
        status.apply(.captureStarted(at: Date()))
        status.apply(.micSilence(active: true))
        #expect(!status.showsMissingCallAudio)
        status.apply(.systemAudioUnavailable(active: true))
        #expect(status.showsMissingCallAudio)
    }

    @Test func captureDownTakesPriorityAndRecoveryRestoresWarning() {
        let status = CaptureStatusHolder()
        status.apply(.captureStarted(at: Date()))
        status.apply(.systemAudioUnavailable(active: true))
        status.apply(.captureDown(active: true))
        #expect(!status.showsMissingCallAudio)
        status.apply(.captureDown(active: false))
        #expect(status.showsMissingCallAudio)
        status.apply(.systemAudioUnavailable(active: false))
        #expect(!status.showsMissingCallAudio)
    }

    @Test func pauseAndNewCaptureClearUnavailableSurface() {
        let status = CaptureStatusHolder()
        status.apply(.captureStarted(at: Date()))
        status.apply(.systemAudioUnavailable(active: true))
        status.apply(.meetingPaused(meetingTitle: "Invented meeting", accumulatedSeconds: 10))
        #expect(!status.showsMissingCallAudio)
        #expect(!status.systemAudioUnavailable)
        status.apply(.captureStarted(at: Date()))
        #expect(!status.showsMissingCallAudio)
        status.apply(.systemAudioUnavailable(active: true))
        status.apply(.captureStopping)
        #expect(!status.showsMissingCallAudio)
    }

    @Test func notificationOpensPersistentSurface() {
        #expect(AutomationNotificationAdapter.action(
            categoryIdentifier: AutomationNotificationCategory.systemAudioUnavailable,
            userInfo: [:]) == .openMainWindow)
        #expect(CaptureStatusHolder.audioSettingsURL.absoluteString.contains("Privacy_ScreenCapture"))
    }
}
