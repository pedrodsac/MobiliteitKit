import Foundation
import os

extension Raptor {
    /// Tests only: the shard count to use instead of the default.
    @TaskLocal static var mergeShardCountOverride: Int?
    /// One shard per worker: stops of different shards merge at the same time.
    static func mergeShardCount(workerCount: Int) -> Int { max(1, mergeShardCountOverride ?? workerCount) }

    /// Tests only: how long the merger pauses after each chunk, to make it the slower side.
    @TaskLocal static var mergeDelayForTests: Duration?

    /// Everything a chunk scan reads. All workers of a round share it.
    struct PatternScanInputs: Sendable {
        let snapshot: RoutingSnapshot
        let query: RouteQuery
        let previousLabels: [Int: LabelProfile]
        let boardings: BoardingIndex
        let patternStartPositions: [Int]
        let activeInstancesByPattern: [Int: [ActiveTripInstance]]
        let reachableStops: [Bool]?
        let round: Int
        let maxRounds: Int
        let finalRoundAlightStops: Set<Int>
    }

    struct PatternScanOutcome: Sendable {
        let merge: PatternScanMerge
        /// Wall time until the last chunk finished scanning.
        let scanMilliseconds: Double
        /// Merge time left after that point. Earlier chunks merge while later ones scan.
        let mergeTailMilliseconds: Double
        /// The most chunks that were started and not yet merged at any time.
        let peakOutstandingChunks: Int
    }

    private enum ScanTaskResult: Sendable {
        case scanned(CompactScratch?)
        case merged(PatternScanMerge)
    }

    /// Scan the chunks on `workerCount` workers while a separate task merges the
    /// finished ones in chunk order. Workers are refilled as soon as one finishes;
    /// the merge never runs on the loop that hands out chunks.
    static func scanAndMerge(chunks: [(index: Int, patterns: [Int])], workerCount: Int,
        inputs: PatternScanInputs, nextLabelID: Int) async throws -> PatternScanOutcome {
        let scanStarted = ContinuousClock.now
        let snapshot = inputs.snapshot
        // Schedule costly chunks first, but merge in the original index order. A window
        // holds six times the workers' chunks, so the costliest ones start early instead
        // of in the last window, where their scan would end the round.
        let schedulingWindow = max(1, workerCount * 6)
        let scheduled = stride(from: 0, to: chunks.count, by: schedulingWindow).flatMap { start in
            chunks[start..<min(start + schedulingWindow, chunks.count)].sorted { a, b in
                func cost(_ patterns: [Int]) -> Int {
                    patterns.reduce(0) { total, pattern in
                        total + (inputs.activeInstancesByPattern[pattern]?.count ?? 0)
                            * snapshot.patterns[pattern].stops.count
                    }
                }
                let left = cost(a.patterns), right = cost(b.patterns)
                return left == right ? a.index < b.index : left > right
            }
        }
        // Chunks that were started and not yet merged: running ones, finished ones that wait
        // for an earlier chunk, and finished ones that wait for the merger. A window starts only
        // after the previous one has been handed out, so while the lowest unmerged chunk has not
        // started, fewer than a window of chunks are outstanding. A limit of one window therefore
        // never keeps the merger from making progress, and it bounds the memory of chunks that
        // are scanned but not merged.
        let outstandingLimit = schedulingWindow
        let (finished, finishedSink) = AsyncStream.makeStream(of: PatternScanResult.self)
        let (progress, progressSink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let mergedCount = OSAllocatedUnfairLock(initialState: 0)
        let chunkCount = chunks.count
        let shardCount = mergeShardCount(workerCount: workerCount)
        var scanEnded = scanStarted
        var peakOutstanding = 0
        let merge = try await withThrowingTaskGroup(of: ScanTaskResult.self) { group in
            group.addTask(priority: .userInitiated) {
                .merged(await mergeInOrder(finished, chunkCount: chunkCount, nextLabelID: nextLabelID, shardCount: shardCount, boardings: inputs.boardings) {
                    mergedCount.withLock { $0 += 1 }
                    progressSink.yield()
                })
            }
            var availableScratch: [CompactScratch] = []
            var progressWaits = progress.makeAsyncIterator()
            var cursor = 0
            var active = 0
            func enqueue() {
                let chunk = scheduled[cursor]
                cursor += 1
                active += 1
                let scratch = availableScratch.popLast() ?? CompactScratch()
                group.addTask(priority: .userInitiated) {
                    var result = try scanPatterns(
                        chunkIndex: chunk.index,
                        patternIDs: chunk.patterns,
                        snapshot: inputs.snapshot,
                        query: inputs.query,
                        previousLabels: inputs.previousLabels,
                        boardings: inputs.boardings,
                        patternStartPositions: inputs.patternStartPositions,
                        activeInstancesByPattern: inputs.activeInstancesByPattern,
                        reachableStops: inputs.reachableStops,
                        round: inputs.round,
                        maxRounds: inputs.maxRounds,
                        finalRoundAlightStops: inputs.finalRoundAlightStops, scratch: scratch
                    )
                    let returned = result.scratch
                    result.scratch = nil
                    finishedSink.yield(result)
                    return .scanned(returned)
                }
            }
            do {
                while true {
                    if cursor < scheduled.count, active < workerCount {
                        let outstanding = cursor - mergedCount.withLock { $0 }
                        if outstanding < outstandingLimit {
                            enqueue()
                            peakOutstanding = max(peakOutstanding, outstanding + 1)
                            continue
                        }
                        // Too many chunks wait for the merger: let it catch up first.
                        guard await progressWaits.next() != nil else { throw CancellationError() }
                        continue
                    }
                    guard active > 0, let result = try await group.next() else { break }
                    active -= 1
                    if case let .scanned(scratch?) = result { availableScratch.append(scratch) }
                }
            } catch {
                finishedSink.finish()
                throw error
            }
            scanEnded = .now
            finishedSink.finish()
            while let result = try await group.next() {
                if case let .merged(merge) = result { return merge }
            }
            preconditionFailure("The merger returned no result")
        }
        let mergeEnded = ContinuousClock.now
        func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        }
        return .init(merge: merge, scanMilliseconds: milliseconds(scanStarted.duration(to: scanEnded)),
            mergeTailMilliseconds: milliseconds(scanEnded.duration(to: mergeEnded)),
            peakOutstandingChunks: peakOutstanding)
    }

    /// Merge finished chunks strictly in chunk-index order, whatever order they arrive in.
    /// With more than one shard, each shard merges its stops of every chunk, in chunk order, in a
    /// task of its own, and, given the `boardings`, turns its merged profiles into labels while the
    /// other shards do the same. `merged` reports each chunk once no shard needs it any more.
    static func mergeInOrder(_ finished: AsyncStream<PatternScanResult>, chunkCount: Int, nextLabelID: Int,
        shardCount: Int = 1, boardings: BoardingIndex? = nil, merged: @escaping @Sendable () -> Void) async -> PatternScanMerge {
        var merge = PatternScanMerge(nextID: nextLabelID, shardCount: shardCount)
        var pending: [Int: PatternScanResult] = [:]
        var nextChunk = 0
        var shards = [MergeShard](repeating: .init(), count: merge.shardCount)
        var materialized: [Int: LabelProfile]?
        await withTaskGroup(of: (shard: MergeShard, labels: [Int: LabelProfile]).self) { group in
            var inboxes: [AsyncStream<ShardWork>.Continuation] = []
            if merge.shardCount > 1 {
                shards = []
                for _ in 0..<merge.shardCount {
                    let (inbox, sink) = AsyncStream.makeStream(of: ShardWork.self)
                    inboxes.append(sink)
                    group.addTask(priority: .userInitiated) {
                        var shard = MergeShard()
                        for await work in inbox {
                            shard.merge(work)
                            work.ticket?.consumed()
                        }
                        return (shard, boardings.map { Raptor.materialize(shard.profiles, boardings: $0) } ?? [:])
                    }
                }
            }
            for await result in finished {
                pending[result.chunkIndex] = result
                while let ready = pending.removeValue(forKey: nextChunk) {
                    nextChunk += 1
                    if let split = merge.append(ready) {
                        let busy = split.busyShards
                        if inboxes.isEmpty {
                            shards[0].merge(split.work(shard: 0, ticket: nil))
                            merged()
                        } else if busy.isEmpty {
                            merged()
                        } else {
                            let ticket = ChunkTicket(shards: busy.count, merged: merged)
                            for shard in busy { inboxes[shard].yield(split.work(shard: shard, ticket: ticket)) }
                        }
                    } else {
                        merged()
                    }
                    if let delay = mergeDelayForTests { try? await Task.sleep(for: delay) }
                }
            }
            for inbox in inboxes { inbox.finish() }
            var labels: [Int: LabelProfile] = [:]
            for await outcome in group {
                shards.append(outcome.shard)
                labels.merge(outcome.labels) { _, shardLabels in shardLabels }
            }
            if boardings != nil, !inboxes.isEmpty { materialized = labels }
        }
        merge.finish(shards, materialized: materialized)
        // A cancelled scan ends the stream early.
        if !Task.isCancelled { precondition(pending.isEmpty && nextChunk == chunkCount) }
        return merge
    }
}
