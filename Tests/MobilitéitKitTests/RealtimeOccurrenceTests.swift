import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimeOccurrenceTests {
    @Test func skippedStopPreventsAlightingButDoesNotCancelTheVehicle() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let body = liveBoard(stops: [liveStop("a", planned: "08:00:00", predicted: "08:08:00"),
            liveStop("b", planned: "08:10:00", predicted: "08:18:00", arrival: "08:18:00", extra: ",\"cancelled\":true"),
            liveStop("c", planned: "08:20:00", predicted: "08:28:00", arrival: "08:28:00")].joined(separator: ","))
        let (client, host) = RealtimeBoardProtocol.client { _ in body }; defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        func query(_ destination: String) -> RouteQuery {
            .init(origin: .stop(id: "a"), destination: .stop(id: destination),
                  departureTime: RealtimeTestFixture.date("08:05:00"), realtimePolicy: .bestEffort())
        }
        let through = try await router.makeSession(for: query("c"))
        #expect(try await through.initial().journeys.count == 1)
        let skipped = try await router.makeSession(for: query("b"))
        #expect(try await skipped.initial().journeys.isEmpty)
    }

    @Test func repeatedStopPredictionsApplyToTheCorrectOccurrence() async throws {
        let fixture = try await RealtimeTestFixture(stopTimes:
            "trip,08:00:00,08:00:00,a,1\ntrip,08:10:00,08:10:00,b,2\ntrip,08:20:00,08:20:00,a,3\ntrip,08:30:00,08:30:00,c,4\n")
        defer { fixture.remove() }
        let body = liveBoard(stops: [liveStop("a", planned: "08:00:00", predicted: "08:05:00", extra: ",\"rtBoarding\":false"),
            liveStop("b", planned: "08:10:00", predicted: "08:15:00", arrival: "08:15:00"),
            liveStop("a", planned: "08:20:00", predicted: "08:25:00", arrival: "08:25:00", extra: ",\"rtBoarding\":true"),
            liveStop("c", planned: "08:30:00", predicted: "08:35:00", arrival: "08:35:00")].joined(separator: ","), realtime: "08:05:00")
        let (client, host) = RealtimeBoardProtocol.client { _ in body }; defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("08:15:00"), realtimePolicy: .bestEffort()))
        let journey = try #require(try await session.initial().journeys.first)
        #expect(journey.effectiveDeparture == RealtimeTestFixture.date("08:25:00"))
        #expect(journey.effectiveArrival == RealtimeTestFixture.date("08:35:00"))
    }

    @Test func secondBoardImprovesAnAlreadyMatchedJourney() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let first = liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:08:00"))
        let second = liveBoard(stops: liveStop("b", planned: "08:10:00", predicted: "08:17:00", arrival: "08:17:00") + ","
            + liveStop("c", planned: "08:20:00", predicted: "08:25:00", arrival: "08:25:00"),
                               time: "08:10:00", realtime: "08:17:00", stop: "b")
        let (client, host) = RealtimeBoardProtocol.client { request in
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
            return id == "a" ? first : second
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let patch = try #require(try await provider.patches(for: ["a", "b"], from: RealtimeTestFixture.date("08:00:00"),
            through: RealtimeTestFixture.date("08:30:00"), refreshPolicy: .useCache).patches.first)
        #expect(patch.events[0].departureSource == .reported)
        #expect(patch.events[1].effectiveArrival == RealtimeTestFixture.date("08:17:00"))
        #expect(patch.events[1].arrivalSource == .reported)
        #expect(patch.events[2].effectiveArrival == RealtimeTestFixture.date("08:25:00"))
    }

    @Test func afterMidnightPredictionsKeepTheGTFSServiceDate() async throws {
        let fixture = try await RealtimeTestFixture(stopTimes:
            "trip,23:55:00,23:55:00,a,1\ntrip,24:10:00,24:10:00,b,2\ntrip,24:20:00,24:20:00,c,3\n")
        defer { fixture.remove() }
        let body = liveBoard(stops: liveStop("b", planned: "00:10:00", predicted: "00:15:00", day: "2026-10-01") + ","
            + liveStop("c", planned: "00:20:00", predicted: "00:25:00", arrival: "00:25:00", day: "2026-10-01"),
                            time: "00:10:00", realtime: "00:15:00", stop: "b", day: "2026-10-01")
        let (client, host) = RealtimeBoardProtocol.client { _ in body }; defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let patch = try #require(try await provider.patches(for: ["b"],
            from: RealtimeTestFixture.date("00:05:00", day: "2026-10-01"),
            through: RealtimeTestFixture.date("00:30:00", day: "2026-10-01"), refreshPolicy: .useCache).patches.first)
        #expect(patch.serviceDate.compactString == "20260930")
        #expect(patch.events[1].departureSource == .reported)
        #expect(patch.events[2].effectiveArrival == RealtimeTestFixture.date("00:25:00", day: "2026-10-01"))
    }
    @Test func daylightSavingTransitionKeepsTheGTFSServiceDate() async throws {
        let fixture = try await RealtimeTestFixture(serviceDates: "service,20261025,1\n")
        defer { fixture.remove() }
        let body = liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:08:00", day: "2026-10-25") + ","
            + liveStop("c", planned: "08:20:00", predicted: "08:25:00", arrival: "08:25:00", day: "2026-10-25"),
            day: "2026-10-25")
        let (client, host) = RealtimeBoardProtocol.client { _ in body }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let formatter = ISO8601DateFormatter()
        let from = formatter.date(from: "2026-10-25T08:00:00+01:00")!
        let patch = try #require(try await provider.patches(for: ["a"], from: from,
            through: from.addingTimeInterval(30 * 60), refreshPolicy: .useCache).patches.first)
        #expect(patch.serviceDate.compactString == "20261025")
        #expect(patch.events[0].scheduledDeparture == from)
        #expect(patch.events[2].effectiveArrival == from.addingTimeInterval(25 * 60))
    }

    @Test func ambiguousAutumnWallTimesDoNotGuessATripInstance() async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "trip,02:30:00,02:30:00,a,1\ntrip,02:50:00,02:50:00,c,2\n",
            serviceDates: "service,20261025,1\n")
        defer { fixture.remove() }
        let body = liveBoard(stops: "", time: "02:30:00", realtime: "02:35:00", day: "2026-10-25")
        let (client, host) = RealtimeBoardProtocol.client { _ in body }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let from = ISO8601DateFormatter().date(from: "2026-10-25T02:25:00+01:00")!
        let batch = try await provider.patches(for: ["a"], from: from,
            through: from.addingTimeInterval(30 * 60), refreshPolicy: .useCache)
        #expect(batch.patches.isEmpty)
    }

}
