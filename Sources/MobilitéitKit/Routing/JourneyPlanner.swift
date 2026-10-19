import Foundation

/// Reuses prepared routing snapshots until the installed database changes.
public actor JourneyPlanner {
    public nonisolated let hasRealtimeProvider: Bool
    private let walkingProvider: (any WalkingRoutingProvider)?
    private let realtimeClient: MobiliteitAPIClient?
    private let suppliedRealtimeProvider: (any RealtimeRoutingProvider)?
    private let snapshotCacheDirectory: URL?

    private struct DatabaseFingerprint: Equatable {
        let path: String
        let fileSize: UInt64
        let modificationDate: Date?
    }

    private struct Preparation {
        let id: UUID
        let fingerprint: DatabaseFingerprint?
        let task: Task<TransitRouter, Error>
    }

    private var router: TransitRouter?
    private var routerFingerprint: DatabaseFingerprint?
    private var preparation: Preparation?

    /// - Parameter snapshotCacheDirectory: A directory owned by the caller, such as one inside Caches. The
    ///   prepared routing snapshot is stored there as one versioned file, so a cold start loads it instead of
    ///   rebuilding it from the database. The file is tied to the database it was built from; a new feed,
    ///   a new format version or a damaged file is ignored and rewritten. `nil` keeps the snapshot in memory only.
    public init(
        walkingProvider: (any WalkingRoutingProvider)? = nil,
        realtimeClient: MobiliteitAPIClient? = nil,
        realtimeProvider: (any RealtimeRoutingProvider)? = nil,
        snapshotCacheDirectory: URL? = nil
    ) {
        self.hasRealtimeProvider = realtimeClient != nil || realtimeProvider != nil
        self.walkingProvider = walkingProvider
        self.realtimeClient = realtimeClient
        self.suppliedRealtimeProvider = realtimeProvider
        self.snapshotCacheDirectory = snapshotCacheDirectory
    }

    /// Deletes the stored snapshot, for example when a new feed is installed.
    /// The file is also ignored automatically once its database changes.
    public static func removeSnapshotCache(in directory: URL) {
        SnapshotCache.remove(in: directory)
    }

    public func makePlanningSession(databaseURL: URL, request: JourneyPlanningRequest,
                                    now: Date = .now) async throws -> JourneyResultSession {
        let started = ContinuousClock.now
        let router = try await router(for: databaseURL)
        return try JourneyResultSession(router: router, snapshot: await router.snapshot, databaseURL: databaseURL, request: request, now: now,
            preparationMilliseconds: RoutingDiagnostics.elapsed(since: started))
    }

    public func router(for databaseURL: URL) async throws -> TransitRouter {
        guard let fingerprint = fingerprint(for: databaseURL) else {
            throw JourneyPlannerError.noInstalledFeed
        }
        if fingerprint == routerFingerprint, let router {
            return router
        }

        let currentPreparation: Preparation
        if let preparation, preparation.fingerprint == fingerprint {
            currentPreparation = preparation
        } else {
            let created = Preparation(
                id: UUID(),
                fingerprint: fingerprint,
                task: Task(priority: .utility) {
                    let realtimeProvider = try suppliedRealtimeProvider ?? realtimeClient.map {
                        try HafasRealtimeRoutingProvider(
                            databaseURL: databaseURL,
                            client: $0,
                            maximumConcurrentBoardRequests: 32,
                            cacheLifetime: 60,
                            requestTimeout: .seconds(4)
                        )
                    }
                    return try await TransitRouter(
                        databaseURL: databaseURL,
                        snapshotCacheDirectory: snapshotCacheDirectory,
                        walkingProvider: walkingProvider,
                        realtimeProvider: realtimeProvider
                    )
                }
            )
            preparation = created
            currentPreparation = created
        }

        do {
            let prepared = try await currentPreparation.task.value
            guard fingerprint == self.fingerprint(for: databaseURL) else {
                if preparation?.id == currentPreparation.id {
                    preparation = nil
                }
                return try await router(for: databaseURL)
            }
            if preparation?.id == currentPreparation.id {
                router = prepared
                routerFingerprint = fingerprint
                preparation = nil
            }
            return prepared
        } catch {
            if preparation?.id == currentPreparation.id {
                preparation = nil
            }
            throw error
        }
    }

    private func fingerprint(for databaseURL: URL) -> DatabaseFingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return DatabaseFingerprint(
            path: databaseURL.standardizedFileURL.path,
            fileSize: size.uint64Value,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }
}

