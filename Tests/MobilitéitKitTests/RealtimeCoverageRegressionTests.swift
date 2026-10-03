import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimeCoverageRegressionTests {
    @Test(arguments: [RouteQueryDirection.departAfter, .arriveBy])
    func laterBoardingIsCheckedEvenWhenAnotherStopAlreadyPatchedTheTrip(direction: RouteQueryDirection) async throws {
        let fixture = try await RealtimeTestFixture(stopTimes:
            "trip,08:00:00,08:00:00,a,1\ntrip,10:00:00,10:00:00,b,2\ntrip,10:20:00,10:20:00,c,3\n")
        defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { request in
            let stop = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "id" }!.value!
            if stop == "a" {
                return liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:02:00") + ","
                    + liveStop("b", planned: "10:00:00") + "," + liveStop("c", planned: "10:20:00"),
                    realtime: "08:02:00")
            }
            return liveBoard(stops: liveStop("b", planned: "10:00:00", predicted: "10:07:00", arrival: "10:06:00")
                + "," + liveStop("c", planned: "10:20:00", predicted: "10:25:00", arrival: "10:25:00"),
                time: "10:00:00", realtime: "10:07:00", stop: "b")
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date(direction == .arriveBy ? "11:00:00" : "08:00:00"),
            direction: direction, realtimePolicy: .bestEffort(configuration: .init(acquisitionBudgetMilliseconds: 2_000))))
        let page = try await session.initial(count: 5, searchHorizon: 3 * 3_600)
        let journey = try #require(page.journeys.first)
        #expect(journey.effectiveArrival == RealtimeTestFixture.date("10:25:00"))
        #expect(journey.statusEvidence.coverage == .live)
        let requests = RealtimeBoardProtocol.requests(host)
        let later = try #require(requests.first { $0.url!.query!.contains("id=b") })
        #expect(later.url!.query!.contains("time=09%3A30%3A00") || later.url!.query!.contains("time=09:30:00"))
        #expect(requests.count == 2)
    }

    @Test(arguments: [false, true]) func newPageAcquiresPreviouslyUncoveredTripEvidence(earlier: Bool) async throws {
        var times = ""
        var trips = ""
        var rows: [String] = []
        for index in 0..<7 {
            let hour = index == 6 ? (earlier ? 4 : 12) : 8
            let minute = index == 6 ? 0 : index * 10
            let planned = String(format: "%02d:%02d:00", hour, minute)
            let arrival = String(format: "%02d:%02d:00", hour, minute + 5)
            times += "run-\(index),\(planned),\(planned),a,1\nrun-\(index),\(arrival),\(arrival),c,2\n"
            trips += "route,service,run-\(index),Destination\n"
            let body = liveBoard(stops: liveStop("a", planned: planned, predicted: planned) + ","
                + liveStop("c", planned: arrival, predicted: arrival, arrival: arrival), time: planned, realtime: planned)
                .replacingOccurrences(of: "same-journey", with: "journey-\(index)")
            rows.append(String(body.dropFirst("{\"Departure\":[".count).dropLast(2)))
        }
        let fixture = try await RealtimeTestFixture(stopTimes: times, trips: trips); defer { fixture.remove() }
        let body = "{\"Departure\":[" + rows.joined(separator: ",") + "]}"
        let (client, host) = RealtimeBoardProtocol.client { _ in body }; defer { RealtimeBoardProtocol.remove(host) }
        let planner = JourneyPlanner(realtimeClient: client)
        let session = try await planner.makePlanningSession(databaseURL: fixture.database,
            request: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
                           time: .departAt(RealtimeTestFixture.date("08:00:00"))))
        let initial = try await session.calculate()
        #expect(!initial.journeys.contains { $0.legs.contains { if case let .transit(t) = $0 { t.tripID == "run-6" } else { false } } })
        let count = RealtimeBoardProtocol.requests(host).count
        let later = try await session.calculate(page: earlier ? .earlier : .later)
        let late = try #require(later.journeys.first { $0.legs.contains { if case let .transit(t) = $0 { t.tripID == "run-6" } else { false } } })
        #expect(late.statusEvidence.coverage == .live)
        #expect(late.effectiveDeparture == RealtimeTestFixture.date(earlier ? "04:00:00" : "12:00:00"))
        #expect(RealtimeBoardProtocol.requests(host).count > count)
    }

    @Test func denseBoardRetainsLiveDepartureBeyondTheOldJourneyCap() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let irrelevant = #"{"Product":{"line":"999"},"time":"08:00:00","date":"2026-09-30","rtTime":"08:01:00"}"#
        let actual = String(liveBoard(stops: "").dropFirst("{\"Departure\":[".count).dropLast(2))
        let body = "{\"Departure\":[" + (Array(repeating: irrelevant, count: 60) + [actual]).joined(separator: ",") + "]}"
        let (client, host) = RealtimeBoardProtocol.client { _ in body }; defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let batch = try await provider.patches(for: ["a"], from: RealtimeTestFixture.date("08:00:00"),
            through: RealtimeTestFixture.date("09:30:00"), refreshPolicy: .useCache)
        #expect(batch.patches.first?.events.first?.departureSource == .reported)
        #expect(batch.networkRequests == 1 && batch.incompleteStopIDs.isEmpty)
        #expect(RealtimeBoardProtocol.requests(host).first?.url?.query?.contains("maxJourneys=-1") == true)
        #expect(batch.matchingRejections[.noCandidate, default: 0] > 0)
    }
}
