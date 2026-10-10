import Foundation
import Testing
@testable import MobiliteitKit

/// Opt-in, deterministic full-feed replay. The identical file can run against
/// the pre-optimization package; it uses no new implementation interfaces.
@Suite struct InstalledEquivalenceReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROUTING_EQUIVALENCE_DATABASE"] != nil))
    func completeJourneysAndPaging() async throws {
        let env = ProcessInfo.processInfo.environment
        let database = URL(fileURLWithPath: try #require(env["ROUTING_EQUIVALENCE_DATABASE"]))
        let output = URL(fileURLWithPath: try #require(env["ROUTING_EQUIVALENCE_OUTPUT"]))
        let store = try GTFSStore(databaseAt: database)
        var records: [[String: Any]] = []
        let scenarios: [(String, JourneyEndpoint, JourneyEndpoint, String, RouteQueryDirection)] = [
            ("departure", .coordinate(.init(latitude: 49.6541071, longitude: 6.2296443), label: "Gromscheed"),
             .stop(id: "000200417019"), "2026-10-08T08:00:00+02:00", .departAfter),
            ("arrival", .stop(id: "000200417019"), .stop(id: "000200508004"),
             "2026-10-08T09:00:00+02:00", .arriveBy),
            ("esch", .stop(id: "000220402034"), .stop(id: "000400000095"),
             "2026-10-08T18:35:00+02:00", .departAfter)
        ]
        for (name, origin, destination, timestamp, direction) in scenarios {
            let anchor = try #require(ISO8601DateFormatter().date(from: timestamp))
            let live = EquivalenceRealtime(clock: anchor)
            let router = try await TransitRouter(databaseURL: database, walkingProvider: EquivalenceWalking(),
                realtimeProvider: live, clock: { anchor })
            let session = try await router.makeSession(for: .init(origin: origin, destination: destination,
                departureTime: anchor, direction: direction, realtimePolicy: .bestEffort(refresh: .forceRefresh)))
            let initial = try await session.initial(count: 8, searchHorizon: 3_600)
            #expect(!initial.journeys.isEmpty)
            records.append(record(initial, scenario: name, operation: "initial"))
            records.append(record(try await session.later(count: 3), scenario: name, operation: "later"))
            records.append(record(try await session.earlier(count: 3), scenario: name, operation: "earlier"))
            let ride = try #require(initial.journeys.first?.legs.compactMap {
                if case let .transit(value) = $0 { value } else { nil }
            }.first)
            let day = try #require(ride.instance?.serviceDate)
            let converter = ServiceInstantConverter(timeZone: TimeZone(identifier: "Europe/Luxembourg")!)
            let times = try await store.stopTimes(forTripID: ride.tripID)
            let events = times.map { time -> RealtimeStopEventPatch in
                let arrival = time.arrival.map { converter.date(serviceDate: day, serviceSeconds: $0.rawValue) }
                let departure = time.departure.map { converter.date(serviceDate: day, serviceSeconds: $0.rawValue) }
                return .init(stopID: time.stop.id, scheduledDeparture: departure,
                    effectiveDeparture: departure?.addingTimeInterval(60), departureSource: .reported,
                    scheduledArrival: arrival, effectiveArrival: arrival?.addingTimeInterval(60),
                    arrivalSource: .reported, stopSequence: time.sequence, observedAt: anchor)
            }
            for (operation, patches) in [
                ("delayed", [RealtimeTripPatch(tripID: ride.tripID, serviceDate: day, events: events)]),
                ("cancelled", [RealtimeTripPatch(tripID: ride.tripID, serviceDate: day, status: .cancelled, events: [])]),
                ("reset", [])
            ] {
                await live.set(patches)
                let page = try await session.initial(count: 8, searchHorizon: 3_600)
                records.append(record(page, scenario: name, operation: operation))
            }
        }
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .prettyPrinted]).write(to: output)
    }

    private func record(_ page: JourneyPage, scenario: String, operation: String) -> [String: Any] {
        ["scenario": scenario, "operation": operation, "recommended": page.recommendedJourneyID?.value ?? "",
         "earlier": page.hasEarlier, "later": page.hasLater, "realtime": page.realtimeState.rawValue,
         "journeys": page.journeys.map { journey -> [String: Any] in
             ["id": journey.id.value, "origin": String(reflecting: journey.origin),
              "destination": String(reflecting: journey.destination),
              "scheduledDeparture": journey.scheduledDeparture.timeIntervalSince1970,
              "scheduledArrival": journey.scheduledArrival.timeIntervalSince1970,
              "effectiveDeparture": journey.effectiveDeparture.timeIntervalSince1970,
              "effectiveArrival": journey.effectiveArrival.timeIntervalSince1970,
              "transfers": journey.transferCount, "walking": journey.walkingDuration,
              "distance": journey.walkingDistance, "waiting": journey.waitingDuration,
              "inVehicle": journey.inVehicleDuration, "feed": journey.feedGeneration,
              "accessibility": String(reflecting: journey.accessibility), "preferred": journey.matchesPreferredMode,
              "statusEvidence": String(reflecting: journey.statusEvidence),
              "fingerprint": journey.transitFingerprint, "legs": String(reflecting: journey.legs)]
         }]
    }
}

private struct EquivalenceWalking: WalkingRoutingProvider {
    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        let meters = distance(request.source, request.destination)
        return .init(durationSeconds: Int(ceil(meters / 1.2)), distanceMeters: meters)
    }
    func route(_ request: WalkingRequest) async throws -> WalkingRoute {
        let estimate = try await estimate(request)
        return .init(durationSeconds: estimate.durationSeconds, distanceMeters: estimate.distanceMeters,
            polyline: [request.source, request.destination])
    }
}
private actor EquivalenceRealtime: RealtimeRoutingProvider {
    let clock: Date
    var values: [RealtimeTripPatch] = []
    init(clock: Date) { self.clock = clock }
    func set(_ patches: [RealtimeTripPatch]) { values = patches }
    func patches(for request: RealtimeRoutingRequest) async throws -> RealtimePatchBatch {
        try await patches(for: request.stopIDs, from: request.from, through: request.through, refreshPolicy: request.refreshPolicy)
    }
    func patches(for stopIDs: [String], from: Date, through: Date, refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        .init(patches: values, requestedStopIDs: Set(stopIDs), coveredStopIDs: Set(stopIDs), fetchedAt: clock)
    }
}
