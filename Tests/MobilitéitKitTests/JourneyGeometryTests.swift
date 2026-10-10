import Testing
@testable import MobiliteitKit

struct JourneyGeometryTests {
    @Test func stationTransferKeepsTheTwoSourceShapesDisconnected() {
        let station = Coordinate(latitude: 49.636375, longitude: 6.174766)
        let arrivalBay = Coordinate(latitude: 49.6361, longitude: 6.1750)
        let departureBay = Coordinate(latitude: 49.6367, longitude: 6.1745)
        let incoming = [Coordinate(latitude: 49.6355, longitude: 6.1755), arrivalBay]
        let outgoing = [departureBay, Coordinate(latitude: 49.6372, longitude: 6.1735)]

        let first = JourneyGeometry.segment(of: incoming, from: incoming[0], to: station)
        let second = JourneyGeometry.segment(of: outgoing, from: station, to: outgoing[1])

        #expect(first == incoming)
        #expect(second == outgoing)
        #expect(first.last != second.first)
        #expect(!first.contains(station) && !second.contains(station))
    }

    @Test func intermediateRidePreservesSourcePointsWhenStopsAreOffset() {
        let shape = (0..<5).map { Coordinate(latitude: 49.6 + Double($0) * 0.001, longitude: 6.1) }
        let board = Coordinate(latitude: 49.6011, longitude: 6.1002)
        let alight = Coordinate(latitude: 49.6029, longitude: 6.1002)

        #expect(JourneyGeometry.segment(of: shape, from: board, to: alight) == Array(shape[1...3]))
    }

    @Test func coincidentShapeIndicesDoNotInventAConnector() {
        let shape = [Coordinate(latitude: 49.6, longitude: 6.1),
                     Coordinate(latitude: 49.61, longitude: 6.1)]
        let board = Coordinate(latitude: 49.6001, longitude: 6.1001)
        let alight = Coordinate(latitude: 49.6002, longitude: 6.1002)

        #expect(JourneyGeometry.segment(of: shape, from: board, to: alight).isEmpty)
    }
}
