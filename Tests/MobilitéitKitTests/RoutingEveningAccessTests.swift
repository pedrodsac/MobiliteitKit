import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Evening access avoids driving away to board a reachable bus")
struct RoutingEveningAccessTests {
    @Test(arguments: [false, true])
    func breedewuesAccessReplacesBothFeederBuses(walkAvailable: Bool) async throws {
        let origin = Coordinate(latitude: 49.5999, longitude: 6.1)
        let gromscheed = Coordinate(latitude: 49.6, longitude: 6.1)
        let breedewues = Coordinate(latitude: 49.602, longitude: 6.1)
        let files = scenarioFiles(
            routes: "a,operator,322,Bus,3\nb,operator,326,Bus,3\nc,operator,850,Bus,3\nt,operator,T1,Tram,0\n",
            stops: scenarioStops([("a", "Gromscheed", 49.6), ("r", "Rue des Résidences", 49.6005),
                ("g", "Rue du Golf", 49.601), ("b", "Breedewues", 49.602),
                ("h", "Heienhaff", 49.61), ("t", "Heienhaff P+R", 49.6105),
                ("d", "Philharmonie / MUDAM", 49.63)]),
            trips: "a,service,322,,,,\nb,service,326,,,,\nc,service,850,,,,\nt,service,T1,,,,\n",
            stopTimes: """
            322,23:18:00,23:18:00,a,1
            322,23:19:00,23:19:00,r,2
            326,23:33:00,23:33:00,a,1
            326,23:36:00,23:36:00,r,2
            326,23:39:00,23:39:00,g,3
            850,23:43:00,23:43:00,b,1
            850,23:45:00,23:45:00,g,2
            850,23:47:00,23:47:00,h,3
            T1,23:54:00,23:54:00,t,1
            T1,24:08:00,24:08:00,d,2

            """)
        var edges = [
            PreventionWalking.Edge(from: origin, to: gromscheed, seconds: 360),
            .init(from: .init(latitude: 49.61, longitude: 6.1),
                  to: .init(latitude: 49.6105, longitude: 6.1), seconds: 180),
        ]
        // Fifteen minutes is within the default access budget, but exceeds
        // the old five-minute extra-walking cutoff by four minutes.
        if walkAvailable { edges.append(.init(from: origin, to: breedewues, seconds: 900)) }
        let anchor = date(hour: 23)
        let fixture = try await RoutingPreventionFixture(files: files, walking: PreventionWalking(edges: edges), now: anchor)
        defer { fixture.remove() }
        let query = fixture.query(origin: .coordinate(origin, label: nil), anchor: anchor)
        let page = try await fixture.profile(query)
        let expected = walkAvailable ? ["850", "T1"] : ["326", "850", "T1"]
        #expect(!page.journeys.isEmpty)
        #expect(page.journeys.allSatisfy { transitTripInstanceSequence($0) == expected })
        if walkAvailable {
            let first = try #require(page.journeys.first)
            #expect(first.firstRide?.board.stop.name == "Breedewues")
            #expect(first.effectiveDeparture == date(hour: 23, minute: 28))
        }
        let session = try await fixture.planning(.init(origin: query.origin, destination: query.destination,
                                                       time: .departAt(anchor)))
        for result in [try await session.calculate(refresh: .scheduleOnly),
                       try await session.calculate(page: .later, refresh: .scheduleOnly),
                       try await session.refreshRealtime(now: anchor)] {
            #expect(!result.journeys.isEmpty)
            #expect(result.journeys.allSatisfy { transitTripInstanceSequence($0) == expected })
        }
    }
}
