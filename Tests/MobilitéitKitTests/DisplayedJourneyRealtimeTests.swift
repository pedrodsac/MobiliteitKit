import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct DisplayedJourneyRealtimeTests {
    @Test(arguments: ["live", "cancelled", "missed"])
    func displayedConnectionsRefreshEvenWhenSearchHasNoLiveBudget(outcome: String) async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "first,08:00:00,08:00:00,a,1\nfirst,08:10:00,08:10:00,b,2\n"
                + "second,08:15:00,08:15:00,b,1\nsecond,08:25:00,08:25:00,c,2\n",
            trips: "route,service,first,Transfer\nroute,service,second,Destination\n")
        defer { fixture.remove() }
        let provider = DisplayedRealtimeProvider(outcome: outcome)
        let planner = JourneyPlanner(realtimeProvider: provider)
        let anchor = RealtimeTestFixture.date("07:55:00")
        let session = try await planner.makePlanningSession(databaseURL: fixture.database, request: .init(
            origin: .stop(id: "a"), destination: .stop(id: "c"), time: .departAt(anchor),
            preferences: .init(maxTransfers: 1), realtimeAcquisitionBudgetMilliseconds: 0,
            realtimeSearchWorkBudgetMilliseconds: 0))
        let initial = try await session.calculate()
        let original = try #require(initial.journeys.first)
        #expect(original.statusEvidence.coverage == .scheduleOnly)
        #expect(await provider.requests.isEmpty)
        let updated = try await session.refreshDisplayedRealtime(now: anchor)
        #expect(Set(await provider.requests.flatMap(\.stopIDs)) == ["a", "b"])
        #expect(updated.earlierCursor?.generation == initial.earlierCursor?.generation)
        if outcome == "live" {
            let journey = try #require(updated.journeys.first)
            #expect(journey.id == original.id)
            #expect(journey.statusEvidence.coverage == .live)
            let rides = journey.legs.compactMap { if case let .transit(t) = $0 { t } else { nil } }
            #expect(rides.count == 2)
            #expect(rides.allSatisfy { $0.board.timingSource == .reported && $0.alight.timingSource == .reported })
            #expect(journey.effectiveArrival == RealtimeTestFixture.date("08:27:00"))
        } else {
            #expect(updated.journeys.isEmpty)
            #expect(updated.invalidatedIDs.contains(original.id))
        }
    }

    @Test func everyBoardGetsAnOpportunityWhenAnEarlierGroupFails() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let provider = DisplayedRealtimeProvider(failFirst: true)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let start = RealtimeTestFixture.date("08:00:00")
        let targets = (0..<20).map {
            RealtimeBoardTarget(stopID: "stop-\($0)", from: start,
                through: start.addingTimeInterval(7_200), lines: ["line-\($0)"])
        }
        let batches = try await DisplayedJourneyRealtime.acquire(targets: targets, router: router,
            refresh: .forceRefresh, timeout: .seconds(1))
        let requests = await provider.requests
        #expect(requests.count == 3)
        #expect(requests.map { $0.stopIDs.count } == [8, 8, 4])
        #expect(Set(requests.flatMap(\.stopIDs)) == Set(targets.map(\.stopID)))
        #expect(requests.allSatisfy { $0.refreshPolicy == .forceRefresh && $0.deadline != nil })
        #expect(batches.count == 2)
    }

    @Test func cancellationStopsRemainingBoards() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let provider = DisplayedRealtimeProvider(delay: true)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let start = RealtimeTestFixture.date("08:00:00")
        let targets = (0..<20).map {
            RealtimeBoardTarget(stopID: "stop-\($0)", from: start, through: start.addingTimeInterval(60))
        }
        let task = Task {
            try await DisplayedJourneyRealtime.acquire(targets: targets, router: router,
                                                       refresh: .useCache, timeout: .seconds(1))
        }
        await provider.waitForRequest()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await provider.requests.count == 1)
    }

    @Test func aNewCalculationRejectsAnInFlightRefresh() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let provider = DisplayedRealtimeProvider(hold: true)
        let planner = JourneyPlanner(realtimeProvider: provider)
        let anchor = RealtimeTestFixture.date("07:55:00")
        let session = try await planner.makePlanningSession(databaseURL: fixture.database, request: .init(
            origin: .stop(id: "a"), destination: .stop(id: "c"), time: .departAt(anchor),
            realtimeAcquisitionBudgetMilliseconds: 0))
        _ = try await session.calculate()
        let refresh = Task { try await session.refreshDisplayedRealtime(now: anchor) }
        await provider.waitForRequest()
        let replacement = try await session.calculate()
        await provider.release()
        do {
            _ = try await refresh.value
            Issue.record("A refresh from the previous calculation was accepted")
        } catch JourneyPlanningError.supersededRequest {
            #expect(await session.result().revision == replacement.revision)
        }
    }

    @Test func displayedRefreshIncludesPreviouslyLoadedPages() async throws {
        var trips = "", times = ""
        let day = try GTFSDate(parsing: "20260930")
        var patches: [RealtimeTripPatch] = []
        for index in 0..<7 {
            let minute = index == 6 ? 240 : index * 10
            let departure = RealtimeTestFixture.date("08:00:00").addingTimeInterval(Double(minute * 60))
            let arrival = departure.addingTimeInterval(300)
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(identifier: "Europe/Luxembourg")
            formatter.dateFormat = "HH:mm:ss"
            let d = formatter.string(from: departure), a = formatter.string(from: arrival)
            trips += "route,service,run-\(index),Destination\n"
            times += "run-\(index),\(d),\(d),a,1\nrun-\(index),\(a),\(a),c,2\n"
            patches.append(.init(tripID: "run-\(index)", serviceDate: day, events: [
                .init(stopID: "a", scheduledDeparture: departure, effectiveDeparture: departure,
                      departureSource: .reported, stopSequence: 1, observedAt: .now),
                .init(stopID: "c", scheduledArrival: arrival, effectiveArrival: arrival,
                      arrivalSource: .reported, stopSequence: 2, observedAt: .now)
            ]))
        }
        let fixture = try await RealtimeTestFixture(stopTimes: times, trips: trips); defer { fixture.remove() }
        let planner = JourneyPlanner(realtimeProvider: DisplayedProfileProvider(values: patches))
        let anchor = RealtimeTestFixture.date("07:55:00")
        let session = try await planner.makePlanningSession(databaseURL: fixture.database, request: .init(
            origin: .stop(id: "a"), destination: .stop(id: "c"), time: .departAt(anchor),
            realtimeAcquisitionBudgetMilliseconds: 0, pagingPolicy: .adjacentTimeWindows))
        let initial = try await session.calculate()
        #expect(initial.journeys.count == 6)
        let page = try await session.calculate(page: .later)
        #expect(page.journeys.count == 7)
        let tracked = try await session.refreshDisplayedRealtime(now: anchor)
        #expect(Set(tracked.journeys.map(\.id)) == Set(page.journeys.map(\.id)))
        #expect(tracked.journeys.allSatisfy { $0.statusEvidence.coverage == .live })
        #expect(tracked.browsingWindow == page.browsingWindow)
        #expect(tracked.laterCursor == page.laterCursor)
    }
}

private struct DisplayedProfileProvider: RealtimeRoutingProvider {
    let values: [RealtimeTripPatch]
    func patches(for stopIDs: [String], from: Date, through: Date,
                 refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        .init(patches: values, requestedStopIDs: Set(stopIDs), coveredStopIDs: Set(stopIDs))
    }
}

private actor DisplayedRealtimeProvider: RealtimeRoutingProvider {
    let outcome: String
    let failFirst: Bool
    let delay: Bool
    let hold: Bool
    var requests: [RealtimeRoutingRequest] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?
    init(outcome: String = "live", failFirst: Bool = false, delay: Bool = false, hold: Bool = false) {
        self.outcome = outcome; self.failFirst = failFirst; self.delay = delay; self.hold = hold
    }
    func waitForRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func patches(for request: RealtimeRoutingRequest) async throws -> RealtimePatchBatch {
        requests.append(request)
        waiter?.resume(); waiter = nil
        if delay { try await Task.sleep(for: .seconds(30)) }
        if hold { await withCheckedContinuation { held = $0 } }
        if failFirst, requests.count == 1 { throw HafasRealtimeRoutingError.timedOut }
        let day = try GTFSDate(parsing: "20260930")
        let observed = Date.now
        func patch(_ trip: String, from: String, to: String, departure: String, arrival: String,
                   delay: TimeInterval, status: RealtimeTripStatus = .active) -> RealtimeTripPatch {
            let d = RealtimeTestFixture.date(departure), a = RealtimeTestFixture.date(arrival)
            return .init(tripID: trip, serviceDate: day, status: status, events: [
                .init(stopID: from, scheduledDeparture: d, effectiveDeparture: d.addingTimeInterval(delay),
                      departureSource: .reported, stopSequence: 1, observedAt: observed),
                .init(stopID: to, scheduledArrival: a, effectiveArrival: a.addingTimeInterval(delay),
                      arrivalSource: .reported, stopSequence: 2, observedAt: observed)
            ])
        }
        return .init(patches: [
            patch("first", from: "a", to: "b", departure: "08:00:00", arrival: "08:10:00",
                  delay: outcome == "missed" ? 600 : 60),
            patch("second", from: "b", to: "c", departure: "08:15:00", arrival: "08:25:00",
                  delay: 120, status: outcome == "cancelled" ? .cancelled : .active)
        ], requestedStopIDs: Set(request.stopIDs), coveredStopIDs: Set(request.stopIDs))
    }
    func release() { held?.resume(); held = nil }
    func patches(for stopIDs: [String], from: Date, through: Date,
                 refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        try await patches(for: .init(stopIDs: stopIDs, from: from, through: through, refreshPolicy: refreshPolicy))
    }
}
