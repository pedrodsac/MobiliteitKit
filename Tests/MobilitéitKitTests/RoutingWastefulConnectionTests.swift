import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Avoid wasteful connections when the same downstream vehicle is reachable")
struct RoutingWastefulConnectionTests {
    private let origin = Coordinate(latitude: 49.5999, longitude: 6.1)
    private let a = Coordinate(latitude: 49.6, longitude: 6.1)
    private let b = Coordinate(latitude: 49.6005, longitude: 6.1)
    private let c = Coordinate(latitude: 49.601, longitude: 6.1)

    private func files(firstArrival: String = "08:46:45") -> [String: String] {
        scenarioFiles(routes: "bus,operator,326,Bus,3\nother,operator,311,Other,3\nlast,operator,18,Last,3\n",
            stops: scenarioStops([("a", "Gromscheed", 49.6), ("b", "Rue du Golf", 49.6005),
                                 ("c", "Laangschib", 49.601), ("x", "Luxexpo", 49.61), ("d", "Konrad Adenauer", 49.63)]),
            trips: "bus,service,326,,,,\nother,service,311,,,,\nlast,service,18,,,,\n",
            stopTimes: "326,08:37:25,08:37:25,a,1\n326,08:39:15,08:39:15,b,2\n326,\(firstArrival),\(firstArrival),x,3\n311,08:42:00,08:42:00,c,1\n311,08:47:00,08:47:00,x,2\n18,08:55:00,08:55:00,x,1\n18,08:59:00,08:59:00,d,2\n")
    }

    @Test(arguments: ["08:46:45", "08:58:00"])
    func stayOn326Unless311IsNeededToCatch18(firstArrival: String) async throws {
        let fixture = try await RoutingPreventionFixture(files: files(firstArrival: firstArrival),
            walking: PreventionWalking(edges: [.init(from: b, to: c, seconds: 120)]))
        defer { fixture.remove() }
        let page = try await fixture.profile()
        let beforeNine = page.journeys.filter { $0.effectiveArrival <= date(hour: 9) }
        #expect(!beforeNine.isEmpty)
        #expect(beforeNine.allSatisfy { transitTripInstanceSequence($0) ==
            (firstArrival == "08:46:45" ? ["326", "18"] : ["326", "311", "18"]) })
    }

    @Test func stayOn322ToCatchTheSameTramDespiteLongerInterchangeWalk() async throws {
        let fixture = try await luxexpoFixture()
        defer { fixture.remove() }
        let query = fixture.query(anchor: date(hour: 10, minute: 58))
        let page = try await fixture.profile(query)
        #expect(!page.journeys.isEmpty)
        #expect(page.journeys.allSatisfy { transitTripInstanceSequence($0) == ["322", "T1"] })
        let session = try await fixture.planning(.init(origin: query.origin, destination: query.destination,
            time: .departAt(query.departureTime)))
        for result in [try await session.calculate(refresh: .scheduleOnly),
                       try await session.calculate(page: .later, refresh: .scheduleOnly),
                       try await session.refreshRealtime(now: query.departureTime)] {
            #expect(!result.journeys.isEmpty)
            #expect(result.journeys.allSatisfy { transitTripInstanceSequence($0) == ["322", "T1"] })
        }
    }

    @Test(arguments: [0, 300, 540, 541, 660], ["11:23:00", "11:40:00"])
    func preserveUseful325AndInterchangeWalkingBoundary(interchangeSeconds: Int, firstArrival: String) async throws {
        let fixture = try await luxexpoFixture(interchangeSeconds: interchangeSeconds, firstArrival: firstArrival,
            tramDeparture: "11:40:00", tramArrival: "11:48:00")
        defer { fixture.remove() }
        let query = fixture.query(anchor: date(hour: 10, minute: 58))
        let page = try await fixture.profile(query)
        let detour = page.journeys.first { transitTripInstanceSequence($0) == ["322", "325", "T1"] }
        #expect(!page.journeys.isEmpty)
        #expect((detour != nil) == (interchangeSeconds == 0 || firstArrival == "11:40:00" || interchangeSeconds > 540))
        let lessWalking = try await fixture.profile(fixture.query(preferences: .init(routePreference: .lessWalking), anchor: query.departureTime))
        #expect(lessWalking.journeys.contains { transitTripInstanceSequence($0) == ["322", "325", "T1"] })
        let budget = try await fixture.profile(fixture.query(preferences: .init(maximumWalkingSeconds: 240), anchor: query.departureTime))
        #expect(!budget.journeys.isEmpty)
        #expect(budget.journeys.allSatisfy { transitTripInstanceSequence($0) == ["322", "325", "T1"] })
        let arriveBy = try await fixture.profile(fixture.query(anchor: date(hour: 11, minute: 48), direction: .arriveBy))
        #expect(arriveBy.journeys.map(\.id) == page.journeys.map(\.id))
    }

    @Test func longerRefinedLuxexpoWalkRestoresNecessary325() async throws {
        let fixture = try await luxexpoFixture()
        defer { fixture.remove() }
        let session = try await fixture.planning(.init(origin: .stop(id: "a"), destination: .stop(id: "d"),
            time: .departAt(date(hour: 10, minute: 58))))
        let initial = try await session.calculate(refresh: .scheduleOnly)
        let stay = try #require(initial.journeys.first { transitTripInstanceSequence($0) == ["322", "T1"] })
        let index = try #require(stay.legs.firstIndex { if case .walk = $0 { true } else { false } })
        guard case let .walk(walk) = stay.legs[index] else { return }
        let corrected = try await session.submitWalkingRefinement(.init(
            token: try #require(initial.refinementTokens[stay.id]), range: index..<(index + 1),
            route: .init(durationSeconds: 420, distanceMeters: 200, polyline: [walk.from.coordinate, walk.to.coordinate]),
            departure: walk.departure, arrival: walk.departure.addingTimeInterval(420)))
        #expect(corrected.invalidatedIDs.contains(stay.id))
        #expect(corrected.journeys.contains { transitTripInstanceSequence($0) == ["322", "325", "T1"] })
    }

    @Test func intermediateTransferRequiresInstanceAndOccurrenceEvidence() async throws {
        let fixture = try await luxexpoFixture()
        defer { fixture.remove() }
        let page = try await fixture.profile(fixture.query(preferences: .init(routePreference: .lessWalking)))
        let detour = try #require(page.journeys.first { transitTripInstanceSequence($0) == ["322", "325", "T1"] })
        let stay = try #require(page.journeys.first { transitTripInstanceSequence($0) == ["322", "T1"] })
        #expect(JourneyQualityPolicy.redundantIntermediateTransfer(detour, replacedBy: stay, preferences: .init()))
        for change in 0..<7 {
            var legs = stay.legs
            let indexes = legs.indices.filter { if case .transit = legs[$0] { true } else { false } }
            let index = change < 3 ? indexes[0] : indexes[1]
            guard case var .transit(ride) = legs[index] else { return }
            switch change {
            case 0: ride.boardSequence = nil
            case 1: ride.alightSequence = 2 // No longer extends the first ride.
            case 2: ride.instance = nil
            case 3: ride.instance = .init(feedGeneration: 8, tripID: ride.tripID, serviceDate: try GTFSDate(parsing: "20260904"))
            case 4: ride.instance = .init(feedGeneration: 7, tripID: ride.tripID, serviceDate: try GTFSDate(parsing: "20260905"))
            case 5: ride.alightSequence = 3
            default: ride.boardSequence = nil
            }
            legs[index] = .transit(ride)
            #expect(!JourneyQualityPolicy.redundantIntermediateTransfer(detour, replacedBy: replacingLegs(stay, with: legs), preferences: .init()))
        }
    }

    private func luxexpoFixture(interchangeSeconds: Int = 300, firstArrival: String = "11:23:00",
                                tramDeparture: String = "11:29:00", tramArrival: String = "11:37:00") async throws -> RoutingPreventionFixture {
        let files = scenarioFiles(routes: "bus,operator,322,Bus,3\nother,operator,325,Other,3\nlast,operator,T1,Tram,0\n",
            stops: scenarioStops([("a", "Gromscheed", 49.6), ("b", "Rue du Golf", 49.6005),
                                 ("c", "Laangschib", 49.601), ("x", "Gare routière Luxexpo", 49.61),
                                 ("h", "Hugo Gernsback", 49.6105), ("t", "Luxexpo Tram", 49.611),
                                 ("d", "Philharmonie / Mudam", 49.63)]),
            trips: "bus,service,322,,,,\nother,service,325,,,,\nlast,service,T1,,,,\n",
            stopTimes: "322,11:17:00,11:17:00,a,1\n322,11:19:00,11:19:00,b,2\n322,\(firstArrival),\(firstArrival),x,3\n325,11:22:00,11:22:00,c,1\n325,11:26:00,11:26:00,h,2\nT1,\(tramDeparture),\(tramDeparture),t,1\nT1,\(tramArrival),\(tramArrival),d,2\n")
        var edges = [PreventionWalking.Edge(
            from: b, to: c, seconds: 120),
            .init(from: .init(latitude: 49.6105, longitude: 6.1), to: .init(latitude: 49.611, longitude: 6.1), seconds: 120),
        ]
        if interchangeSeconds > 0 {
            edges.append(.init(from: .init(latitude: 49.61, longitude: 6.1),
                to: .init(latitude: 49.611, longitude: 6.1), seconds: interchangeSeconds))
        }
        return try await RoutingPreventionFixture(files: files, walking: PreventionWalking(edges: edges))
    }

    @Test(arguments: [0, 540, 660, 720, 900])
    func walkTo850WhenItLeavesHomeLater(walkingSeconds: Int) async throws {
        let files = scenarioFiles(routes: "bus,operator,326,Bus,3\nother,operator,850,Other,3\nlast,operator,16,Last,3\n",
            stops: scenarioStops([("a", "Gromscheed", 49.6), ("b", "Kapell", 49.6005),
                                 ("c", "Charlys Statioun", 49.601), ("x", "Heienhaff", 49.61), ("d", "Konrad Adenauer", 49.63)]),
            trips: "bus,service,326,,,,\nother,service,850,,,,\nlast,service,16,,,,\n",
            stopTimes: "326,08:37:00,08:37:00,a,1\n326,08:38:00,08:38:00,b,2\n850,08:44:00,08:44:00,c,1\n850,08:45:00,08:45:00,b,2\n850,08:47:00,08:47:00,x,3\n16,08:59:00,08:59:00,x,1\n16,09:10:00,09:10:00,d,2\n")
        var edges = [PreventionWalking.Edge(from: origin, to: a, seconds: 360), .init(from: b, to: c, seconds: 60)]
        if walkingSeconds > 0 { edges.append(.init(from: origin, to: c, seconds: walkingSeconds)) }
        let fixture = try await RoutingPreventionFixture(files: files, walking: PreventionWalking(edges: edges))
        defer { fixture.remove() }
        let page = try await fixture.profile(fixture.query(origin: .coordinate(origin, label: nil)))
        #expect(!page.journeys.isEmpty)
        if walkingSeconds == 0 {
            #expect(page.journeys.allSatisfy { transitTripInstanceSequence($0) == ["326", "850", "16"] })
        } else if walkingSeconds <= 720 {
            #expect(page.journeys.allSatisfy { transitTripInstanceSequence($0) == ["850", "16"] })
        } else {
            #expect(page.journeys.contains { transitTripInstanceSequence($0) == ["326", "850", "16"] })
            #expect(page.journeys.contains { transitTripInstanceSequence($0) == ["850", "16"] })
        }
        if walkingSeconds > 0 && walkingSeconds <= 720 {
            #expect(page.journeys.first?.effectiveDeparture == date(hour: 8, minute: 44).addingTimeInterval(-Double(walkingSeconds)))
        }
        let request = JourneyPlanningRequest(origin: .coordinate(origin, label: nil), destination: .stop(id: "d"), time: .departAt(date(hour: 8)))
        let publicSession = try await fixture.planning(request)
        for result in [try await publicSession.calculate(refresh: .scheduleOnly),
                       try await publicSession.calculate(page: .later, refresh: .scheduleOnly),
                       try await publicSession.refreshRealtime(now: date(hour: 8))] {
            #expect(result.journeys.map(\.id) == page.journeys.map(\.id))
        }
        if walkingSeconds > 0 {
            let lessWalking = try await fixture.profile(fixture.query(preferences: .init(routePreference: .lessWalking), origin: request.origin))
            #expect(lessWalking.journeys.contains { transitTripInstanceSequence($0) == ["326", "850", "16"] })
            if walkingSeconds == 540 {
                let feeder = try #require(lessWalking.journeys.first { $0.firstRide?.tripID == "326" })
                let direct = try #require(lessWalking.journeys.first { $0.firstRide?.tripID == "850" })
                #expect(JourneyQualityPolicy.redundantAccessFeeder(feeder, replacedBy: direct, preferences: .init()))
                for change in 0..<3 {
                    var legs = direct.legs
                    let index = try #require(legs.firstIndex { if case .transit = $0 { true } else { false } })
                    guard case var .transit(ride) = legs[index] else { return }
                    if change == 0 { ride.instance = .init(feedGeneration: 7, tripID: ride.tripID, serviceDate: try GTFSDate(parsing: "20260905")) }
                    if change == 1 { ride.boardSequence = nil }
                    if change == 2 { ride.alightSequence = 4 }
                    legs[index] = .transit(ride)
                    #expect(!JourneyQualityPolicy.redundantAccessFeeder(feeder, replacedBy: replacingLegs(direct, with: legs), preferences: .init()))
                }
                let budget = try await fixture.profile(fixture.query(preferences: .init(maximumWalkingSeconds: 500), origin: request.origin))
                #expect(budget.journeys.allSatisfy { $0.firstRide?.tripID == "326" })
                let arriveBy = try await fixture.profile(fixture.query(origin: request.origin, anchor: date(hour: 9, minute: 10), direction: .arriveBy))
                #expect(arriveBy.journeys.map(\.id) == page.journeys.map(\.id))
            }
        }
    }
    private func replacingLegs(_ journey: Journey, with legs: [JourneyLeg]) -> Journey {
        .init(id: journey.id, origin: journey.origin, destination: journey.destination,
              scheduledDeparture: journey.scheduledDeparture, scheduledArrival: journey.scheduledArrival,
              effectiveDeparture: journey.effectiveDeparture, effectiveArrival: journey.effectiveArrival,
              transferCount: journey.transferCount, walkingDuration: journey.walkingDuration,
              walkingDistance: journey.walkingDistance, waitingDuration: journey.waitingDuration,
              inVehicleDuration: journey.inVehicleDuration, legs: legs, feedGeneration: journey.feedGeneration,
              accessibility: journey.accessibility, matchesPreferredMode: journey.matchesPreferredMode)
    }
}
