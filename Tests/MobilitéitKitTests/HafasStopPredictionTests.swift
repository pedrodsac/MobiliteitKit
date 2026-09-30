import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct HafasStopPredictionTests {
    @Test func predictionsRecoverIndependentlyAndInjectDelayedPastDeparture() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let body = liveBoard(stops: [liveStop("a", planned: "08:00:00", predicted: "08:08:00"),
                                    liveStop("b", planned: "08:10:00", predicted: "08:15:00", arrival: "08:14:00"),
                                    liveStop("c", planned: "08:20:00", predicted: "08:20:00", arrival: "08:20:00")].joined(separator: ","))
        let (client, host) = RealtimeBoardProtocol.client { _ in body }; defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let batch = try await provider.patches(for: .init(stopIDs: ["a"],
            from: RealtimeTestFixture.date("08:05:00"), through: RealtimeTestFixture.date("08:30:00")))
        let patch = try #require(batch.patches.first)
        #expect(patch.events[0].effectiveDeparture == RealtimeTestFixture.date("08:08:00"))
        #expect(patch.events[1].effectiveArrival == RealtimeTestFixture.date("08:14:00"))
        #expect(patch.events[1].effectiveDeparture == RealtimeTestFixture.date("08:15:00"))
        #expect(patch.events[2].effectiveArrival == RealtimeTestFixture.date("08:20:00"))
        #expect(patch.events.allSatisfy { $0.departureSource == .reported })
        #expect(batch.networkRequests == 1 && batch.responseBytes > 0)
        let url = try #require(RealtimeBoardProtocol.requests(host).first?.url)
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(params.first { $0.name == "rtMode" }?.value == "SERVER_DEFAULT")
        #expect(params.first { $0.name == "time" }?.value == "08:00:00")
        #expect(params.first { $0.name == "passlist" }?.value == "1")
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("08:05:00"), realtimePolicy: .bestEffort()))
        let journey = try #require(try await session.initial().journeys.first)
        #expect(journey.effectiveDeparture == RealtimeTestFixture.date("08:08:00"))
        #expect(journey.effectiveArrival == RealtimeTestFixture.date("08:20:00"))
    }

    @Test func downstreamOnlyListDoesNotApplyDelayToEarlierStops() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let body = liveBoard(stops: liveStop("b", planned: "08:10:00", predicted: "08:15:00") + ","
            + liveStop("c", planned: "08:20:00", predicted: "08:22:00", arrival: "08:22:00"),
                            time: "08:10:00", realtime: "08:15:00", stop: "b")
        let (client, host) = RealtimeBoardProtocol.client { _ in body }; defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let patch = try #require(try await provider.patches(for: ["b"], from: RealtimeTestFixture.date("08:10:00"),
            through: RealtimeTestFixture.date("08:30:00"), refreshPolicy: .useCache).patches.first)
        #expect(patch.events[0].effectiveDeparture == patch.events[0].scheduledDeparture)
        #expect(patch.events[0].departureSource == .scheduled)
        #expect(patch.events[1].arrivalSource == .scheduled)
        #expect(patch.events[1].departureSource == .reported)
        #expect(patch.events[2].arrivalSource == .reported)
    }

    @Test func omittedTimesRemainEstimatedAndPerStopOnlySignalIsAccepted() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let body = liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:08:00") + ","
            + liveStop("b", planned: "08:10:00") + ","
            + liveStop("c", planned: "08:20:00", predicted: "08:25:00", arrival: "08:25:00"), realtime: nil)
        let (client, host) = RealtimeBoardProtocol.client { _ in body }; defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let patch = try #require(try await provider.patches(for: ["a"], from: RealtimeTestFixture.date("08:00:00"),
            through: RealtimeTestFixture.date("08:30:00"), refreshPolicy: .useCache).patches.first)
        #expect(patch.events[1].effectiveArrival == RealtimeTestFixture.date("08:18:00"))
        #expect(patch.events[1].arrivalSource == .estimated)
        #expect(patch.events[2].arrivalSource == .reported)
    }

    @Test func refreshBypassesBothCachesAndIntervalsMustContainTheRequest() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { _ in liveBoard(stops: "") }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let from = RealtimeTestFixture.date("08:00:00"), through = RealtimeTestFixture.date("08:10:00")
        _ = try await provider.patches(for: ["a"], from: from, through: through, refreshPolicy: .useCache)
        _ = try await provider.patches(for: ["a"], from: from, through: through, refreshPolicy: .useCache)
        #expect(RealtimeBoardProtocol.requests(host).count == 1)
        _ = try await provider.patches(for: ["a"], from: from, through: through, refreshPolicy: .forceRefresh)
        #expect(RealtimeBoardProtocol.requests(host).count == 2)
        _ = try await provider.patches(for: ["a"], from: from.addingTimeInterval(-30), through: through,
                                      refreshPolicy: .useCache)
        #expect(RealtimeBoardProtocol.requests(host).count == 3)
    }

    @Test func fullBoardsAreSplitAndRemainPartialWhenTheBudgetIsExhausted() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let row = #"{"Product":{"line":"201"},"time":"08:00:00","date":"2026-09-30","rtTime":"08:08:00"}"#
        let body = "{\"Departure\":[" + Array(repeating: row, count: 50).joined(separator: ",") + "]}"
        let (client, host) = RealtimeBoardProtocol.client { _ in body }; defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let batch = try await provider.patches(for: ["a"], from: RealtimeTestFixture.date("08:00:00"),
            through: RealtimeTestFixture.date("08:30:00"), refreshPolicy: .forceRefresh)
        #expect(batch.incompleteStopIDs == ["a"])
        #expect(batch.networkRequests == 8)
        #expect(RealtimeBoardProtocol.requests(host).count == 8)
    }

    @Test func ambiguousTripsAndNonMonotonicPredictionsAreIgnored() async throws {
        let fixture = try await RealtimeTestFixture(stopTimes: "trip,08:00:00,08:00:00,a,1\ntrip,08:20:00,08:20:00,c,2\ntwin,08:00:00,08:00:00,a,1\ntwin,08:20:00,08:20:00,c,2\n",
            trips: "route,service,trip,Destination\nroute,service,twin,Destination\n")
        defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { _ in liveBoard(stops: "") }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        #expect(try await provider.patches(for: ["a"], from: RealtimeTestFixture.date("08:00:00"),
            through: RealtimeTestFixture.date("08:30:00"), refreshPolicy: .useCache).patches.isEmpty)
        let simple = try await RealtimeTestFixture(); defer { simple.remove() }
        let bad = liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:30:00") + ","
            + liveStop("c", planned: "08:20:00", predicted: "08:20:00", arrival: "08:20:00"), realtime: "08:30:00")
        let (badClient, badHost) = RealtimeBoardProtocol.client { _ in bad }; defer { RealtimeBoardProtocol.remove(badHost) }
        let badProvider = try HafasRealtimeRoutingProvider(databaseURL: simple.database, client: badClient)
        #expect(try await badProvider.patches(for: ["a"], from: RealtimeTestFixture.date("08:00:00"),
            through: RealtimeTestFixture.date("08:30:00"), refreshPolicy: .useCache).patches.isEmpty)
    }
}
