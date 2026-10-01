import Foundation
import Testing
@testable import MobiliteitKit

/// Supplemental replay over installed data; no downloads or live requests.
@Suite struct InstalledRoutingPreventionReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROUTING_BENCHMARK_DATABASE"] != nil))
    func circularMidnightFirstLastAndCancellation() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["ROUTING_BENCHMARK_DATABASE"])
        let database = URL(fileURLWithPath: path)
        let router = try await TransitRouter(databaseURL: database)
        let snapshot = await router.snapshot
        struct Example {
            let trip: Int
            let day: GTFSDate
            let board: Int
            let alight: Int
            let departure: Int32
            let arrival: Int32
        }
        let examples = snapshot.trips.indices.compactMap { index -> Example? in
            let trip = snapshot.trips[index]
            guard !trip.isFrequencyTemplate,
                  let day = snapshot.serviceDays.first(where: { $0.activeServices.contains(trip.service) })?.date,
                  let board = trip.times.indices.first(where: { trip.times[$0].pickup == 0 && trip.times[$0].departure != nil }),
                  let alight = trip.times.indices.reversed().first(where: {
                      $0 > board && trip.times[$0].dropoff == 0 && trip.times[$0].arrival != nil
                          && trip.times[$0].stop != trip.times[board].stop
                  }), let departure = trip.times[board].departure, let arrival = trip.times[alight].arrival,
                  arrival > departure else { return nil }
            return .init(trip: index, day: day, board: board, alight: alight, departure: departure, arrival: arrival)
        }
        let circular = try #require(examples.first { example in
            let stops = snapshot.trips[example.trip].times.map(\.stop)
            return Set(stops).count < stops.count
        }, "Installed feed must contain a circular/repeated-stop control")
        let midnight = try #require(examples.first { $0.departure < 86_400 && $0.arrival >= 86_400 },
                                    "Installed feed must contain a cross-midnight service")
        let overflow = try #require(examples.first { $0.departure >= 86_400 },
                                    "Installed feed must contain an overflow service-day departure")
        let first = try #require(examples.min { $0.departure < $1.departure })
        let last = try #require(examples.max { $0.departure < $1.departure })
        var cancellationQuery: RouteQuery?
        var cancelledRide: TransitLeg?
        for (name, example) in [("circular", circular), ("midnight", midnight), ("overflow", overflow),
                                ("first-service", first), ("last-service", last)] {
            let trip = snapshot.trips[example.trip]
            let anchor = snapshot.converter.date(serviceDate: example.day, serviceSeconds: example.departure).addingTimeInterval(-1)
            let query = RouteQuery(origin: .stop(id: snapshot.stops[trip.times[example.board].stop].id),
                destination: .stop(id: snapshot.stops[trip.times[example.alight].stop].id), departureTime: anchor,
                preferences: .init(maxTransfers: 0))
            let session = try await router.makeSession(for: query)
            let page = try await session.initial(count: 20, searchHorizon: min(86_400, Double(example.arrival - example.departure) + 60))
            #expect(!page.journeys.isEmpty)
            #expect(Set(page.journeys.map(\.id)).count == page.journeys.count)
            for journey in page.journeys {
                #expect(journey.transferCount == 0)
                #expect(!JourneyPublicationValidator.assess(journey, query: query).isInvalid)
                #expect(JourneyFeedValidator.failure(journey, snapshot: snapshot, preferences: query.preferences) == nil)
                #expect(journey.effectiveDeparture >= anchor && journey.effectiveArrival > journey.effectiveDeparture)
            }
            if cancellationQuery == nil {
                cancellationQuery = query; cancelledRide = page.journeys.first?.firstRide
            }
            print("INSTALLED_PREVENTION_REPLAY \(name) service=\(example.day.compactString) anchorTrip=\(trip.id) journeys=\(page.journeys.count)")
        }
        let query = try #require(cancellationQuery)
        let ride = try #require(cancelledRide)
        let identity = try #require(ride.instance)
        let cancelled = try await TransitRouter(databaseURL: database, realtimeProvider: InstalledCancellationReplay(
            patch: .init(tripID: ride.tripID, serviceDate: identity.serviceDate, status: .cancelled, events: [])))
        let liveQuery = RouteQuery(origin: query.origin, destination: query.destination, departureTime: query.departureTime,
            preferences: query.preferences, realtimePolicy: .bestEffort())
        let session = try await cancelled.makeSession(for: liveQuery)
        let page = try await session.initial(count: 20)
        #expect(page.journeys.allSatisfy { journey in
            !journey.legs.contains { if case let .transit(t) = $0 { t.instance == identity } else { false } }
        })
        print("INSTALLED_PREVENTION_REPLAY cancellation trip=\(identity.stableKey) remaining=\(page.journeys.count)")
    }
}

private struct InstalledCancellationReplay: RealtimeRoutingProvider {
    let patch: RealtimeTripPatch
    func patches(for stopIDs: [String], from: Date, through: Date, refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        .init(patches: [patch], requestedStopIDs: Set(stopIDs), coveredStopIDs: Set(stopIDs))
    }
}
