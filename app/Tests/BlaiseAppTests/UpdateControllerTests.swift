import Testing

@testable import BlaiseApp

@MainActor
struct UpdateControllerTests {
    @Test("The updater starts exactly once only when a feed URL is present")
    func startsOnlyWithFeedURL() {
        var starts = 0
        let withoutFeed = UpdateController(feedURL: nil, start: { starts += 1 })
        #expect(starts == 0)
        #expect(!withoutFeed.canCheckForUpdates)

        let withFeed = UpdateController(
            feedURL: "https://example.invalid/appcast.xml", start: { starts += 1 })
        #expect(starts == 1)
        #expect(!withFeed.canCheckForUpdates)
    }
}
