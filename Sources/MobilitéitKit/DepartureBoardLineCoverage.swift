import Foundation

/// A metadata-only reuse plan. Acquisition revalidates each source before
/// taking its response, so planning never extends freshness or revives a flight.
struct DepartureBoardLineCoveragePart: Sendable {
    enum Source: Sendable {
        case cached(String)
        case flight(UUID)
    }
    let source: Source
    let scope: BoardCacheScope
    let requestedLines: [String]

    struct Candidate {
        let source: Source
        let scope: BoardCacheScope
        let acquired: Date
        let cached: Bool
    }

    static func select(_ available: [Candidate], for scope: BoardCacheScope) -> [Self] {
        var candidates = available
        var remaining = Set(scope.selectedLines)
        var parts: [Self] = []
        while !remaining.isEmpty {
            let needed = remaining
            func covered(_ candidate: Candidate) -> Set<String> {
                candidate.scope.selectedLines.isEmpty ? needed
                    : needed.intersection(candidate.scope.selectedLines)
            }
            guard let selected = candidates.indices.filter({ !covered(candidates[$0]).isEmpty }).max(by: { a, b in
                let first = candidates[a], second = candidates[b]
                if first.cached != second.cached { return !first.cached }
                if covered(first).count != covered(second).count { return covered(first).count < covered(second).count }
                if first.acquired != second.acquired { return first.acquired < second.acquired }
                return first.scope.namespace > second.scope.namespace
            }) else { break }
            let candidate = candidates.remove(at: selected)
            let lines = covered(candidate)
            let requested = BoardCacheScope(namespace: candidate.scope.namespace, interval: scope.interval, maximumJourneys: -1)
            parts.append(.init(source: candidate.source, scope: requested, requestedLines: lines.sorted()))
            remaining.subtract(lines)
        }
        return parts
    }
}
