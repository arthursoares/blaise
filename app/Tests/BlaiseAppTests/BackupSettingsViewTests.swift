import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

@MainActor
struct BackupSettingsViewTests {

    /// The holder driven the way the app drives it: a meeting paused, then another meeting's
    /// grace window, processing and alarm outranking it on the indicator.
    @Test func quitAndRestoreSeesAPausedMeetingBehindGraceProcessingOrAlarm() {
        let holder = CaptureStatusHolder()
        #expect(QuitAndRestoreButton.captureState(holder) == (false, false))

        holder.pausedMeetingID = "01JVEXATRONPAUSED000000000"
        holder.apply(.meetingPaused(meetingTitle: "Vexatron sync", accumulatedSeconds: 60))
        #expect(QuitAndRestoreButton.captureState(holder) == (false, true))

        holder.apply(.graceEntered(meetingTitle: "Quoll Harbor review", until: Date(timeIntervalSince1970: 1_790_000_000)))
        #expect(!holder.isPaused)
        #expect(QuitAndRestoreButton.captureState(holder) == (false, true))

        holder.apply(.graceExpired)
        #expect(QuitAndRestoreButton.captureState(holder).isPaused)

        holder.apply(.captureStopped(alarm: "No recoverable audio"))
        #expect(QuitAndRestoreButton.captureState(holder).isPaused)

        holder.pausedMeetingID = nil
        holder.apply(.meetingEnded)
        #expect(!QuitAndRestoreButton.captureState(holder).isPaused)
    }
}
