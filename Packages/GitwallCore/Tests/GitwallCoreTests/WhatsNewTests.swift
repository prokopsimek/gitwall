import Foundation
import Testing
@testable import GitwallCore

@Suite("What's new")
struct WhatsNewTests {
    typealias S = DetailSupport

    private let timeline = [
        S.event("a", by: "jana", minutes: -90),
        S.event("b", .labeled("bug"), by: "tomas", minutes: -60),
        S.event("c", by: "prokop", minutes: -40),
        S.event("d", .reviewed(.approved), by: "mara", minutes: -20),
        S.event("e", .committed(sha: "abc1234", message: "Fix"), by: nil, minutes: -10),
    ]

    @Test("events by other people after the last open, oldest first")
    func sinceLastOpen() {
        let events = WhatsNew.events(in: timeline, lastSeenAt: S.at(minutes: -50), me: S.me)
        #expect(events.map(\.id) == ["d", "e"])
    }

    @Test("an event exactly at the last open was already seen")
    func boundary() {
        let events = WhatsNew.events(in: timeline, lastSeenAt: S.at(minutes: -20), me: S.me)
        #expect(events.map(\.id) == ["e"])
    }

    @Test("the first open shows the last three events, whoever made them")
    func firstOpen() {
        let shuffled = [timeline[3], timeline[0], timeline[4], timeline[2], timeline[1]]
        let events = WhatsNew.events(in: shuffled, lastSeenAt: nil, me: S.me)
        #expect(events.map(\.id) == ["c", "d", "e"])
    }

    @Test("nothing new since the last open")
    func nothingNew() {
        #expect(WhatsNew.events(in: timeline, lastSeenAt: S.at(minutes: 0), me: S.me).isEmpty)
    }

    @Test("an item changed after it was opened gets a dot; one never opened does not")
    func changedSinceOpened() {
        let item = S.pull()
        #expect(WhatsNew.hasChanged(item, lastSeenAt: S.at(minutes: -6)))
        #expect(!WhatsNew.hasChanged(item, lastSeenAt: S.at(minutes: -5)))
        #expect(!WhatsNew.hasChanged(item, lastSeenAt: nil))
    }
}
