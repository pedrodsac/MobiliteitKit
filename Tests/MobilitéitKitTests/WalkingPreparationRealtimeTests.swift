import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct WalkingPreparationRealtimeTests {
    @Test(arguments: [0, 3])
    func preliminaryVehiclesAreCheckedDuringDiscoveryAndCancellationStillWins(maxTransfers: Int) async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let provider = OverlappingPreparationRealtime()
        let router = try await TransitRouter(databaseURL: fixture.database,
            walkingProvider: PreparationWalking(), realtimeProvider: provider)
        let page = try await router.makeSession(for: .init(origin: .stop(id: "a"),
            destination: .stop(id: "c"), departureTime: RealtimeTestFixture.date("07:55:00"),
            preferences: .init(maxTransfers: maxTransfers),
            realtimePolicy: .bestEffort(configuration: .init(maximumConcurrentBoardRequests: 32,
                acquisitionBudgetMilliseconds: 1_000))))
            .initial(count: 1, searchHorizon: 3_600)
        #expect(page.journeys.isEmpty)
        #expect(await provider.overlapped)
        #expect(await Array(provider.limits.prefix(2)).sorted() == [4, 28])
        #expect(await provider.peak <= 32)
    }

    @Test func preliminaryVehicleChecksPreserveThePublishedTransferCount() async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "first,08:00:00,08:00:00,a,1\nfirst,08:10:00,08:10:00,b,2\n"
                + "second,08:15:00,08:15:00,b,1\nsecond,08:25:00,08:25:00,d,2\n"
                + "third,08:30:00,08:30:00,d,1\nthird,08:40:00,08:40:00,c,2\n"
                + "trip,08:05:00,08:05:00,a,1\ntrip,08:45:00,08:45:00,c,2\n",
            trips: "route,service,first,Transfer\nroute,service,second,Transfer\n"
                + "route,service,third,Destination\nroute,service,trip,Direct\n",
            additionalStops: "d,Third boarding,49.68,6.15\n")
        defer { fixture.remove() }
        let provider = OverlappingPreparationRealtime()
        let router = try await TransitRouter(databaseURL: fixture.database,
            walkingProvider: PreparationWalking(), realtimeProvider: provider)
        let page = try await router.makeSession(for: .init(origin: .stop(id: "a"),
            destination: .stop(id: "c"), departureTime: RealtimeTestFixture.date("07:55:00"),
            preferences: .init(maxTransfers: 2),
            realtimePolicy: .bestEffort(configuration: .init(maximumConcurrentBoardRequests: 32,
                acquisitionBudgetMilliseconds: 1_000))))
            .initial(count: 1, searchHorizon: 3_600)
        let tripIDs = page.journeys.flatMap(\.legs).compactMap { leg -> String? in
            guard case let .transit(ride) = leg else { return nil }
            return ride.tripID
        }
        #expect(tripIDs == ["first", "second", "third"])
        #expect(page.metrics.pointRaptorScans >= 2)
        #expect(await provider.limits.contains(4))
        #expect(await provider.peak <= 32)
    }

    @Test(arguments: [false, true])
    func preparedScheduledConnectionCannotSurviveLiveInvalidation(cancelled: Bool) async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "first,08:00:00,08:00:00,a,1\nfirst,08:10:00,08:10:00,b,2\n"
                + "second,08:15:00,08:15:00,d,1\nsecond,08:30:00,08:30:00,c,2\n",
            trips: "route,service,first,Transfer\nconnection,service,second,Destination\n",
            additionalStops: "d,Nearby transfer,49.6501,6.15\n",
            additionalRoutes: "connection,operator,202,Connection,3\n")
        defer { fixture.remove() }
        let walking = PreparationWalking()
        let day = try GTFSDate(parsing: "20260930")
        let patch = RealtimeTripPatch(tripID: "first", serviceDate: day,
            status: cancelled ? .cancelled : .active, events: cancelled ? [] : [
                .init(stopID: "a", scheduledDeparture: RealtimeTestFixture.date("08:00:00"),
                    effectiveDeparture: RealtimeTestFixture.date("08:10:00"),
                    departureSource: .reported, stopSequence: 1),
                .init(stopID: "b", scheduledArrival: RealtimeTestFixture.date("08:10:00"),
                    effectiveArrival: RealtimeTestFixture.date("08:20:00"),
                    arrivalSource: .reported, stopSequence: 2)
            ])
        let live = PreparationRealtime(patch: patch)
        let router = try await TransitRouter(databaseURL: fixture.database,
            walkingProvider: walking, realtimeProvider: live)
        let page = try await router.makeSession(for: .init(
            origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("07:55:00"),
            preferences: .init(maxTransfers: 1),
            realtimePolicy: .bestEffort(configuration: .init(acquisitionBudgetMilliseconds: 1_000))))
            .initial(count: 1, searchHorizon: 3_600)
        // The speculative schedule really computed the walking interchange.
        #expect(await walking.interchangeRequests > 0)
        // Neither a cancelled feeder nor one arriving after the connection may
        // be published from that preliminary schedule-only search.
        #expect(page.journeys.isEmpty)
        #expect(page.metrics.pointRaptorScans == 2)
    }
}

private actor OverlappingPreparationRealtime: RealtimeRoutingProvider {
    var limits: [Int] = []
    var active = 0
    var peak = 0
    var overlapped = false
    func patches(for request: RealtimeRoutingRequest) async throws -> RealtimePatchBatch {
        let first = request.maximumConcurrentRequests == 28
        if active > 0 { overlapped = true }
        limits.append(request.maximumConcurrentRequests)
        active += request.maximumConcurrentRequests
        peak = max(peak, active)
        defer { active -= request.maximumConcurrentRequests }
        try await Task.sleep(for: first ? .milliseconds(100) : .milliseconds(10))
        return .init(patches: first ? [] : [.init(tripID: "trip",
            serviceDate: try GTFSDate(parsing: "20260930"), status: .cancelled, events: [])],
            requestedStopIDs: Set(request.stopIDs), coveredStopIDs: Set(request.stopIDs))
    }
    func patches(for stopIDs: [String], from: Date, through: Date,
                 refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        try await patches(for: .init(stopIDs: stopIDs, from: from, through: through, refreshPolicy: refreshPolicy))
    }
}

private actor PreparationRealtime: RealtimeRoutingProvider {
    let patch: RealtimeTripPatch
    init(patch: RealtimeTripPatch) { self.patch = patch }
    func patches(for stopIDs: [String], from: Date, through: Date,
                 refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        try await Task.sleep(for: .milliseconds(80))
        return .init(patches: [patch], requestedStopIDs: Set(stopIDs), coveredStopIDs: Set(stopIDs))
    }
}

private actor PreparationWalking: WalkingRoutingProvider {
    var interchangeRequests = 0
    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        let value = try await route(request)
        return .init(durationSeconds: value.durationSeconds, distanceMeters: value.distanceMeters)
    }
    func route(_ request: WalkingRequest) async throws -> WalkingRoute {
        guard request.source.latitude == 49.65, request.destination.latitude == 49.6501 else {
            throw Unavailable.route
        }
        interchangeRequests += 1
        return .init(durationSeconds: 60, distanceMeters: 100,
            polyline: [request.source, request.destination])
    }
    private enum Unavailable: Error { case route }
}
