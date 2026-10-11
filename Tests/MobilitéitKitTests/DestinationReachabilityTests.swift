import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct DestinationReachabilityTests {
    @Test(arguments: [0, 1, 2])
    func zeroRideReachabilityAllowsOneWalkingTransferAndPriorPathways(pathwayDirection: Int) async throws {
        var files = preventionFiles(trips: "bus,service,ride,Destination\n",
            times: "ride,08:00:00,08:00:00,a,1\nride,08:10:00,08:10:00,b,2\nride,08:20:00,08:20:00,c,3\n")
        files["stops.txt"] = "stop_id,stop_name,stop_lat,stop_lon\na,A,49.6,6.10\nb,B,49.6,6.11\nc,C,49.6,6.12\n"
        if pathwayDirection != 0 {
            let from = pathwayDirection == 1 ? "a" : "b"
            let to = pathwayDirection == 1 ? "b" : "a"
            files["pathways.txt"] = "pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional,traversal_time,length\np,\(from),\(to),1,0,300,750\n"
        }
        let fixture = try await RoutingPreventionFixture(files: files)
        defer { fixture.remove() }
        let snapshot = await fixture.router.snapshot
        let a = try #require(snapshot.stopByID["a"]), b = try #require(snapshot.stopByID["b"])
        let c = try #require(snapshot.stopByID["c"])
        #expect(snapshot.nearbyTransferStopsByStop[a].contains(b))
        #expect(snapshot.nearbyTransferStopsByStop[b].contains(c))
        #expect(!snapshot.nearbyTransferStopsByStop[a].contains(c))
        let reachability = Raptor.DestinationReachability(snapshot: snapshot, egressStops: [c], maxRides: 2)
        #expect(reachability.stopsByRemainingRides[0][c])
        #expect(reachability.stopsByRemainingRides[0][b])
        // a→b→c requires two pedestrian batches. A declared a→b
        // pathway can precede the one permitted pedestrian batch instead.
        #expect(reachability.stopsByRemainingRides[0][a] == (pathwayDirection == 1))
        #expect(reachability.stopsByRemainingRides[1][a])
        let discovery = Raptor.DestinationReachability(snapshot: snapshot,
            egressStops: [c], maxRides: 2, allowWalkingChains: true)
        #expect(discovery.stopsByRemainingRides[0][a])
    }
}
