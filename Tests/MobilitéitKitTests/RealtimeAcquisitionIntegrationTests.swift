import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimeAcquisitionIntegrationTests {
    @Test func nextWaveFindsADelayedTransferOutsideStaticWinners() async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "first,08:00:00,08:00:00,a,1\nfirst,08:10:00,08:10:00,b,2\nsecond,08:12:00,08:12:00,b,1\nsecond,08:30:00,08:30:00,c,2\n",
            trips: "route,service,first,Destination\nroute,service,second,Destination\n")
        defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { request in
            let stop = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "id" }!.value!
            if stop == "a" {
                return liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:08:00") + ","
                    + liveStop("b", planned: "08:10:00", predicted: "08:18:00", arrival: "08:18:00"))
            }
            return liveBoard(stops: liveStop("b", planned: "08:12:00", predicted: "08:20:00") + ","
                + liveStop("c", planned: "08:30:00", predicted: "08:38:00", arrival: "08:38:00"),
                time: "08:12:00", realtime: "08:20:00", stop: "b")
                .replacingOccurrences(of: "same-journey", with: "second-journey")
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("08:05:00"), realtimePolicy: .bestEffort()))
        let page = try await session.initial()
        let journey = try #require(page.journeys.first)
        #expect(journey.effectiveArrival == RealtimeTestFixture.date("08:38:00"))
        #expect(page.metrics.hafasRequests == 8)
        #expect(page.metrics.realtimeBoardsCovered == 2)
        let stops = Set(RealtimeBoardProtocol.requests(host).compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
        })
        #expect(stops == ["a", "b"])
        #expect(page.realtimeState == .partial) // The full GTFS profile exceeds the live horizon.
        _ = try await session.refreshRealtime()
        #expect(RealtimeBoardProtocol.requests(host).count == 16)
    }

    @Test func APIErrorKeepsScheduleOnlyRoutingAvailable() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { _ in
            #"{"errorCode":"API_PARAM","errorText":"Fixture failure"}"#
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("07:55:00"), realtimePolicy: .bestEffort()))
        let page = try await session.initial()
        #expect(!page.journeys.isEmpty)
        #expect(page.journeys.first?.effectiveDeparture == RealtimeTestFixture.date("08:00:00"))
        #expect(page.realtimeState == .unavailable)
    }
}
