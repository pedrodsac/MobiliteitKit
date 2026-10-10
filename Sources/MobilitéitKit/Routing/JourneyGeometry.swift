import Foundation

public enum JourneyGeometry {
    public static func segment(of shape: [Coordinate], from origin: Coordinate,
                               to destination: Coordinate) -> [Coordinate] {
        guard shape.count >= 2 else { return [origin, destination] }
        let start = shape.indices.min { distanceSquared(shape[$0], origin) < distanceSquared(shape[$1], origin) } ?? 0
        let end = (start..<shape.count).min {
            distanceSquared(shape[$0], destination) < distanceSquared(shape[$1], destination)
        } ?? (shape.count - 1)
        guard end > start else { return [] }
        // Aggregate station coordinates can lie between several platforms.
        // Use them to select the ride's range, never to extend the source
        // shape across the station forecourt or between separate bus bays.
        return Array(shape[start...end])
    }
    private static func distanceSquared(_ a: Coordinate, _ b: Coordinate) -> Double {
        let latitude = a.latitude - b.latitude
        let longitude = (a.longitude - b.longitude) * cos((a.latitude + b.latitude) * .pi / 360)
        return latitude * latitude + longitude * longitude
    }
    static func enrich(_ journeys: [Journey], store: GTFSStore) async -> [Journey] {
        let ids = Set(journeys.flatMap { $0.legs.compactMap { leg -> String? in
            if case let .transit(t) = leg { t.tripID } else { nil }
        } })
        let bases = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, id.range(of: "#frequency-").map { String(id[..<$0.lowerBound]) } ?? id)
        })
        let shapes = (try? await store.shapes(forTripIDs: Array(ids.union(bases.values)))) ?? [:]
        return journeys.map { journey in
            journey.replacing(legs: journey.legs.map { leg in
                guard case var .transit(t) = leg else { return leg }
                t.polyline = segment(of: shapes[t.tripID] ?? shapes[bases[t.tripID] ?? t.tripID] ?? [],
                                     from: t.board.stop.coordinate, to: t.alight.stop.coordinate)
                return .transit(t)
            })
        }
    }
}
