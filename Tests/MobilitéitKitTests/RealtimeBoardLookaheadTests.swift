import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimeBoardLookaheadTests {
    @Test func futureCoverageIsCachedWithoutPublishingFutureTripPatches() async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "trip,08:00:00,08:00:00,a,1\ntrip,08:20:00,08:20:00,c,2\n"
                + "late,11:00:00,11:00:00,a,1\nlate,11:20:00,11:20:00,c,2\n",
            trips: "route,service,trip,Destination\nroute,service,late,Destination\n")
        defer { fixture.remove() }
        let first = liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:08:00") + ","
            + liveStop("c", planned: "08:20:00", predicted: "08:28:00", arrival: "08:28:00"))
        let late = liveBoard(stops: liveStop("a", planned: "11:00:00", predicted: "11:08:00") + ","
            + liveStop("c", planned: "11:20:00", predicted: "11:28:00", arrival: "11:28:00"),
            time: "11:00:00", realtime: "11:08:00")
            .replacingOccurrences(of: "same-journey", with: "later-journey")
        let prefix = "{\"Departure\":["
        let payload = prefix + String(first.dropFirst(prefix.count).dropLast(2)) + ","
            + String(late.dropFirst(prefix.count).dropLast(2)) + "]}"
        let (client, host) = RealtimeBoardProtocol.client { _ in payload }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let earlyFrom = RealtimeTestFixture.date("08:00:00")
        let earlyThrough = RealtimeTestFixture.date("09:30:00")
        let initial = try await provider.patches(for: .init(stopIDs: ["a"],
            from: earlyFrom, through: earlyThrough, refreshPolicy: .forceRefresh,
            targets: [.init(stopID: "a", from: earlyFrom, through: earlyThrough, lines: ["201"])],
            minimumBoardCoverageMinutes: 240))
        #expect(initial.patches.map(\.tripID) == ["trip"])
        #expect(initial.networkRequests == 1)
        let laterFrom = RealtimeTestFixture.date("11:00:00")
        let laterThrough = RealtimeTestFixture.date("12:00:00")
        let expanded = try await provider.patches(for: .init(stopIDs: ["a"],
            from: laterFrom, through: laterThrough,
            targets: [.init(stopID: "a", from: laterFrom, through: laterThrough, lines: ["201"])]))
        #expect(expanded.patches.map(\.tripID) == ["late"])
        #expect(expanded.networkRequests == 0)
        #expect(expanded.cacheHits == 1)
        #expect(RealtimeBoardProtocol.requests(host).count == 1)
        let request = try #require(RealtimeBoardProtocol.requests(host).first)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first { $0.name == "duration" }?.value == "240")
    }
}
