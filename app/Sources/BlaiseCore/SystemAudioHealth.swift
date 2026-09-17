import Foundation

/// Frame-delivery health, independent of signal amplitude. Silent audio is
/// still audio; only missing streams or stalled delivery indicate failure.
struct SystemAudioHealth {
    static let stallSeconds: TimeInterval = 3
    static let maximumAutomaticRetries = 2
    private(set) var unavailable = false
    private var graphStartedAt: TimeInterval?
    private var lastFramesAt: TimeInterval?
    private var automaticRetries = 0
    private var nextRetryAt: TimeInterval = 0

    mutating func graphStarted(at time: TimeInterval, hasSystemStream: Bool) -> Bool? {
        graphStartedAt = time
        lastFramesAt = nil
        // A replacement graph is not recovery evidence until frames arrive.
        return hasSystemStream ? nil : setUnavailable(true)
    }

    mutating func receivedFrames(at time: TimeInterval) -> Bool? {
        lastFramesAt = time
        return setUnavailable(false)
    }

    mutating func poll(at time: TimeInterval) -> Bool? {
        guard let anchor = lastFramesAt ?? graphStartedAt,
            time - anchor >= Self.stallSeconds else { return nil }
        return setUnavailable(true)
    }

    /// The session calls this only when a live graph has no pending rebuild.
    /// The budget is per recording, so flapping cannot shred a meeting into
    /// unlimited teardown gaps. Manual Retry remains available afterwards.
    mutating func claimAutomaticRetry(at time: TimeInterval) -> Bool {
        guard unavailable, automaticRetries < Self.maximumAutomaticRetries,
            time >= nextRetryAt else { return false }
        automaticRetries += 1
        nextRetryAt = time + Self.stallSeconds
        return true
    }

    private mutating func setUnavailable(_ value: Bool) -> Bool? {
        guard value != unavailable else { return nil }
        unavailable = value
        return value
    }
}
