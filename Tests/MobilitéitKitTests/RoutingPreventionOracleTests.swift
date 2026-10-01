import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Routing prevention: independent tiny-network oracle")
struct RoutingPreventionOracleTests {
    struct Ride { let id: String; let from: String; let to: String; let departure: Int; let arrival: Int }
    struct Outcome: Hashable { let departure: Int; let arrival: Int; let transfers: Int }

    @Test func generatedTimetablesMatchExhaustiveFeasibleParetoOutcomes() async throws {
        var state: UInt64 = 0x49cafe
        func random(_ upper: Int) -> Int { state = state &* 6364136223846793005 &+ 1; return Int(state >> 32) % upper }
        let links = [("a", "b"), ("b", "d"), ("a", "d"), ("a", "c"), ("c", "d"), ("b", "c"), ("c", "b"), ("c", "d")]
        for seed in 0..<32 {
            let rides = links.enumerated().map { index, link in
                let departure = random(2400)
                return Ride(id: "ride-\(index)", from: link.0, to: link.1, departure: departure, arrival: departure + 60 + random(600))
            }
            func clock(_ seconds: Int) -> String { ServiceTime(rawValue: Int32(8 * 3600 + seconds)).gtfsString }
            let files = preventionFiles(trips: rides.map { "bus,service,\($0.id),,,,\n" }.joined(),
                times: rides.map { "\($0.id),\(clock($0.departure)),\(clock($0.departure)),\($0.from),1\n\($0.id),\(clock($0.arrival)),\(clock($0.arrival)),\($0.to),2\n" }.joined())
            let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
            var exhaustive: Set<Outcome> = []
            func visit(stop: String, time: Int, first: Int?, used: Set<String>) {
                if stop == "d", let first { exhaustive.insert(.init(departure: first, arrival: time, transfers: used.count - 1)); return }
                if used.count == 3 { return }
                for ride in rides where ride.from == stop && !used.contains(ride.id) && ride.departure >= time + (used.isEmpty ? 0 : 120) {
                    visit(stop: ride.to, time: ride.arrival, first: first ?? ride.departure, used: used.union([ride.id]))
                }
            }
            visit(stop: "a", time: 0, first: nil, used: [])
            let pareto = exhaustive.filter { candidate in
                !exhaustive.contains { other in
                    other != candidate && other.departure >= candidate.departure && other.arrival <= candidate.arrival && other.transfers <= candidate.transfers
                }
            }
            let query = fixture.query(preferences: .init(maxTransfers: 2))
            let actual = try await fixture.profile(query)
            let outcomes = Set(actual.journeys.map { journey in
                Outcome(departure: Int(journey.effectiveDeparture.timeIntervalSince(date(hour: 8))),
                    arrival: Int(journey.effectiveArrival.timeIntervalSince(date(hour: 8))), transfers: journey.transferCount)
            })
            #expect(outcomes == Set(pareto), "oracle seed \(seed)")
            #expect(actual.journeys.allSatisfy { !JourneyPublicationValidator.assess($0, query: query).isInvalid })
        }
    }

    // 02–04, 06–07, 38: remove a cycle only when the timetable offers a valid shortcut.
    @Test(arguments: [false, true])
    func redundantCycleAndNecessaryReverseInterchange(forbidShortcut: Bool) async throws {
        var files = preventionFiles(trips: "bus,service,in,,,,\nbus,service,away,,,,\nbus,service,back,,,,\nother,service,out,,,,\n",
            times: "in,08:00:00,08:00:00,a,1\nin,08:10:00,08:10:00,b,2\naway,08:12:00,08:12:00,b,1\naway,08:14:00,08:14:00,c,2\nback,08:16:00,08:16:00,c,1\nback,08:18:00,08:18:00,b,2\nout,08:20:00,08:20:00,b,1\nout,08:30:00,08:30:00,d,2\n")
        if forbidShortcut { files["transfers.txt"] = "from_stop_id,to_stop_id,from_trip_id,to_trip_id,transfer_type\nb,b,in,out,3\n" }
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        let session = try await fixture.router.makeSession(for: fixture.query(preferences: .init(maxTransfers: 3)))
        let initial = try await session.initial()
        let journey = try #require(initial.journeys.first)
        #expect(journey.transferCount == (forbidShortcut ? 3 : 1))
        #expect(transitTripInstanceSequence(journey) == (forbidShortcut ? ["in", "away", "back", "out"] : ["in", "out"]))
    }

    // 17, 20: inferior boarding disappears; a barrier-required access detour remains.
    @Test(arguments: [false, true])
    func inferiorBoardingVersusRequiredWalkingDetour(barrier: Bool) async throws {
        let a = Coordinate(latitude: 49.6, longitude: 6.1), b = Coordinate(latitude: 49.61, longitude: 6.1)
        let origin = Coordinate(latitude: 49.5999, longitude: 6.1)
        let files = preventionFiles(trips: "bus,service,ride,,,,\n", times: "ride,08:10:00,08:10:00,a,1\nride,08:11:00,08:11:00,b,2\nride,08:20:00,08:20:00,d,3\n")
        var edges = [PreventionWalking.Edge(from: origin, to: b, seconds: 180)]
        if !barrier { edges.append(.init(from: origin, to: a, seconds: 60)) }
        let fixture = try await RoutingPreventionFixture(files: files, walking: PreventionWalking(edges: edges)); defer { fixture.remove() }
        let profile = try await fixture.profile(fixture.query(origin: .coordinate(origin, label: nil)))
        #expect(profile.journeys.count == 1)
        #expect(profile.journeys.first?.firstRide?.boardSequence == (barrier ? 2 : 1))
    }

    // 21: staying aboard beats a premature exit; a genuinely faster early exit remains.
    @Test(arguments: [30, 180])
    func alightingChoiceUsesActualEgressTime(earlyWalk: Int) async throws {
        let b = Coordinate(latitude: 49.61, longitude: 6.1), d = Coordinate(latitude: 49.63, longitude: 6.1)
        let destination = Coordinate(latitude: 49.6301, longitude: 6.1)
        let files = preventionFiles(trips: "bus,service,ride,,,,\n", times: "ride,08:10:00,08:10:00,a,1\nride,08:19:00,08:19:00,b,2\nride,08:20:00,08:20:00,d,3\n")
        let walking = PreventionWalking(edges: [.init(from: b, to: destination, seconds: earlyWalk), .init(from: d, to: destination, seconds: 30)])
        let fixture = try await RoutingPreventionFixture(files: files, walking: walking); defer { fixture.remove() }
        let profile = try await fixture.profile(fixture.query(destination: .coordinate(destination, label: nil)))
        #expect(profile.journeys.first?.firstRide?.alightSequence == (earlyWalk == 30 ? 2 : 3))
    }
}
