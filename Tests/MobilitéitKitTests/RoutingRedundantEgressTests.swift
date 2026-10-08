import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Avoid walking back when the boarded bus serves the destination")
struct RoutingRedundantEgressTests {
    private let b = Coordinate(latitude: 49.629, longitude: 6.1)
    private let d = Coordinate(latitude: 49.63, longitude: 6.1)

    @Test(arguments: [false, true], [false, true])
    func useDestinationStopInsteadOfTwentyMinuteDetour(overshoot: Bool, accessible: Bool) async throws {
        let fixture = try await makeFixture(overshoot: overshoot, accessible: accessible)
        defer { fixture.remove() }
        let page = try await fixture.profile()
        #expect(!page.journeys.isEmpty)
        #expect(page.journeys.allSatisfy { $0.firstRide?.alight.stop.id == "d" })
        #expect(page.journeys.allSatisfy { $0.effectiveArrival == date(hour: 8, minute: 20) })
        let session = try await fixture.planning()
        for result in [try await session.calculate(refresh: .scheduleOnly),
                       try await session.calculate(page: .later, refresh: .scheduleOnly),
                       try await session.refreshRealtime(now: date(hour: 8))] {
            #expect(!result.journeys.isEmpty)
            #expect(result.journeys.allSatisfy { $0.firstRide?.alight.stop.id == "d" })
        }
        let arriveBy = try await fixture.profile(fixture.query(anchor: date(hour: 9), direction: .arriveBy))
        #expect(arriveBy.journeys.map(\.id) == page.journeys.map(\.id))
    }

    @Test func keepGenuinelyFasterEarlyExit() async throws {
        let fixture = try await makeFixture(overshoot: false, accessible: true, walkSeconds: 300)
        defer { fixture.remove() }
        let page = try await fixture.profile()
        #expect(page.journeys.contains { $0.firstRide?.alight.stop.id == "b" && $0.effectiveArrival == date(hour: 8, minute: 15) })
        #expect(page.journeys.contains { $0.firstRide?.alight.stop.id == "d" })
    }

    @Test func forbiddenDestinationDropoffStillUsesTheWalk() async throws {
        let fixture = try await makeFixture(overshoot: true, accessible: true, forbidDropoff: true)
        defer { fixture.remove() }
        let page = try await fixture.profile()
        #expect(!page.journeys.isEmpty)
        #expect(page.journeys.allSatisfy { $0.firstRide?.alight.stop.id == "b" })
    }

    @Test func walkingRefinementRemovesNewlyWastefulExit() async throws {
        let fixture = try await makeFixture(overshoot: false, accessible: true, walkSeconds: 300)
        defer { fixture.remove() }
        let session = try await fixture.planning()
        let initial = try await session.calculate(refresh: .scheduleOnly)
        let early = try #require(initial.journeys.first { $0.firstRide?.alight.stop.id == "b" })
        let index = try #require(early.legs.firstIndex { if case .walk = $0 { true } else { false } })
        guard case let .walk(walk) = early.legs[index] else { return }
        let result = try await session.submitWalkingRefinement(.init(
            token: try #require(initial.refinementTokens[early.id]), range: index..<(index + 1),
            route: .init(durationSeconds: 1800, distanceMeters: 100, polyline: [b, d]),
            departure: walk.departure, arrival: walk.departure.addingTimeInterval(1800)))
        #expect(!result.journeys.isEmpty)
        #expect(result.journeys.allSatisfy { $0.firstRide?.alight.stop.id == "d" })
        #expect(result.recommendedJourneyID == result.journeys.first?.id)
    }

    @Test func requiredWheelchairCannotUseInaccessibleDestination() async throws {
        let fixture = try await makeFixture(overshoot: true, accessible: true, inaccessibleDestination: true)
        defer { fixture.remove() }
        let page = try await fixture.profile(fixture.query(preferences: .init(wheelchair: .required)))
        #expect(page.journeys.isEmpty)
    }

    @Test(arguments: [119, 120, 121, 420])
    func sixStaysAboardUntilLuxexpoUnlessWalkingArrivesEarlier(walkingSeconds: Int) async throws {
        let fixture = try await luxexpoFixture(walkingSeconds: walkingSeconds)
        defer { fixture.remove() }
        let query = fixture.query(anchor: date(hour: 14, minute: 14))
        let page = try await fixture.profile(query)
        #expect(!page.journeys.isEmpty)
        func obeysRule(_ journeys: [Journey]) -> Bool {
            if walkingSeconds < 120 { return journeys.contains { $0.firstRide?.alight.stop.id == "b" } }
            return journeys.allSatisfy { $0.firstRide?.alight.stop.id == "x" }
        }
        #expect(obeysRule(page.journeys))
        #expect(page.journeys.allSatisfy {
            $0.legs.compactMap { if case let .transit(ride) = $0 { ride.route.shortName } else { nil } } == ["6", "212"]
        })
        let session = try await fixture.planning(.init(origin: query.origin, destination: query.destination,
            time: .departAt(query.departureTime)))
        for result in [try await session.calculate(refresh: .scheduleOnly),
                       try await session.calculate(page: .later, refresh: .scheduleOnly)] {
            #expect(!result.journeys.isEmpty)
            #expect(obeysRule(result.journeys))
        }
    }

    @Test func shortcutCannotBypassLuxexpoTransferMinimum() async throws {
        let fixture = try await luxexpoFixture(walkingSeconds: 420, transferMinimum: 450)
        defer { fixture.remove() }
        let page = try await fixture.profile(fixture.query(anchor: date(hour: 14, minute: 14)))
        // The 14:31 connection cannot be reached with the feed's 7.5-minute
        // buffer after arriving on the 6 at 14:25. Use the next 212 instead.
        #expect(!page.journeys.isEmpty)
        #expect(page.journeys.allSatisfy { $0.firstRide?.alight.stop.id == "x" })
        #expect(page.journeys.allSatisfy { transitTripInstanceSequence($0) == ["6", "later-212"] })
    }

    private func luxexpoFixture(walkingSeconds: Int, transferMinimum: Int? = nil) async throws -> RoutingPreventionFixture {
        var files = scenarioFiles(routes: "bus,operator,6,Bus,3\nother,operator,212,Bus,3\n",
            stops: scenarioStops([("a", "Konrad Adenauer", 49.6), ("b", "Mathias Tresch", 49.61),
                ("x", "Gare routière Luxexpo", 49.6105), ("d", "Destination", 49.63)]),
            trips: "bus,service,6,,,,\nother,service,212,,,,\nother,service,later-212,,,,\n",
            stopTimes: "6,14:19:00,14:19:00,a,1\n6,14:23:00,14:23:00,b,2\n6,14:25:00,14:25:00,x,3\n212,14:31:00,14:31:00,x,1\n212,14:39:00,14:39:00,d,2\nlater-212,14:41:00,14:41:00,x,1\nlater-212,14:49:00,14:49:00,d,2\n")
        if let transferMinimum {
            files["transfers.txt"] = "from_stop_id,to_stop_id,transfer_type,min_transfer_time\nx,x,2,\(transferMinimum)\n"
        }
        return try await RoutingPreventionFixture(files: files, walking: PreventionWalking(edges: [
            .init(from: .init(latitude: 49.61, longitude: 6.1),
                  to: .init(latitude: 49.6105, longitude: 6.1), seconds: walkingSeconds)
        ]))
    }

    @Test(arguments: [false, true])
    func liveTimingAndSkippedStopsKeepNecessaryWalk(skipped: Bool) async throws {
        let realtime = PreventionRealtime(patches: [.init(tripID: "321",
            serviceDate: try GTFSDate(parsing: "20260904"), events: [.init(stopID: "d",
                effectiveArrival: skipped ? date(hour: 8, minute: 20) : date(hour: 8, minute: 50),
                arrivalSource: .reported, stopSequence: 3, alightingAllowed: !skipped,
                observedAt: date(hour: 8))])])
        let fixture = try await makeFixture(overshoot: false, accessible: true, realtime: realtime)
        defer { fixture.remove() }
        let page = try await fixture.profile(fixture.query(live: true))
        #expect(page.journeys.contains { $0.firstRide?.alight.stop.id == "b" && $0.effectiveArrival == date(hour: 8, minute: 40) })
        if skipped { #expect(!page.journeys.contains { $0.firstRide?.alight.stop.id == "d" }) }
    }

    private func makeFixture(overshoot: Bool, accessible: Bool, walkSeconds: Int? = nil,
                             forbidDropoff: Bool = false, inaccessibleDestination: Bool = false,
                             realtime: (any RealtimeRoutingProvider)? = nil) async throws -> RoutingPreventionFixture {
        let accessibility = accessible ? 1 : 0
        var files = scenarioFiles(routes: "bus,operator,321,Bus,3\n", stops: "",
            trips: "", stopTimes: "")
        files["stops.txt"] = "stop_id,stop_name,stop_lat,stop_lon,wheelchair_boarding\na,Origin,49.6,6.1,\(accessibility)\nb,Nearby,49.629,6.1,\(accessibility)\nd,Destination,49.63,6.1,\(inaccessibleDestination ? 2 : accessibility)\n"
        files["trips.txt"] = "route_id,service_id,trip_id,wheelchair_accessible\nbus,service,321,\(accessibility)\n"
        let nearbyTime = overshoot ? "08:30:00" : "08:10:00"
        let nearbySequence = overshoot ? 3 : 2
        let destinationSequence = overshoot ? 2 : 3
        let destinationDropoff = forbidDropoff ? 1 : 0
        let nearby = "321,\(nearbyTime),\(nearbyTime),b,\(nearbySequence),0\n"
        let destination = "321,08:20:00,08:20:00,d,\(destinationSequence),\(destinationDropoff)\n"
        files["stop_times.txt"] = "trip_id,arrival_time,departure_time,stop_id,stop_sequence,drop_off_type\n321,08:05:00,08:05:00,a,1,0\n" + (overshoot ? destination + nearby : nearby + destination)
        return try await RoutingPreventionFixture(files: files, walking: PreventionWalking(edges: [
            .init(from: b, to: d, seconds: walkSeconds ?? (overshoot ? 600 : 1800))
        ]), realtime: realtime)
    }
}
