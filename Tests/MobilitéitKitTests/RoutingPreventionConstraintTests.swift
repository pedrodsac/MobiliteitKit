import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Routing prevention: movement and hard constraints")
struct RoutingPreventionConstraintTests {
    // 12, 39–40: physical platform movement must consume positive verified time.
    @Test(arguments: [0, -1, 60, 500])
    func pathwayMovementAndTotalTransferMinimum(seconds: Int) async throws {
        var files = preventionFiles(trips: "bus,service,in,,,,\nother,service,out,,,,\n",
            times: "in,08:00:00,08:00:00,a,1\nin,08:10:00,08:10:00,b,2\nout,08:13:00,08:13:00,c,1\nout,08:20:00,08:20:00,d,2\n")
        files["pathways.txt"] = "pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional,traversal_time,length\np,b,c,1,1,\(seconds),500\n"
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("fixture.zip"); let database = directory.appendingPathComponent("feed.sqlite")
        try writeArchive(to: archive, files: files)
        if seconds <= 0 {
            await #expect(throws: GTFSArchiveError.self) { try await GTFSArchiveInstaller.install(archiveAt: archive, databaseAt: database) }
        } else {
            let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
            #expect(try await fixture.profile().journeys.isEmpty == (seconds > 180))
            if seconds == 60 {
                let journey = try #require(try await fixture.profile().journeys.first)
                #expect(journey.walkingDuration == 60)
                let second = try #require(journey.legs.compactMap { if case let .transit(t) = $0 { t } else { nil } }.last)
                #expect(second.requiredTransferSecondsAfterWalking == 60)
            }
        }
    }

    // 46–47: required wheelchair access and modes are enforced before pruning.
    @Test(arguments: [0, 1, 2])
    func requiredVehicleAccessIsNotInferredFromUnknown(code: Int) async throws {
        var files = preventionFiles(trips: "bus,service,ride,,,,\n", times: "ride,08:05:00,08:05:00,a,1\nride,08:20:00,08:20:00,d,2\n")
        files["stops.txt"] = "stop_id,stop_name,stop_lat,stop_lon,wheelchair_boarding\na,A,49.6,6.1,1\nd,D,49.63,6.1,1\n"
        files["trips.txt"] = "route_id,service_id,trip_id,wheelchair_accessible,bikes_allowed\nbus,service,ride,\(code),1\n"
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        #expect(try await fixture.profile(fixture.query(preferences: .init(wheelchair: .required))).journeys.isEmpty == (code != 1))
        #expect(try await fixture.profile(fixture.query(preferences: .init(allowedModes: .init(rawValue: 1 << 2)))).journeys.isEmpty)
        #expect(try await fixture.profile(fixture.query(preferences: .init(bike: .required))).journeys.count == 1)
    }

    @Test(arguments: [0, 1]) func continuationRequiresVehicleButNotInterchangeAccess(vehicle: Int) async throws {
        var files = preventionFiles(trips: "bus,service,in,,,,\nother,service,out,,,,\n", times: "in,08:00:00,08:00:00,a,1\nin,08:10:00,08:10:00,b,2\nout,08:10:00,08:10:00,b,1\nout,08:20:00,08:20:00,d,2\n")
        files["stops.txt"] = "stop_id,stop_name,stop_lat,stop_lon,wheelchair_boarding\na,A,49.6,6.1,1\nb,B,49.61,6.1,0\nd,D,49.63,6.1,1\n"
        files["trips.txt"] = "route_id,service_id,trip_id,wheelchair_accessible\nbus,service,in,1\nother,service,out,\(vehicle)\n"
        files["transfers.txt"] = "from_trip_id,to_trip_id,transfer_type\nin,out,4\n"
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        #expect(try await fixture.profile(fixture.query(preferences: .init(maxTransfers: 0, wheelchair: .required))).journeys.isEmpty == (vehicle != 1))
    }

    @Test func walkingBudgetRemainsHardDuringPublication() async throws {
        let files = preventionFiles(trips: "bus,service,ride,,,,\n", times: "ride,08:05:00,08:05:00,a,1\nride,08:20:00,08:20:00,d,2\n")
        let origin = Coordinate(latitude: 49.5999, longitude: 6.1)
        let fixture = try await RoutingPreventionFixture(files: files, walking: PreventionWalking(edges: [.init(from: origin, to: .init(latitude: 49.6, longitude: 6.1), seconds: 60)])); defer { fixture.remove() }
        #expect(try await fixture.profile(fixture.query(preferences: .init(maximumWalkingSeconds: 59), origin: .coordinate(origin, label: nil))).journeys.isEmpty)
        #expect(try await fixture.profile(fixture.query(preferences: .init(maximumWalkingSeconds: 60), origin: .coordinate(origin, label: nil))).journeys.count == 1)
    }

    // 37: separate alternatives never compose overlapping rides into one route.
    @Test func simultaneousVehiclesAndDisconnectedLegsCannotPublish() throws {
        let journey = try preventionJourney(id: "one", arrival: 1200)
        let overlapping = try preventionJourney(id: "two", departure: 600, arrival: 1800, firstTrip: "two")
        let combined = journey.replacing(legs: journey.legs + overlapping.legs)
        let query = RouteQuery(origin: journey.origin, destination: journey.destination, departureTime: date(hour: 8))
        #expect(JourneyPublicationValidator.assess(combined, query: query) == .invalid(.overlappingLegs))
        let disconnected = try preventionJourney(id: "two", departure: 1500, arrival: 1800, firstTrip: "two")
        #expect(JourneyPublicationValidator.assess(journey.replacing(legs: journey.legs + disconnected.legs), query: query) == .invalid(.disconnectedLegs))
    }

    @Test func exactFrequencyInstancesDoNotPublishTemplatePhantom() async throws {
        var files = preventionFiles(trips: "bus,service,ride,,,,\n", times: "ride,08:00:00,08:00:00,a,1\nride,08:20:00,08:20:00,d,2\n")
        files["frequencies.txt"] = "trip_id,start_time,end_time,headway_secs,exact_times\nride,08:05:00,08:25:00,600,1\n"
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        let page = try await fixture.profile()
        #expect(page.journeys.count == 2)
        #expect(page.journeys.allSatisfy { $0.firstRide?.tripID.contains("#frequency-") == true })
    }
}
