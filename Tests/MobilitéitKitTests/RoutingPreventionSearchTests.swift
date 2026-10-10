import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Routing prevention: identity, validity and continuations")
struct RoutingPreventionSearchTests {
    // 11–13: minima remain strict, including deprecated shortfall and fractional time.
    @Test(arguments: [119.0, 119.999, 120.0, 120.001, 121.0])
    func strictMinimumBoundary(gap: Double) {
        let start = date(hour: 8)
        let incoming = JourneyTimingLeg(kind: .transit, departure: start, arrival: start.addingTimeInterval(600), destinationStopID: "b")
        let outgoing = JourneyTimingLeg(kind: .transit, departure: start.addingTimeInterval(600 + gap), arrival: start.addingTimeInterval(1800), originStopID: "b")
        let context = JourneyValidationContext(anchor: start, arriveBy: false, minimumTransferSeconds: 120, sameStopTransferShortfallSeconds: 180)
        #expect(JourneyItineraryValidator.assess([incoming, outgoing], context: context).isInvalid == (gap < 120))
    }

    @Test func transferMinimumIncludesWalkingAndRefinementRecalculatesResidual() {
        #expect(JourneyTransferArithmetic.requiredAfterWalking(totalMinimum: 120, walkingSeconds: 90) == 30)
        #expect(JourneyTransferArithmetic.requiredAfterWalking(totalMinimum: 120, walkingSeconds: 150) == 0)
        #expect(JourneyTransferArithmetic.requiredAfterWalking(totalMinimum: 120, walkingSeconds: 150, boardingBufferSeconds: 30) == 30)
        #expect(JourneyTransferArithmetic.requiredAfterWalking(totalMinimum: 120, walkingSeconds: 90.1) == 30)
    }

    // 39–40: a child-specific forbidden rule cannot leak into another platform.
    @Test(arguments: ["b1", "b2", "station"])
    func exactPlatformTransferScope(ruleEndpoint: String) async throws {
        var files = preventionFiles(trips: "bus,service,in,,,,\nother,service,out,,,,\n",
            times: "in,08:00:00,08:00:00,a,1\nin,08:10:00,08:10:00,b2,2\nout,08:12:00,08:12:00,b2,1\nout,08:20:00,08:20:00,d,2\n")
        files["stops.txt"] = "stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station\na,A,49.6,6.1,0,\nd,D,49.63,6.1,0,\nstation,Station,49.61,6.1,1,\nb1,Platform 1,49.61,6.1,0,station\nb2,Platform 2,49.6101,6.1,0,station\n"
        files["transfers.txt"] = "from_stop_id,to_stop_id,transfer_type\n\(ruleEndpoint),\(ruleEndpoint),3\n"
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        let result = try await fixture.profile()
        #expect(result.journeys.isEmpty == (ruleEndpoint != "b1"))
    }

    // 22–23: explicit linked trips, independent of line labels and blocks.
    @Test(arguments: [4, 5, 0])
    func verifiedContinuationUsesZeroTransfers(type: Int) async throws {
        var files = preventionFiles(trips: "bus,service,in,First,,,same\nother,service,out,Second,,,same\n",
            times: "in,08:00:00,08:00:00,a,1\nin,08:10:00,08:10:00,b,2\nout,08:10:00,08:10:00,b,1\nout,08:20:00,08:20:00,d,2\n")
        if type != 0 { files["transfers.txt"] = "from_trip_id,to_trip_id,transfer_type\nin,out,\(type)\n" }
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        let result = try await fixture.profile(fixture.query(preferences: .init(maxTransfers: 0)))
        #expect(result.journeys.isEmpty == (type == 5))
        if type != 5 {
            let ride = try #require(result.journeys.first)
            #expect(ride.transferCount == 0)
            #expect(ride.summary.transferGaps.isEmpty)
            #expect(ride.legs.contains { if case .inSeatContinuation = $0 { true } else { false } })
            #expect(transitTripInstanceSequence(ride) == ["in", "out"])
            #expect(!JourneyPublicationValidator.assess(ride, query: fixture.query(preferences: .init(maxTransfers: 0))).isInvalid)
        }
    }

    @Test func conflictingTypeFiveOverridesSameScopeContinuation() async throws {
        var files = preventionFiles(trips: "bus,service,in,,,,\nother,service,out,,,,\n",
            times: "in,08:00:00,08:00:00,a,1\nin,08:10:00,08:10:00,b,2\nout,08:10:00,08:10:00,b,1\nout,08:20:00,08:20:00,d,2\n")
        files["transfers.txt"] = "from_trip_id,to_trip_id,transfer_type\nin,out,4\nin,out,5\n"
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        #expect(try await fixture.profile().journeys.isEmpty)
    }

    @Test func cancelledContinuationNeverPublishesEitherEnd() async throws {
        var files = preventionFiles(trips: "bus,service,in,,,,\nother,service,out,,,,\n",
            times: "in,08:00:00,08:00:00,a,1\nin,08:10:00,08:10:00,b,2\nout,08:10:00,08:10:00,b,1\nout,08:20:00,08:20:00,d,2\n")
        files["transfers.txt"] = "from_trip_id,to_trip_id,transfer_type\nin,out,4\n"
        let day = try GTFSDate(parsing: "20260904")
        for cancelled in ["in", "out"] {
            let fixture = try await RoutingPreventionFixture(files: files, realtime: PreventionRealtime(patches: [.init(tripID: cancelled, serviceDate: day, status: .cancelled, events: [])]))
            defer { fixture.remove() }
            #expect(try await fixture.profile(fixture.query(preferences: .init(maxTransfers: 0), live: true)).journeys.isEmpty)
        }
    }

    // 01, 04–05, 24–26: one legitimate circular ride, distinct repeated occurrences.
    @Test func circularRideRetainsBoardingOccurrenceAndHeadsign() async throws {
        var files = preventionFiles(trips: "bus,service,loop,Trip terminus,,1,\n",
            times: "loop,08:00:00,08:00:00,a,1\nloop,08:05:00,08:05:00,b,2\nloop,08:10:00,08:10:00,a,3\nloop,08:15:00,08:15:00,d,4\n")
        files["stop_times.txt"] = files["stop_times.txt"]!.replacingOccurrences(of: "stop_sequence\n", with: "stop_sequence,stop_headsign\n").replacingOccurrences(of: "a,3\n", with: "a,3,Boarding terminus\n")
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        let query = fixture.query(anchor: date(hour: 8, minute: 6))
        let result = try await fixture.profile(query)
        let ride = try #require(result.journeys.first?.firstRide)
        #expect(ride.boardSequence == 3 && ride.alightSequence == 4)
        #expect(ride.headsign == "Boarding terminus")
        #expect(ride.instance?.serviceDate.compactString == "20260904")
        #expect(result.journeys.allSatisfy { journey in
            let keys = journey.legs.compactMap { if case let .transit(t) = $0 { t.instance } else { nil } }
            return Set(keys).count == keys.count
        })
        #expect(try await fixture.profile(fixture.query(origin: .stop(id: "d"), destination: .stop(id: "a"))).journeys.isEmpty)
    }

    @Test func scannerNeverReboardsUsedInstanceButAllowsAnotherVehicleOnSameLine() async throws {
        let files = preventionFiles(trips: "bus,service,first,,,,\nbus,service,shuttle,,,,\nbus,service,second,,,,\n",
            times: "first,08:00:00,08:00:00,a,1\nfirst,08:10:00,08:10:00,b,2\nfirst,08:16:00,08:16:00,c,3\nfirst,08:20:00,08:20:00,d,4\nshuttle,08:12:00,08:12:00,b,1\nshuttle,08:14:00,08:14:00,c,2\nsecond,08:16:00,08:16:00,c,1\nsecond,08:20:00,08:20:00,d,2\n")
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        let snapshot = await fixture.router.snapshot
        let result = try await Raptor.search(snapshot: snapshot, query: fixture.query(),
            access: [.init(stop: snapshot.stopByID["a"]!, seconds: 0, distance: 0, walk: nil)],
            egress: [.init(stop: snapshot.stopByID["d"]!, seconds: 0, distance: 0, walk: nil)],
            patches: [], walking: nil, profileHorizon: 3600)
        #expect(result.candidates.allSatisfy { candidate in
            let keys = candidate.transitLegs.map { Raptor.TripInstance(trip: $0.trip, day: $0.day) }
            return Set(keys).count == keys.count
        })
        #expect(result.candidates.contains { $0.transitLegs.count > 1 && snapshot.trips[$0.transitLegs.last!.trip].id == "second" })
    }

    // 41–43: overflow is attached to the earlier service date; a linked run can change service day.
    @Test func linkedMidnightUsesCorrectServiceDates() async throws {
        var files = preventionFiles(trips: "bus,previous,in,,,,\nother,next,out,,,,\n",
            times: "in,24:50:00,24:50:00,a,1\nin,25:00:00,25:00:00,b,2\nout,01:00:00,01:00:00,b,1\nout,01:10:00,01:10:00,d,2\n")
        files["calendar_dates.txt"] = "service_id,date,exception_type\nprevious,20260904,1\nnext,20260905,1\n"
        files["transfers.txt"] = "from_trip_id,to_trip_id,transfer_type\nin,out,4\n"
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        let anchor = date(hour: 0).addingTimeInterval(24 * 3600 + 45 * 60)
        let page = try await fixture.profile(fixture.query(preferences: .init(maxTransfers: 0), anchor: anchor))
        let journey = try #require(page.journeys.first)
        let dates = journey.legs.compactMap { if case let .transit(t) = $0 { t.instance?.serviceDate.compactString } else { nil } }
        #expect(dates == ["20260904", "20260905"])
        #expect(journey.effectiveArrival > journey.effectiveDeparture)
        #expect(try await fixture.profile(fixture.query(anchor: anchor.addingTimeInterval(86400))).journeys.isEmpty)
    }

    @Test func removedCalendarDayCannotBeActivatedByLiveEvidence() async throws {
        var files = preventionFiles(trips: "bus,service,ride,,,,\n", times: "ride,08:05:00,08:05:00,a,1\nride,08:20:00,08:20:00,d,2\n")
        files["calendar.txt"] = "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nservice,1,1,1,1,1,0,0,20260904,20260905\n"
        files["calendar_dates.txt"] = "service_id,date,exception_type\nservice,20260904,2\nservice,20260905,1\n"
        let patch = RealtimeTripPatch(tripID: "ride", serviceDate: try GTFSDate(parsing: "20260904"), events: [.init(stopID: "a", effectiveDeparture: date(hour: 8, minute: 10), departureSource: .reported, stopSequence: 1, observedAt: date(hour: 8))])
        let fixture = try await RoutingPreventionFixture(files: files, realtime: PreventionRealtime(patches: [patch]), now: date(hour: 8)); defer { fixture.remove() }
        #expect(try await fixture.profile(fixture.query(live: true)).journeys.isEmpty)
        #expect(try await fixture.profile(fixture.query(anchor: date(hour: 8).addingTimeInterval(86400))).journeys.count == 1)
    }

    @Test(arguments: ["20260329", "20261025"]) func daylightSavingServiceInstantsRemainChronological(serviceDate: String) throws {
        let converter = ServiceInstantConverter(timeZone: TimeZone(identifier: "Europe/Luxembourg")!)
        let day = try GTFSDate(parsing: serviceDate)
        let first = converter.date(serviceDate: day, serviceSeconds: 2 * 3600)
        let second = converter.date(serviceDate: day, serviceSeconds: 3 * 3600)
        let overflow = converter.date(serviceDate: day, serviceSeconds: 25 * 3600)
        #expect(second.timeIntervalSince(first) == 3600)
        #expect(overflow.timeIntervalSince(first) == 23 * 3600)
    }

    // 45, 47: permission is a hard rule, even when the line goes to the destination.
    @Test(arguments: ["pickup_type", "drop_off_type"])
    func forbiddenPickupOrDropoff(column: String) async throws {
        var files = preventionFiles(trips: "bus,service,ride,,,,\n", times: "ride,08:05:00,08:05:00,a,1\nride,08:20:00,08:20:00,d,2\n")
        files["stop_times.txt"] = files["stop_times.txt"]!.replacingOccurrences(of: "stop_sequence\n", with: "stop_sequence,\(column)\n").replacingOccurrences(of: column == "pickup_type" ? "a,1\n" : "d,2\n", with: column == "pickup_type" ? "a,1,1\n" : "d,2,1\n")
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        #expect(try await fixture.profile().journeys.isEmpty)
    }

    @Test func invalidFeedUpdateKeepsInstalledGeneration() async throws {
        let valid = preventionFiles(trips: "bus,service,ride,,,,\n", times: "ride,08:00:00,08:00:00,a,1\nride,08:20:00,08:20:00,d,2\n")
        let fixture = try await RoutingPreventionFixture(files: valid); defer { fixture.remove() }
        for invalidTimes in ["ride,08:00:00,08:00:00,a,1\nride,07:59:00,07:59:00,d,2\n", "ride,08:00:00,07:59:00,a,1\nride,08:20:00,08:20:00,d,2\n"] {
            var bad = valid; bad["stop_times.txt"] = "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n" + invalidTimes
            let archive = fixture.directory.appendingPathComponent(UUID().uuidString + ".zip")
            try writeArchive(to: archive, files: bad)
            await #expect(throws: GTFSArchiveError.self) { try await GTFSArchiveInstaller.install(archiveAt: archive, databaseAt: fixture.database, generation: 8) }
            #expect(try await GTFSStore(databaseAt: fixture.database).feedInfo().generation == 7)
        }
    }
}
