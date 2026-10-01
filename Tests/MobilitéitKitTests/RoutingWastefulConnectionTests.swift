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
        } else if walkingSeconds <= 660 {
            #expect(page.journeys.allSatisfy { transitTripInstanceSequence($0) == ["850", "16"] })
        } else {
            #expect(page.journeys.contains { transitTripInstanceSequence($0) == ["326", "850", "16"] })
            #expect(page.journeys.contains { transitTripInstanceSequence($0) == ["850", "16"] })
        }
        if walkingSeconds > 0 && walkingSeconds <= 660 {
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
