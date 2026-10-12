import Foundation

/// Preserves the fixed eight-line partitions, then uses otherwise idle request
/// slots to split the largest remaining partition. Acquisition opts in to this
/// policy explicitly; it never removes a stop, line, or requested interval.
enum RealtimeBoardPartitioning {
    static func partitions(for lineGroups: [[String]],
                           maximumConcurrentRequests: Int) -> [[[String]]] {
        var result = lineGroups.map { lines -> [[String]] in
            guard !lines.isEmpty else { return [[]] }
            return stride(from: 0, to: lines.count, by: 8).map {
                Array(lines[$0..<min($0 + 8, lines.count)])
            }
        }
        var count = result.reduce(0) { $0 + $1.count }
        let available = max(1, maximumConcurrentRequests)
        while count < available {
            var largest: (group: Int, partition: Int, lines: Int)?
            for group in result.indices {
                for partition in result[group].indices {
                    let lines = result[group][partition].count
                    // Ties retain stop and partition order. Small partitions
                    // already bound the server work without another request.
                    if lines > 4, lines > (largest?.lines ?? 0) {
                        largest = (group, partition, lines)
                    }
                }
            }
            guard let largest else { break }
            let lines = result[largest.group][largest.partition]
            let middle = (lines.count + 1) / 2
            result[largest.group].replaceSubrange(largest.partition...largest.partition,
                with: [Array(lines[..<middle]), Array(lines[middle...])])
            count += 1
        }
        return result
    }
}
