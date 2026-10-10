import Foundation
import Testing
@testable import MobiliteitKit

@Suite("GTFS vehicle block continuations")
struct BlockContinuationTests {
    private func files(extraTrips: String = "", extraTimes: String = "") -> [String: String] {
        var files = preventionFiles(trips: "bus,service,seven,Poutty Stein,,,vehicle\nother,service,twentyfive,Dommeldange,,,vehicle\n" + extraTrips,
            times: "seven,20:33:20,20:33:20,a,1\nseven,20:34:40,20:34:40,b,2\ntwentyfive,20:35:10,20:35:10,b,1\ntwentyfive,20:39:00,20:39:00,d,2\n" + extraTimes)
        files["routes.txt"] = "route_id,agency_id,route_short_name,route_long_name,route_type\nbus,operator,7,Seven,3\nother,operator,25,Twenty five,3\n"
        return files
    }

    @Test(arguments: [false, true])
    func luxexpoSevenContinuesAsTwentyFive(arriveBy: Bool) async throws {
        var files = files()
        files["transfers.txt"] = "from_stop_id,to_stop_id,transfer_type,min_transfer_time\nb,b,2,450\n"
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        let query = fixture.query(preferences: .init(maxTransfers: 0),
            anchor: date(hour: arriveBy ? 21 : 20), direction: arriveBy ? .arriveBy : .departAfter)
        let result = try await fixture.profile(query)
        let journey = try #require(result.journeys.first)
        #expect(transitTripInstanceSequence(journey) == ["seven", "twentyfive"])
        #expect(journey.transferCount == 0)
        #expect(journey.legs.contains { if case .inSeatContinuation = $0 { true } else { false } })
    }

    @Test(arguments: [3, 5])
    func explicitRestrictionOverridesBlock(type: Int) async throws {
        var files = files()
        files["transfers.txt"] = "from_stop_id,to_stop_id,from_trip_id,to_trip_id,transfer_type\nb,b,seven,twentyfive,\(type)\n"
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        #expect(try await fixture.profile(fixture.query(preferences: .init(maxTransfers: 0), anchor: date(hour: 20))).journeys.isEmpty)
    }

    @Test(arguments: ["missing", "differentStop", "overlap", "ambiguous", "intervening", "inactive"])
    func invalidBlockCannotInventContinuation(scenario: String) async throws {
        var files = files()
        switch scenario {
        case "missing": files["trips.txt"] = files["trips.txt"]!.replacingOccurrences(of: ",,,vehicle", with: ",,,")
        case "differentStop": files["stop_times.txt"] = files["stop_times.txt"]!.replacingOccurrences(of: "20:35:10,b,1", with: "20:35:10,c,1")
        case "overlap": files = self.files(extraTrips: "bus,service,third,,,,vehicle\n", extraTimes: "third,20:34:00,20:34:00,c,1\nthird,20:36:00,20:36:00,b,2\n")
        case "ambiguous": files = self.files(extraTrips: "bus,service,third,,,,vehicle\n", extraTimes: "third,20:35:10,20:35:10,b,1\nthird,20:36:00,20:36:00,c,2\n")
        case "intervening": files = self.files(extraTrips: "bus,service,third,,,,vehicle\n", extraTimes: "third,20:34:45,20:34:45,c,1\nthird,20:35:00,20:35:00,b,2\n")
        default: files["trips.txt"] = files["trips.txt"]!.replacingOccurrences(of: "other,service,twentyfive", with: "other,inactive,twentyfive")
            files["calendar_dates.txt"]! += "inactive,20260905,1\n"
        }
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        #expect(try await fixture.profile(fixture.query(preferences: .init(maxTransfers: 0), anchor: date(hour: 20))).journeys.isEmpty)
    }
}
