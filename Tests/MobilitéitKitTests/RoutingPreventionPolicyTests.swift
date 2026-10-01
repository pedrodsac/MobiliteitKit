import Foundation
import Testing
@testable import MobiliteitKit

func preventionJourney(id: String, departure: Double = 0, arrival: Double,
                       transfers: Int = 0, walking: Double = 0, firstTrip: String? = "vehicle",
                       accessibility: AccessibilityAssessment = .unknown, preferred: Bool = true) throws -> Journey {
    let anchor = date(hour: 8)
    let start = anchor.addingTimeInterval(departure); let end = anchor.addingTimeInterval(arrival)
    let a = TransitStop(id: "a", code: nil, name: "A", stopDescription: nil, coordinate: .init(latitude: 49.6, longitude: 6.1), locationType: 0, parentStationID: nil, wheelchairBoarding: 0, platformCode: nil)
    let d = TransitStop(id: "d", code: nil, name: "D", stopDescription: nil, coordinate: .init(latitude: 49.63, longitude: 6.1), locationType: 0, parentStationID: nil, wheelchairBoarding: 0, platformCode: nil)
    var legs: [JourneyLeg] = []
    if let firstTrip {
        var ride = TransitLeg(tripID: firstTrip, route: .init(id: "bus", agencyID: nil, shortName: "16", longName: nil, type: 3, color: nil, textColor: nil, routeDescription: nil), headsign: nil,
            board: .init(stop: a, scheduledTime: start, effectiveTime: start),
            alight: .init(stop: d, scheduledTime: end, effectiveTime: end), intermediateStops: [],
            scheduledDeparture: start, scheduledArrival: end, effectiveDeparture: start, effectiveArrival: end,
            status: .active, requiredTransferSecondsAfterWalking: 0)
        ride.instance = .init(feedGeneration: 7, tripID: firstTrip, serviceDate: try GTFSDate(parsing: "20260904"))
        ride.boardSequence = 1; ride.alightSequence = 2
        legs = [.transit(ride)]
    } else {
        legs = [.walk(.init(from: .init(coordinate: a.coordinate), to: .init(coordinate: d.coordinate), departure: start,
            arrival: end, duration: end.timeIntervalSince(start), distanceMeters: walking, polyline: [], steps: [], source: .provider, evidence: .routedPedestrian))]
    }
    return .init(id: .init(id), origin: .stop(id: "a"), destination: .stop(id: "d"),
        scheduledDeparture: start, scheduledArrival: end, effectiveDeparture: start, effectiveArrival: end,
        transferCount: transfers, walkingDuration: walking, walkingDistance: walking,
        waitingDuration: 0, inVehicleDuration: firstTrip == nil ? 0 : end.timeIntervalSince(start), legs: legs,
        feedGeneration: 7, accessibility: accessibility, matchesPreferredMode: preferred)
}

@Suite("Routing prevention: useful choices")
struct RoutingPreventionPolicyTests {
    var query: RouteQuery { .init(origin: .stop(id: "a"), destination: .stop(id: "d"), departureTime: date(hour: 8)) }

    // 06–08, 14–18: easier choices, later useful departures, and genuine tradeoffs.
    @Test(arguments: [60.0, 120.0, 121.0, 600.0])
    func materialTransferBenefit(benefit: Double) throws {
        let direct = try preventionJourney(id: "direct", arrival: 1800, firstTrip: "direct")
        let complex = try preventionJourney(id: "complex", arrival: 1800 - benefit, transfers: 3, firstTrip: "complex")
        let choices = JourneyQualityPolicy.primarySuggestions([complex, direct], count: 5, query: query)
        #expect(choices.contains(where: { $0.id == complex.id }) == (benefit > 120))
        #expect(JourneyQualityPolicy.recommendation(choices, query: query)?.id == direct.id)
        let sole = JourneyQualityPolicy.primarySuggestions([complex], count: 5, query: query)
        #expect(sole.map(\.id) == [complex.id])
    }

    @Test func longWalkForTwoMinutesLosesButAccessibleVariantSurvives() throws {
        let nearby = try preventionJourney(id: "near", arrival: 1800, walking: 100)
        let far = try preventionJourney(id: "far", arrival: 1680, walking: 1500)
        let accessible = try preventionJourney(id: "accessible", arrival: 1680, walking: 1500, accessibility: .verified)
        let choices = JourneyQualityPolicy.primarySuggestions([far, nearby, accessible], count: 5, query: query)
        #expect(!choices.contains { $0.id == far.id })
        #expect(choices.contains { $0.id == accessible.id })
        #expect(JourneyQualityPolicy.recommendation(choices, query: query)?.id == nearby.id)
    }

    @Test func exactDominanceKeepsLaterDepartureAndLowerWalking() throws {
        let best = try preventionJourney(id: "best", departure: 300, arrival: 1800)
        let worse = try preventionJourney(id: "worse", departure: 0, arrival: 2100)
        let lowerWalk = try preventionJourney(id: "lower-walk", departure: 0, arrival: 2100, walking: 0)
        let fastWalk = try preventionJourney(id: "fast-walk", departure: 300, arrival: 1800, walking: 300)
        #expect(JourneyQualityPolicy.dominates(best, worse))
        #expect(!JourneyQualityPolicy.dominates(fastWalk, lowerWalk))
        let later = try preventionJourney(id: "later", departure: 900, arrival: 2400)
        #expect(!JourneyQualityPolicy.dominates(best, later))
        var arriveBy = query
        arriveBy = .init(origin: query.origin, destination: query.destination, departureTime: date(hour: 9), direction: .arriveBy)
        #expect(JourneyQualityPolicy.recommendation([best, later], query: arriveBy)?.id == later.id)
    }

    @Test func needlessWaitAndSlowerChangeLoseWhileSoleRuralServiceSurvives() throws {
        let stay = try preventionJourney(id: "stay", arrival: 1200, firstTrip: "direct")
        let slowChange = try preventionJourney(id: "change", arrival: 1500, transfers: 1, firstTrip: "connection")
        #expect(JourneyQualityPolicy.primarySuggestions([stay, slowChange], count: 5, query: query).map(\.id) == [stay.id])
        let longWait = try preventionJourney(id: "wait", arrival: 3600, transfers: 1, firstTrip: "rural")
        let laterDirect = try preventionJourney(id: "later", departure: 2400, arrival: 3600, firstTrip: "later")
        #expect(JourneyQualityPolicy.dominates(laterDirect, longWait))
        #expect(JourneyQualityPolicy.recommendation([longWait, laterDirect], query: query)?.id == laterDirect.id)
        #expect(JourneyQualityPolicy.primarySuggestions([longWait], count: 5, query: query).map(\.id) == [longWait.id])
        let early = try preventionJourney(id: "early", arrival: 3600, firstTrip: "early")
        #expect(JourneyQualityPolicy.dominates(laterDirect, early))
    }

    // 19: direct walk is an eligible recommendation; transit preferences still count.
    @Test func fifteenMinuteWalkBeatsTwentyFiveMinuteTwoBusRide() throws {
        let walk = try preventionJourney(id: "walk", arrival: 900, walking: 900, firstTrip: nil)
        let bus = try preventionJourney(id: "bus", arrival: 1500, transfers: 1, walking: 100)
        #expect(JourneyQualityPolicy.recommendation([bus, walk], query: query)?.id == walk.id)
        let transitPreference = RouteQuery(origin: query.origin, destination: query.destination, departureTime: query.departureTime,
            preferences: .init(preferredMode: .init(rawValue: 1 << 3)))
        let unpreferredWalk = try preventionJourney(id: "walk", arrival: 900, walking: 900, firstTrip: nil, preferred: false)
        #expect(JourneyQualityPolicy.recommendation([bus, unpreferredWalk], query: transitPreference)?.id == bus.id)
    }

    // 09–10: minor entrances collapse only with compatible access evidence.
    @Test func tinyEndpointVariationKeepsAccessibleException() throws {
        let simple = try preventionJourney(id: "simple", arrival: 1800, walking: 100)
        let variant = try preventionJourney(id: "variant", departure: 30, arrival: 1800, walking: 120)
        let accessible = try preventionJourney(id: "accessible", departure: 30, arrival: 1800, walking: 120, accessibility: .verified)
        let choices = JourneyQualityPolicy.primarySuggestions([simple, variant, accessible], count: 5, query: query)
        #expect(!choices.contains { $0.id == variant.id })
        #expect(choices.contains { $0.id == accessible.id })
        #expect(choices.contains { $0.id == simple.id })
    }

    // 34–36: equal departures order by arrival; the fallback is independently catchable.
    @Test func independentFallbackAndSensibleEqualTimeOrdering() throws {
        let primary = try preventionJourney(id: "primary", arrival: 1800, firstTrip: "first")
        let variants = try (0..<5).map { try preventionJourney(id: "variant-\($0)", arrival: 1850 + Double($0), firstTrip: "first") }
        let fallback = try preventionJourney(id: "fallback", departure: 300, arrival: 2100, firstTrip: "backup")
        let choices = JourneyQualityPolicy.primarySuggestions([primary] + variants + [fallback], count: 5, query: query)
        #expect(choices.contains { $0.id == fallback.id })
        #expect(choices.filter { $0.firstVehicleKey == primary.firstVehicleKey }.count <= 2)
        #expect(fallback.effectiveDeparture >= primary.firstRide!.effectiveDeparture)
        let slow = try preventionJourney(id: "a-slow", arrival: 3300, firstTrip: "slow")
        let fast = try preventionJourney(id: "z-fast", arrival: 1800, firstTrip: "fast")
        #expect(JourneyQualityPolicy.chronologicalOrder(fast, slow, query: query))
        // An unusably early or very poor fallback is never forced into the list.
        let poor = try preventionJourney(id: "poor", departure: 60, arrival: 9000, firstTrip: "poor")
        #expect(JourneyQualityPolicy.primarySuggestions([primary] + variants + [poor], count: 5, query: query).map(\.id) == [primary.id])
    }
}
