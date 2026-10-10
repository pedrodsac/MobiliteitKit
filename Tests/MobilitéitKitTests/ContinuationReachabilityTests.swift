import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Continuation-aware destination pruning")
struct ContinuationReachabilityTests {
    @Test(arguments: [false, true])
    func continuationChainRemainsReachableWithoutAnExtraBoarding(explicit: Bool) async throws {
        var files = preventionFiles(trips:
            "bus,service,first,First,,,\(explicit ? "" : "vehicle")\n"
            + "other,service,second,Second,,,\(explicit ? "" : "vehicle")\n"
            + "bus,service,third,Third,,,\(explicit ? "" : "vehicle")\n",
            times: "first,08:00:00,08:00:00,a,1\nfirst,08:10:00,08:10:00,b,2\n"
                + "second,08:10:30,08:10:30,b,1\nsecond,08:20:00,08:20:00,c,2\n"
                + "third,08:20:30,08:20:30,c,1\nthird,08:30:00,08:30:00,d,2\n")
        if explicit { files["transfers.txt"] = "from_trip_id,to_trip_id,transfer_type\nfirst,second,4\nsecond,third,4\n" }
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        let snapshot = await fixture.router.snapshot
        let destination = snapshot.stopByID["d"]!
        let bound = Raptor.DestinationReachability(snapshot: snapshot, egressStops: [destination], maxRides: 1)
        #expect(bound.stopsByRemainingRides[0][snapshot.stopByID["b"]!])
        #expect(bound.stopsByRemainingRides[0][snapshot.stopByID["c"]!])
        #expect(!bound.stopsByRemainingRides[0][snapshot.stopByID["a"]!])
        let page = try await fixture.profile(fixture.query(preferences: .init(maxTransfers: 0)))
        let journey = try #require(page.journeys.first)
        #expect(transitTripInstanceSequence(journey) == ["first", "second", "third"])
        #expect(journey.transferCount == 0)
    }

    @Test(arguments: [false, true])
    func unrelatedStopsStillPruneWhenAnotherPartOfTheFeedHasContinuations(nearContinuation: Bool) async throws {
        var files = preventionFiles(trips: "bus,service,first,,,,vehicle\nother,service,second,,,,vehicle\nbus,service,dead,,,,\n",
            times: "first,08:00:00,08:00:00,a,1\nfirst,08:10:00,08:10:00,b,2\n"
                + "second,08:10:30,08:10:30,b,1\nsecond,08:20:00,08:20:00,d,2\n"
                + "dead,08:00:00,08:00:00,a,1\ndead,08:05:00,08:05:00,c,2\n")
        if nearContinuation {
            files["stops.txt"] = files["stops.txt"]!.replacingOccurrences(of: "C,49.62", with: "C,49.612")
        }
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        let snapshot = await fixture.router.snapshot
        let bound = Raptor.DestinationReachability(snapshot: snapshot, egressStops: [snapshot.stopByID["d"]!], maxRides: 2)
        #expect(snapshot.hasContinuations)
        if nearContinuation {
            // The loose topology bound admits walking C → B before the onward
            // run. That would require another boarding, so the final-round
            // bound must still reject C for a zero-transfer query.
            #expect(bound.stopsByRemainingRides[0][snapshot.stopByID["c"]!])
        } else {
            #expect(bound.stopsByRemainingRides.allSatisfy { !$0[snapshot.stopByID["c"]!] })
        }
        #expect(snapshot.continuations.blockTripsByID["vehicle"]?.count == 2)
        let search = try await Raptor.search(snapshot: snapshot, query: fixture.query(preferences: .init(maxTransfers: 0)),
            access: [.init(stop: snapshot.stopByID["a"]!, seconds: 0, distance: 0, walk: nil)],
            egress: [.init(stop: snapshot.stopByID["d"]!, seconds: 0, distance: 0, walk: nil)],
            patches: [], walking: nil, profileHorizon: 3600)
        #expect(!search.candidates.isEmpty)
        // The dead-end A → C pattern must not be scanned at all, despite this
        // feed having a valid stay-aboard connection on the useful branch.
        #expect(search.scannedPatterns == 1)
    }
}
