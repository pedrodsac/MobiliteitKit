import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Same-stop bus changes below aggregate feed buffers")
struct TightSameStopBusTransferTests {
    @Test(arguments: [119, 120, 155, 449, 450])
    func shortChangeRequiresRiderMinimumWithoutMislabelingFeedBuffer(gap: Int) async throws {
        let fixture = try await makeFixture(gap: gap)
        defer { fixture.remove() }
        let preferences = RoutingPreferences(preferredMode: nil, avoidTightTransfers: false)
        let query = fixture.query(preferences: preferences)
        let page = try await fixture.profile(query)
        let short = page.journeys.first { $0.legs.contains { if case let .transit(ride) = $0 { ride.tripID == "short" } else { false } } }
        #expect((short != nil) == (gap >= 120))
        if let short {
            #expect(!JourneyPublicationValidator.assess(short, query: query).isInvalid)
            let last = try #require(short.legs.compactMap { if case let .transit(ride) = $0 { ride } else { nil } }.last)
            #expect(last.requiredTotalTransferSeconds == 120)
            #expect(last.recommendedTotalTransferSeconds == 450)
            #expect(!short.statusEvidence.tightTransfer)
            let risks = JourneyItineraryValidator.transferRisks(short,
                context: .init(anchor: query.departureTime, arriveBy: false, minimumTransferSeconds: 120))
            #expect(!risks.values.contains(.tight))
        }
        for strict in [RoutingPreferences()] {
            let strictPage = try await fixture.profile(fixture.query(preferences: strict))
            #expect(strictPage.journeys.contains { $0.legs.contains { if case let .transit(ride) = $0 { ride.tripID == "short" } else { false } } } == (gap >= 450))
        }
    }

    @Test(arguments: ["route", "trip", "forbidden", "train", "platform", "wheelchair"])
    func specificRulesAndPlatformOrRailChangesRemainStrict(scenario: String) async throws {
        let fixture = try await makeFixture(gap: 155, scenario: scenario)
        defer { fixture.remove() }
        var preferences = RoutingPreferences(preferredMode: nil, avoidTightTransfers: false)
        if scenario == "wheelchair" { preferences.wheelchair = .required }
        let page = try await fixture.profile(fixture.query(preferences: preferences))
        #expect(!page.journeys.contains { $0.legs.contains { if case let .transit(ride) = $0 { ride.tripID == "short" } else { false } } })
    }

    @Test func riskUpdatesWithLiveArrivalAndMissedConnectionsStayInvalid() async throws {
        let fixture = try await makeFixture(gap: 155)
        defer { fixture.remove() }
        let query = fixture.query(preferences: .init(preferredMode: nil, avoidTightTransfers: false))
        let journey = try #require(try await fixture.profile(query).journeys.first {
            $0.legs.contains { if case let .transit(ride) = $0 { ride.tripID == "short" } else { false } }
        })
        let incoming = try #require(journey.firstRide)
        let instance = try #require(incoming.instance)
        func revised(delay: Int) throws -> Journey {
            let patch = RealtimeTripPatch(tripID: incoming.tripID, serviceDate: instance.serviceDate,
                events: [.init(stopID: "b", effectiveArrival: incoming.effectiveArrival.addingTimeInterval(Double(delay)),
                    arrivalSource: .reported, stopSequence: incoming.alightSequence)])
            return try #require(journey.applyingRealtime([.init(tripID: incoming.tripID, serviceDate: instance.serviceDate): patch]))
        }
        let delayed = try revised(delay: 20)
        #expect(!delayed.statusEvidence.tightTransfer)
        #expect(!JourneyPublicationValidator.assess(delayed, query: query).isInvalid)
        #expect(JourneyPublicationValidator.assess(try revised(delay: 36), query: query).isInvalid)
        let early = try revised(delay: -300)
        #expect(!early.statusEvidence.tightTransfer)
    }

    @Test func riderConvenienceAndLegacyDecodingPreserveExplicitPolicy() throws {
        #expect(RoutingPreferences(preferredMode: nil, avoidTightTransfers: false).allowTightSameStopBusTransfers)
        #expect(RoutingPreferences(preferredMode: nil, avoidTightTransfers: true).allowTightSameStopBusTransfers)
        #expect(RoutingPreferences(preferredMode: nil, avoidTightTransfers: true).minimumTransferSeconds == 120)
        #expect(try !JSONDecoder().decode(RoutingPreferences.self, from: Data("{}".utf8)).allowTightSameStopBusTransfers)
        let preferences = RoutingPreferences(preferredMode: nil, avoidTightTransfers: false)
        #expect(try JSONDecoder().decode(RoutingPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
    }

    @Test func arrivalDeadlineAndLargerRiderBufferRemainHardConstraints() async throws {
        let fixture = try await makeFixture(gap: 155)
        defer { fixture.remove() }
        for avoidTight in [false, true] {
            let query = fixture.query(preferences: .init(preferredMode: nil, avoidTightTransfers: avoidTight),
                anchor: date(hour: 8, minute: 26), direction: .arriveBy)
            let page = try await fixture.profile(query)
            #expect(!page.journeys.isEmpty)
            #expect(page.journeys.allSatisfy { $0.effectiveArrival <= query.departureTime })
        }
        var buffered = RoutingPreferences(preferredMode: nil, avoidTightTransfers: false)
        buffered.boardingBufferSeconds = 180
        let page = try await fixture.profile(fixture.query(preferences: buffered))
        #expect(page.journeys.allSatisfy { !$0.statusEvidence.tightTransfer })
    }

    @Test(arguments: [119, 120, 155, 449, 450])
    func tightRiskUsesOnlyTwoMinuteBoundary(gap: Int) async throws {
        let fixture = try await makeFixture(gap: max(120, gap))
        defer { fixture.remove() }
        let query = fixture.query(preferences: .init(preferredMode: nil, avoidTightTransfers: false))
        let journey = try #require(try await fixture.profile(query).journeys.first {
            $0.legs.contains { if case let .transit(ride) = $0 { ride.tripID == "short" } else { false } }
        })
        let incoming = try #require(journey.firstRide)
        var legs = journey.legs
        let index = try #require(legs.lastIndex { if case let .transit(ride) = $0 { ride.tripID == "short" } else { false } })
        guard case var .transit(outgoing) = legs[index] else { return }
        outgoing = TransitLeg(tripID: outgoing.tripID, route: outgoing.route, headsign: outgoing.headsign,
            board: outgoing.board, alight: outgoing.alight, intermediateStops: outgoing.intermediateStops,
            scheduledDeparture: outgoing.scheduledDeparture, scheduledArrival: outgoing.scheduledArrival,
            effectiveDeparture: incoming.effectiveArrival.addingTimeInterval(Double(gap)),
            effectiveArrival: outgoing.effectiveArrival, status: outgoing.status,
            requiredTransferSecondsAfterWalking: 0, recommendedTotalTransferSeconds: 450)
        legs[index] = .transit(outgoing)
        let revised = journey.replacing(legs: legs)
        let risks = JourneyItineraryValidator.transferRisks(revised,
            context: .init(anchor: query.departureTime, arriveBy: false, minimumTransferSeconds: 0))
        #expect(risks.values.contains(.tight) == (gap < 120))
        #expect(revised.statusEvidence.tightTransfer == (gap < 120))
    }

    private func makeFixture(gap: Int, scenario: String = "aggregate") async throws -> RoutingPreventionFixture {
        let total = 8 * 3_600 + 10 * 60 + gap
        let departure = String(format: "%02d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
        var files = preventionFiles(trips: "bus,service,in,,,,\nother,service,short,,,,\nother,service,later,,,,\n",
            times: "in,08:05:00,08:05:00,a,1\nin,08:10:00,08:10:00,b,2\nshort,\(departure),\(departure),b,1\nshort,08:25:00,08:25:00,d,2\nlater,08:30:00,08:30:00,b,1\nlater,08:40:00,08:40:00,d,2\n")
        files["transfers.txt"] = switch scenario {
        case "route": "from_stop_id,to_stop_id,transfer_type,min_transfer_time,from_route_id,to_route_id\nb,b,2,450,bus,other\n"
        case "trip": "from_stop_id,to_stop_id,transfer_type,min_transfer_time,from_trip_id,to_trip_id\nb,b,2,450,in,short\n"
        case "forbidden": "from_stop_id,to_stop_id,transfer_type\nb,b,3\n"
        default: "from_stop_id,to_stop_id,transfer_type,min_transfer_time\nb,b,2,450\n"
        }
        if scenario == "train" { files["routes.txt"] = "route_id,agency_id,route_short_name,route_long_name,route_type\nbus,operator,322,Bus,3\nother,operator,Train,Train,2\n" }
        if scenario == "platform" {
            files["stops.txt"] = "stop_id,stop_name,stop_lat,stop_lon,platform_code\na,A,49.6,6.1,\nb,B,49.61,6.1,2C\nd,D,49.63,6.1,\n"
        }
        if scenario == "wheelchair" {
            files["stops.txt"] = "stop_id,stop_name,stop_lat,stop_lon,wheelchair_boarding\na,A,49.6,6.1,1\nb,B,49.61,6.1,1\nd,D,49.63,6.1,1\n"
            files["trips.txt"] = "route_id,service_id,trip_id,wheelchair_accessible\nbus,service,in,1\nother,service,short,1\nother,service,later,1\n"
        }
        return try await RoutingPreventionFixture(files: files)
    }

    @Test func twoMinuteChangeIsNotTightEvenBelowFeedRecommendation() async throws {
        var files = preventionFiles(trips: "bus,service,in,,,,\nother,service,short,,,,\nbus,service,direct,,,,\n",
            times: "in,08:05:00,08:05:00,a,1\nin,08:10:00,08:10:00,b,2\nshort,08:12:35,08:12:35,b,1\nshort,08:25:00,08:25:00,d,2\ndirect,08:05:00,08:05:00,a,1\ndirect,08:40:00,08:40:00,d,2\n")
        files["transfers.txt"] = "from_stop_id,to_stop_id,transfer_type,min_transfer_time\nb,b,2,450\n"
        let fixture = try await RoutingPreventionFixture(files: files)
        defer { fixture.remove() }
        let preferences = RoutingPreferences(preferredMode: nil, avoidTightTransfers: false)
        let session = try await fixture.planning(.init(origin: .stop(id: "a"), destination: .stop(id: "d"),
            time: .departAt(date(hour: 8)), preferences: preferences))
        let result = try await session.calculate(refresh: .scheduleOnly)
        #expect(result.journeys.contains { $0.firstRide?.tripID == "in" })
        #expect(result.journeys.allSatisfy { !$0.statusEvidence.tightTransfer })
    }
}
