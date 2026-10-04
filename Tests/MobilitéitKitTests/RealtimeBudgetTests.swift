import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimeBudgetTests {
    @Test(arguments: [false, true])
    func slowLaterSliceRetainsPredictionsAndCancellations(cancelled: Bool) async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { request in
            let time = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "time" }?.value
            return time == "08:00:00" ? .milliseconds(20) : .seconds(5)
        }) { _ in
            liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:08:00") + ","
                + liveStop("c", planned: "08:20:00", predicted: "08:28:00", arrival: "08:28:00"),
                extra: cancelled ? ",\"cancelled\":true" : "")
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let started = ContinuousClock.now
        let batch = try await provider.patches(for: .init(stopIDs: ["a"],
            from: RealtimeTestFixture.date("08:00:00"), through: RealtimeTestFixture.date("09:30:00"),
            timeout: .seconds(1), deadline: started.advanced(by: .seconds(1)), targets: [
                .init(stopID: "a", from: RealtimeTestFixture.date("08:00:00"), through: RealtimeTestFixture.date("08:30:00")),
                .init(stopID: "a", from: RealtimeTestFixture.date("09:00:00"), through: RealtimeTestFixture.date("09:30:00"))]))
        let patch = try #require(batch.patches.first)
        #expect(patch.tripID == "trip")
        #expect(patch.status == (cancelled ? .cancelled : .active))
        #expect(patch.events.first?.departureSource == .reported)
        #expect(patch.events.first?.effectiveDeparture == RealtimeTestFixture.date("08:08:00"))
        #expect(batch.coveredStopIDs == ["a"])
        #expect(batch.incompleteStopIDs == ["a"])
        #expect(RealtimeBoardProtocol.requests(host).count == 2)
        #expect(started.duration(to: .now) < .seconds(2))

        // Exercise the complete acquisition → matching → RAPTOR path as well.
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let session = try await router.makeSession(for: .init(
            origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("08:05:00"),
            realtimePolicy: .bestEffort(configuration: .init(acquisitionBudgetMilliseconds: 1_000),
                                      refresh: .forceRefresh)))
        let page = try await session.initial()
        if cancelled {
            #expect(page.journeys.isEmpty)
        } else {
            let journey = try #require(page.journeys.first)
            #expect(journey.statusEvidence.coverage == .live)
            #expect(journey.effectiveDeparture == RealtimeTestFixture.date("08:08:00"))
            #expect(journey.effectiveArrival == RealtimeTestFixture.date("08:28:00"))
        }
        #expect(page.realtimeState == .partial)
    }

    @Test func oldConfigurationDecodesWithFourSecondBudget() throws {
        let json = Data(#"{"scheduledLookbackSeconds":7200,"minimumForwardHorizonSeconds":5400,"maximumConcurrentBoardRequests":4,"maximumRefinementWaves":4}"#.utf8)
        let old = try JSONDecoder().decode(RealtimeConfiguration.self, from: json)
        #expect(old.acquisitionBudgetMilliseconds == 4_000)
        #expect(old.searchWorkBudgetMilliseconds == nil)
        var changed = old
        changed.acquisitionBudgetMilliseconds = 2_000
        changed.searchWorkBudgetMilliseconds = 4_100
        #expect(try JSONDecoder().decode(RealtimeConfiguration.self, from: JSONEncoder().encode(changed)) == changed)
    }

    @Test func shiftedClockReusesSlicesAndFetchesOnlyMissingCoverage() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { _ in liveBoard(stops: "") }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let from = RealtimeTestFixture.date("08:05:00")
        let through = RealtimeTestFixture.date("09:35:00")
        let first = try await provider.patches(for: ["a"], from: from, through: through, refreshPolicy: .useCache)
        #expect(first.networkRequests == 1)
        let moved = try await provider.patches(for: ["a"], from: from.addingTimeInterval(10),
                                              through: through.addingTimeInterval(10), refreshPolicy: .useCache)
        #expect(moved.networkRequests == 0)
        #expect(moved.cacheHits == 1)
        let extended = try await provider.patches(for: ["a"], from: from.addingTimeInterval(30 * 60),
                                                 through: through.addingTimeInterval(30 * 60), refreshPolicy: .useCache)
        #expect(extended.networkRequests == 1)
        #expect(extended.cacheHits == 1)
        let refreshed = try await provider.patches(for: ["a"], from: from, through: through, refreshPolicy: .forceRefresh)
        #expect(refreshed.networkRequests == 1)
    }

    @Test func expiredDeadlineDoesNotUseCachedEvidenceAsComplete() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { _ in liveBoard(stops: "") }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let from = RealtimeTestFixture.date("08:00:00"), through = RealtimeTestFixture.date("08:30:00")
        _ = try await provider.patches(for: ["a"], from: from, through: through, refreshPolicy: .useCache)
        do {
            let batch = try await provider.patches(for: .init(stopIDs: ["a"], from: from, through: through,
                timeout: .zero, deadline: ContinuousClock.now.advanced(by: .seconds(-1))))
            #expect(batch.patches.isEmpty)
            #expect(batch.incompleteStopIDs == ["a"])
        } catch HafasRealtimeRoutingError.unavailable {
            // No work began before the expired deadline.
        }
        #expect(RealtimeBoardProtocol.requests(host).count == 1)
    }
    @Test func deadlineDuringMatchingKeepsCompletedPatchesAndReportsPartialCoverage() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let stops = liveStop("a", planned: "08:00:00", predicted: "08:08:00") + ","
            + liveStop("b", planned: "08:10:00", predicted: "08:18:00", arrival: "08:18:00") + ","
            + liveStop("c", planned: "08:20:00", predicted: "08:28:00", arrival: "08:28:00")
        let object = try JSONSerialization.jsonObject(with: Data(liveBoard(stops: stops).utf8)) as! [String: Any]
        let row = (object["Departure"] as! [[String: Any]])[0]
        let rows = (0..<392).map { index in
            var value = row
            value["JourneyDetailRef"] = ["ref": "journey-\(index)"]
            return value
        }
        let data = try JSONSerialization.data(withJSONObject: ["Departure": rows])
        let payload = String(decoding: data, as: UTF8.self)
        let (client, host) = RealtimeBoardProtocol.client { _ in payload }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let from = RealtimeTestFixture.date("08:00:00"), through = RealtimeTestFixture.date("08:30:00")
        _ = await provider.prepareSchedules(for: ["a"], from: from.addingTimeInterval(-7_200),
                                           through: through, deadline: ContinuousClock.now.advanced(by: .seconds(4)))
        _ = await provider.cachedStopTimes(forTripID: "trip")
        _ = try await client.departureBoardSnapshot(.init(stationID: "a", language: "en",
            date: try GTFSDate(parsing: "20260930"), time: ServiceTime(rawValue: 8 * 3_600),
            durationMinutes: 30, maximumJourneys: -1, realtimeMode: .serverDefault, includePasslist: true))
        let started = ContinuousClock.now
        let batch = try await provider.patches(for: .init(stopIDs: ["a"], from: from, through: through,
            timeout: .milliseconds(100), deadline: started.advanced(by: .milliseconds(100))))
        #expect(!batch.patches.isEmpty)
        #expect(batch.incompleteStopIDs == ["a"])
        #expect(batch.boardMatchingMilliseconds > 0)
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(RealtimeBoardProtocol.requests(host).count == 1)
    }

    @Test(arguments: [false, true])
    func itineraryFilterKeepsFullTimetableAmbiguity(ambiguous: Bool) async throws {
        let otherTime = ambiguous ? "08:00:00" : "09:00:00"
        let otherArrival = ambiguous ? "08:20:00" : "09:20:00"
        let fixture = try await RealtimeTestFixture(
            stopTimes: "trip,08:00:00,08:00:00,a,1\ntrip,08:20:00,08:20:00,c,2\n"
                + "other,\(otherTime),\(otherTime),a,1\nother,\(otherArrival),\(otherArrival),c,2\n",
            trips: "route,service,trip,Destination\nroute,service,other,Destination\n")
        defer { fixture.remove() }
        let first = try JSONSerialization.jsonObject(with: Data(liveBoard(stops:
            liveStop("a", planned: "08:00:00", predicted: "08:01:00") + ","
                + liveStop("c", planned: "08:20:00", predicted: "08:21:00", arrival: "08:21:00"),
            realtime: "08:01:00").utf8)) as! [String: Any]
        let other = try JSONSerialization.jsonObject(with: Data(liveBoard(stops:
            liveStop("a", planned: otherTime, predicted: otherTime) + ","
                + liveStop("c", planned: otherArrival, predicted: otherArrival, arrival: otherArrival),
            time: otherTime, realtime: otherTime, extra: ",\"cancelled\":true")
            .replacingOccurrences(of: "same-journey", with: "other-journey").utf8)) as! [String: Any]
        let payload = String(decoding: try JSONSerialization.data(withJSONObject:
            ["Departure": (first["Departure"] as! [[String: Any]]) + (other["Departure"] as! [[String: Any]])]), as: UTF8.self)
        let (client, host) = RealtimeBoardProtocol.client { _ in payload }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let batch = try await provider.patches(for: .init(stopIDs: ["a"],
            from: RealtimeTestFixture.date("07:55:00"), through: RealtimeTestFixture.date("10:00:00"),
            refreshPolicy: .useCache, tripIDs: ["trip"]))
        if ambiguous {
            #expect(batch.patches.isEmpty)
            #expect(batch.matchingRejections[.ambiguousCandidate, default: 0] > 0)
        } else {
            #expect(batch.patches.map(\.tripID) == ["trip"])
            #expect(batch.patches.first?.events.first?.departureSource == .reported)
        }
    }

    @Test func explicitSessionDeadlineCanCoverSeveralRequestWaves() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in .milliseconds(100) }) { _ in
            liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:01:00") + ","
                + liveStop("c", planned: "08:20:00", predicted: "08:21:00", arrival: "08:21:00"), realtime: "08:01:00")
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client,
                                                        requestTimeout: .milliseconds(20))
        let from = RealtimeTestFixture.date("07:55:00"), through = RealtimeTestFixture.date("08:30:00")
        let standalone = try await provider.patches(for: .init(stopIDs: ["a"], from: from, through: through,
            refreshPolicy: .forceRefresh, timeout: .seconds(1)))
        #expect(standalone.patches.isEmpty)
        let started = ContinuousClock.now
        let sessionBatch = try await provider.patches(for: .init(stopIDs: ["a"], from: from, through: through,
            refreshPolicy: .forceRefresh, timeout: .seconds(1), deadline: started.advanced(by: .seconds(1)), tripIDs: ["trip"]))
        #expect(sessionBatch.patches.first?.events.first?.departureSource == .reported)
        #expect(sessionBatch.incompleteStopIDs.isEmpty)
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test func parallelItineraryBatchCompletesBeforeTheDeadline() async throws {
        let ids = (0..<16).map { "boarding-\($0)" }
        let fixture = try await RealtimeTestFixture(
            stopTimes: ids.map { "\($0),08:00:00,08:00:00,\($0),1\n\($0),08:20:00,08:20:00,c,2\n" }.joined(),
            trips: ids.map { "route,service,\($0),Destination\n" }.joined(),
            additionalStops: ids.map { "\($0),Boarding \($0),49.6,6.1\n" }.joined())
        defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in .milliseconds(200) }) { request in
            let stop = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "id" }!.value!
            return liveBoard(stops: liveStop(stop, planned: "08:00:00", predicted: "08:01:00") + ","
                + liveStop("c", planned: "08:20:00", predicted: "08:21:00", arrival: "08:21:00"),
                realtime: "08:01:00", stop: stop)
                .replacingOccurrences(of: "same-journey", with: stop)
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client,
                                                        maximumConcurrentBoardRequests: 16)
        let started = ContinuousClock.now
        let batch = try await provider.patches(for: .init(stopIDs: ids,
            from: RealtimeTestFixture.date("07:55:00"), through: RealtimeTestFixture.date("08:30:00"),
            refreshPolicy: .forceRefresh, maximumConcurrentRequests: 16, timeout: .milliseconds(700),
            deadline: started.advanced(by: .milliseconds(700)), tripIDs: Set(ids)))
        #expect(batch.patches.count == 16)
        #expect(batch.coveredStopIDs == Set(ids))
        #expect(batch.incompleteStopIDs.isEmpty)
        #expect(started.duration(to: .now) < .seconds(1.5))
    }

    @Test func exhaustedSearchWorkAllowanceRetainsTheFullScheduledSearch() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { _ in liveBoard(stops: "") }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let page = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("07:55:00"), realtimePolicy: .bestEffort(
                configuration: .init(acquisitionBudgetMilliseconds: 1_000, searchWorkBudgetMilliseconds: 0))))
            .initial(count: 10, searchHorizon: 3 * 3_600)
        #expect(!page.journeys.isEmpty)
        #expect(page.metrics.candidatesGenerated > 0)
        #expect(page.journeys.first?.effectiveArrival == RealtimeTestFixture.date("08:20:00"))
        #expect(RealtimeBoardProtocol.requests(host).isEmpty)
    }

}
