import BlaiseCore
import Foundation
import Observation

/// A notes block's stored anchor, in transcript time on one capture track.
struct NotesDocTimecode: Equatable {
    var seconds: Double
    var track: CaptureTrack
}

/// What the notes view needs to draw and act on timecode marks.
struct NotesDocTimecodes {
    /// Block anchor id → its stored anchor.
    var targets: [String: NotesDocTimecode]
    /// Transcript time on a track → where it plays, nil when it does not.
    var playbackSeconds: (Double, CaptureTrack) -> Double?
    /// Bumped whenever the player's mapping is set again.
    var mappingGeneration: Int
    /// The block whose mark started what is playing now.
    var playing: String?
    /// A mark was activated: the block and its playback time.
    var onActivate: (String, Double) -> Void

    /// Where a block's mark plays, nil when the block has no mark.
    func playback(_ anchor: String) -> Double? {
        targets[anchor].flatMap { playbackSeconds($0.seconds, $0.track) }
    }
}

/// The one link between the notes pane's marks and its audio player: the
/// latest request, the block now playing, and the player's time mapping.
@MainActor @Observable
final class TimecodeLink {
    struct Request: Equatable {
        var anchorID: String
        /// nil: pause.
        var playbackSeconds: Double?
        var token: Int
    }

    private(set) var request: Request?
    /// Set by the player when a mark's request starts playback; cleared
    /// whenever playback stops, whatever stopped it.
    var playingAnchor: String?
    /// Set when the player's audio is ready; nil while it resolves, when it
    /// is unreadable or failed, or when there is no audio.
    private(set) var mapping: ((Double, CaptureTrack) -> Double?)?
    private(set) var mappingGeneration = 0

    func setMapping(_ mapping: ((Double, CaptureTrack) -> Double?)?) {
        self.mapping = mapping
        mappingGeneration += 1
    }

    /// A click on a mark: the item already playing pauses; any other plays.
    func activate(_ anchorID: String, playbackSeconds: Double) {
        let token = (request?.token ?? 0) + 1
        request = Request(
            anchorID: anchorID,
            playbackSeconds: playingAnchor == anchorID ? nil : playbackSeconds,
            token: token)
    }

    /// The seek target for a mark: three seconds of lead-in, inside the audio.
    nonisolated static func seekTarget(playback: Double, duration: Double) -> Double {
        min(max(0, playback - 3), duration)
    }
}

/// Block anchor id → stored anchor, for every laid-out block that can carry
/// a mark and has a row: the row's section and the hash of the block's
/// folded text match, and that text occurs once in its section.
func notesDocTimecodes(_ rows: [NotesTimecode], document: NotesDocument) -> [String: NotesDocTimecode] {
    guard !rows.isEmpty else { return [:] }
    struct Key: Hashable {
        let section: MeetingCorrection.Section
        let hash: String
    }
    let byKey = Dictionary(
        rows.map { (Key(section: $0.section, hash: $0.itemHash), $0) }, uniquingKeysWith: { first, _ in first })
    var renderedIndex: [CorrectionAnchoring.RenderedBlock.ID: Int] = [:]
    for (index, block) in document.space.blocks.enumerated() { renderedIndex[block.id] = index }
    var result: [String: NotesDocTimecode] = [:]
    for block in TimecodeAnchoring.markableBlocks(space: document.space, parsed: document.parsed) {
        guard let row = byKey[Key(section: block.id.section, hash: block.hash)],
            let index = renderedIndex[block.id], let anchor = document.anchorOfRendered[index]
        else { continue }
        result[anchor] = NotesDocTimecode(seconds: row.startSeconds, track: row.track)
    }
    return result
}
