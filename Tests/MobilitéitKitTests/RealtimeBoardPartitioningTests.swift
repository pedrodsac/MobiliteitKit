import Testing
@testable import MobiliteitKit

@Suite struct RealtimeBoardPartitioningTests {
    @Test func idleRequestSlotsSplitTheLargestGroupsInStableOrder() {
        let first = (0..<17).map { "first-\($0)" }
        let second = (0..<11).map { "second-\($0)" }
        let groups = [first, second, [], ["single"]]
        let actual = RealtimeBoardPartitioning.partitions(for: groups, maximumConcurrentRequests: 10)
        let expected: [[[String]]] = [
            [Array(first[0..<4]), Array(first[4..<8]), Array(first[8..<12]),
             Array(first[12..<16]), [first[16]]],
            [Array(second[0..<4]), Array(second[4..<8]), Array(second[8..<11])],
            [[]], [["single"]]
        ]
        #expect(actual == expected)
        #expect(actual.reduce(0) { $0 + $1.count } == 10)
        #expect(actual == RealtimeBoardPartitioning.partitions(for: groups, maximumConcurrentRequests: 10))
    }

    @Test(arguments: [1, 5, 7, 8, 10, 40])
    func everyLineAndUnrestrictedStopRemainCovered(concurrency: Int) {
        let groups = [(0..<17).map(String.init), (20..<31).map(String.init), [], ["single"]]
        let actual = RealtimeBoardPartitioning.partitions(for: groups,
            maximumConcurrentRequests: concurrency)
        #expect(actual.count == groups.count)
        for index in groups.indices {
            #expect(actual[index].flatMap { $0 } == groups[index])
            #expect(actual[index].allSatisfy { $0.count <= 8 })
            #expect(actual[index].contains(where: \.isEmpty) == groups[index].isEmpty)
        }
        let baselineCount = 7
        let actualCount = actual.reduce(0) { $0 + $1.count }
        #expect(actualCount >= baselineCount)
        #expect(actualCount <= max(baselineCount, concurrency))
    }

    @Test func anOversubscribedBatchKeepsItsOriginalEightLinePartitions() {
        let lines = (0..<17).map(String.init)
        let actual = RealtimeBoardPartitioning.partitions(for: [lines, []],
            maximumConcurrentRequests: 2)
        #expect(actual == [[Array(lines[0..<8]), Array(lines[8..<16]), [lines[16]]], [[]]])
    }

    @Test func smallAndUnrestrictedGroupsDoNotCreateExtraRequests() {
        #expect(RealtimeBoardPartitioning.partitions(for: [[], ["a", "b", "c", "d"]],
            maximumConcurrentRequests: 40) == [[[]], [["a", "b", "c", "d"]]])
        #expect(RealtimeBoardPartitioning.partitions(for: [], maximumConcurrentRequests: 0).isEmpty)
    }
}
