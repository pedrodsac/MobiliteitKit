import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimeReachabilityTests {
    @Test(arguments: 0..<7, [false, true])
    func singlePassMatchesIndependentBoardingTraversal(patchCase: Int, busOnly: Bool) async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "loop,08:00:00,08:00:00,a,1\nloop,08:10:00,08:10:00,b,2\n"
                + "loop,08:20:00,08:20:00,a,3\nloop,08:40:00,08:40:00,c,4\n"
                + "tram,08:16:00,08:16:00,a,1\ntram,08:30:00,08:30:00,d,2\n"
                + "inactive,08:16:00,08:16:00,a,1\ninactive,08:17:00,08:17:00,c,2\n",
            trips: "route,service,loop,Destination\ntram-route,service,tram,Neighbor\n"
                + "route,absent,inactive,Destination\n",
            serviceDates: "service,20260930,1\nabsent,20261001,1\n",
            additionalStops: "d,Neighbor,49.7001,6.2001\n",
            additionalRoutes: "tram-route,operator,T1,Tram,0\n")
        defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let snapshot = await router.snapshot
        let a = try #require(snapshot.stopByID["a"])
        let b = try #require(snapshot.stopByID["b"])
        let c = try #require(snapshot.stopByID["c"])
        let d = try #require(snapshot.stopByID["d"])
        #expect(snapshot.nearbyTransferStopsByStop[c].contains(d))
        let arrivals = [a: RealtimeTestFixture.date("08:15:00"), b: RealtimeTestFixture.date("08:12:00")]
        let date = try GTFSDate(parsing: "20260930")
        var events: [RealtimeStopEventPatch] = []
        if patchCase == 1 || patchCase == 2 {
            let source: RealtimeTimingSource = patchCase == 1 ? .reported : .estimated
            events = [
                .init(stopID: "a", effectiveDeparture: RealtimeTestFixture.date("08:05:00"),
                      departureSource: source, stopSequence: 1),
                .init(stopID: "b", effectiveArrival: RealtimeTestFixture.date("08:15:00"),
                      arrivalSource: source, stopSequence: 2),
                .init(stopID: "c", effectiveArrival: RealtimeTestFixture.date("08:45:00"),
                      arrivalSource: source, stopSequence: 4)
            ]
        } else if patchCase == 5 {
            events = [.init(stopID: "a", stopSequence: 3, boardingAllowed: false)]
        } else if patchCase == 6 {
            events = [.init(stopID: "c", stopSequence: 4, alightingAllowed: false)]
        }
        let status: RealtimeTripStatus = patchCase == 3 ? .cancelled : patchCase == 4 ? .unreachable : .active
        let patches: [RealtimePatchKey: RealtimeTripPatch] = patchCase == 0 ? [:] : [
            .init(tripID: "loop", serviceDate: date): .init(tripID: "loop", serviceDate: date,
                                                         status: status, events: events)
        ]
        let modes: TransitModeMask = busOnly ? .init(rawValue: 1 << 3) : .all
        for through in ["08:34:00", "08:50:00"] {
            let limit = RealtimeTestFixture.date(through)
            let expected = Self.independentBoardings(arrivals, snapshot: snapshot, modes: modes,
                                                      through: limit, patches: patches)
            let actual = RealtimeReachability.advance(arrivals, snapshot: snapshot,
                serviceDays: snapshot.serviceDays, allowedModes: modes, through: limit,
                lookback: 7_200, deadline: .now.advanced(by: .seconds(5)), patches: patches,
                freshBoardingReport: { $0?.departureSource == .reported })
            #expect(actual == expected)
        }
    }

    /// Reference explores every reachable boarding and its downstream stops
    /// independently, including repeated visits to the same physical stop.
    private static func independentBoardings(_ arrivals: [Int: Date], snapshot: RoutingSnapshot,
                                             modes: TransitModeMask, through: Date,
                                             patches: [RealtimePatchKey: RealtimeTripPatch]) -> [Int: Date] {
        var improved = arrivals
        for (stop, reach) in arrivals {
            for tripIndex in snapshot.tripIndicesByDepartureStop[stop] {
                let trip = snapshot.trips[tripIndex]
                guard modes.contains(routeType: snapshot.routes[trip.route].type) else { continue }
                for day in snapshot.serviceDays where day.activeServices.contains(trip.service) {
                    let patch = patches[.init(tripID: trip.id, serviceDate: day.date)]
                    guard patch?.status != .cancelled, patch?.status != .unreachable else { continue }
                    for position in trip.times.indices where trip.times[position].stop == stop {
                        let board = trip.times[position]
                        guard board.pickup == 0, let scheduled = board.departure else { continue }
                        let event = patch?.event(stopID: snapshot.stops[stop].id, sequence: board.sequence)
                        let departure = event?.effectiveDeparture ?? day.start.addingTimeInterval(Double(scheduled))
                        let lookback = event?.departureSource == .reported ? 0.0 : 7_200.0
                        guard event?.boardingAllowed != false,
                              departure >= reach.addingTimeInterval(-lookback), departure <= through else { continue }
                        let rescue = max(0, reach.timeIntervalSince(departure))
                        for downstream in trip.times.dropFirst(position + 1) where downstream.dropoff == 0 {
                            guard let scheduled = downstream.arrival else { continue }
                            let report = patch?.event(stopID: snapshot.stops[downstream.stop].id,
                                                      sequence: downstream.sequence)
                            guard report?.alightingAllowed != false else { continue }
                            let arrival = (report?.effectiveArrival ?? day.start.addingTimeInterval(Double(scheduled)))
                                .addingTimeInterval(rescue)
                            guard arrival <= through else { continue }
                            improved[downstream.stop] = min(improved[downstream.stop] ?? .distantFuture, arrival)
                            for neighbor in snapshot.nearbyTransferStopsByStop[downstream.stop] {
                                improved[neighbor] = min(improved[neighbor] ?? .distantFuture, arrival)
                            }
                        }
                    }
                }
            }
        }
        return improved
    }
}
