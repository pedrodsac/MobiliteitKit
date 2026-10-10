import Foundation

extension Raptor {
    /// Only scalar comparison state lives in the scan's hot profiles. A path is
    /// materialized after a chunk finishes, for its surviving labels only.
    struct ScanKey: Sendable {
        var id: Int
        var arrival: Double
        let departure: Double
        let doorDeparture: Double
        let walkingSeconds: Int
        let minimumSlack: Int
        let totalSlack: Int
        let preferred: Bool
        let prefixRank: Int
        let incomingTrip: Int
        let serviceDate: GTFSDate
        var alightPosition: Int = 1

        @inline(__always) func sameTrips(as other: Self) -> Bool {
            prefixRank == other.prefixRank && incomingTrip == other.incomingTrip && serviceDate == other.serviceDate
        }
        @inline(__always) func precedes(_ other: Self) -> Bool {
            if departure != other.departure { return departure < other.departure }
            if arrival != other.arrival { return arrival < other.arrival }
            if walkingSeconds != other.walkingSeconds { return walkingSeconds < other.walkingSeconds }
            if prefixRank != other.prefixRank { return prefixRank < other.prefixRank }
            if incomingTrip != other.incomingTrip { return incomingTrip < other.incomingTrip }
            if serviceDate != other.serviceDate { return serviceDate < other.serviceDate }
            return id < other.id
        }
        @inline(__always) func arrivesBefore(_ other: Self) -> Bool {
            arrival == other.arrival ? precedes(other) : arrival < other.arrival
        }
        @inline(__always) func walksBefore(_ other: Self) -> Bool {
            walkingSeconds == other.walkingSeconds ? precedes(other) : walkingSeconds < other.walkingSeconds
        }
        @inline(__always) func dominates(_ other: Self) -> Bool {
            // Every record here alights at this profile's stop, has no transfer
            // walk, and resets its walking visits to that single stop.
            sameTrips(as: other) && alightPosition == other.alightPosition && preferred == other.preferred
                && minimumSlack >= other.minimumSlack && totalSlack >= other.totalSlack
                && doorDeparture >= other.doorDeparture && arrival <= other.arrival
                && walkingSeconds <= other.walkingSeconds
                && (doorDeparture != other.doorDeparture || arrival < other.arrival
                    || walkingSeconds < other.walkingSeconds || sameTrips(as: other))
        }
    }

    struct ScanPath: Sendable {
        let sourceIndex: Int
        let trip: Int
        let board: Int
        let alight: Int
        let boardPos: Int
        let alightPos: Int
        let day: GTFSDate
        let scheduledBoard: Date
        let scheduledAlight: Date
        let boardTime: Date
        let alightTime: Date
        let requiredTransferSeconds: Int
        var boardingDeadline: Date? = nil
    }

    struct CompactProfile: Sendable {
        // 48 retained records plus one insertion slot. Sorted arrays hold slot
        // numbers rather than copies or reference-counted Label objects.
        var keys: [ScanKey?] = []
        var paths: [ScanPath?] = []
        var ordered: [Int] = []
        var byArrival: [Int] = []
        var byWalk: [Int] = []
        var byIncomingTrip: [Int: UInt64] = [:]
        var available: UInt64 = (1 << (profileWidth + 1)) - 1
        var lastUnprotected: Int?
        var lastPreferred: Int?

        init() {
            ordered.reserveCapacity(8)
            byArrival.reserveCapacity(8)
            byWalk.reserveCapacity(8)
            byIncomingTrip.reserveCapacity(8)
        }

        @inline(__always) func isDominated(_ candidate: ScanKey, peers suppliedPeers: UInt64? = nil) -> Bool {
            var peers = suppliedPeers ?? byIncomingTrip[candidate.incomingTrip, default: 0]
            while peers != 0 {
                let index = peers.trailingZeroBitCount
                peers &= peers - 1
                if keys[index]!.dominates(candidate) { return true }
            }
            return false
        }

        /// Identical quota rejection to the reference profile. Never reject a
        /// candidate that could first remove one of its dominated peers.
        @inline(__always) func cannotEnter(_ candidate: ScanKey, peers suppliedPeers: UInt64? = nil) -> Bool {
            guard ordered.count == profileWidth, let lastUnprotected else { return false }
            let quota = profileWidth / 5
            guard keys[lastUnprotected]!.arrivesBefore(candidate),
                  keys[ordered[quota - 1]]!.precedes(candidate),
                  candidate.precedes(keys[ordered[profileWidth - quota]]!),
                  keys[byWalk[quota - 1]]!.walksBefore(candidate),
                  !candidate.preferred || lastPreferred.map({ keys[$0]!.arrivesBefore(candidate) }) == true
            else { return false }
            var peers = suppliedPeers ?? byIncomingTrip[candidate.incomingTrip, default: 0]
            while peers != 0 {
                let index = peers.trailingZeroBitCount
                peers &= peers - 1
                if candidate.dominates(keys[index]!) { return false }
            }
            return true
        }

        @inline(__always) mutating func insert(_ key: ScanKey, path: ScanPath) -> Bool {
            var peers = byIncomingTrip[key.incomingTrip, default: 0]
            while peers != 0 {
                let slot = peers.trailingZeroBitCount
                peers &= peers - 1
                if key.dominates(keys[slot]!) { remove(slot) }
            }
            let slot = available.trailingZeroBitCount
            available &= ~(1 << slot)
            if slot == 16, slot == keys.count {
                keys.reserveCapacity(profileWidth + 1); paths.reserveCapacity(profileWidth + 1)
                ordered.reserveCapacity(profileWidth + 1)
                byArrival.reserveCapacity(profileWidth + 1); byWalk.reserveCapacity(profileWidth + 1)
            }
            if slot == keys.count {
                keys.append(key); paths.append(path)
            } else { keys[slot] = key; paths[slot] = path }
            byIncomingTrip[key.incomingTrip, default: 0] |= 1 << slot
            insertIndex(slot, into: &ordered, keys: keys, order: .departure)
            insertIndex(slot, into: &byArrival, keys: keys, order: .arrival)
            insertIndex(slot, into: &byWalk, keys: keys, order: .walking)
            if ordered.count < profileWidth {
                lastUnprotected = nil; lastPreferred = nil
                return true
            }
            let protected = quotas()
            if ordered.count > profileWidth,
               let victim = byArrival.reversed().first(where: { protected.mask & (1 << $0) == 0 }) {
                remove(victim)
            }
            if ordered.count == profileWidth {
                lastUnprotected = byArrival.reversed().first { protected.mask & (1 << $0) == 0 }
                lastPreferred = protected.lastPreferred
            } else { lastUnprotected = nil; lastPreferred = nil }
            return keys[slot] != nil
        }

        mutating func remove(_ slot: Int) {
            let trip = keys[slot]!.incomingTrip
            let remaining = byIncomingTrip[trip, default: 0] & ~(1 << slot)
            byIncomingTrip[trip] = remaining == 0 ? nil : remaining
            ordered.remove(at: ordered.firstIndex(of: slot)!)
            byArrival.remove(at: byArrival.firstIndex(of: slot)!)
            byWalk.remove(at: byWalk.firstIndex(of: slot)!)
            keys[slot] = nil; paths[slot] = nil; available |= 1 << slot
        }

        func quotas() -> (mask: UInt64, lastPreferred: Int?) {
            let quota = profileWidth / 5
            var mask: UInt64 = 0; var count = 0; var last: Int?
            for slot in byArrival where keys[slot]!.preferred {
                if count == quota { break }
                mask |= 1 << slot; count += 1; last = slot
            }
            for slot in ordered.prefix(quota) { mask |= 1 << slot }
            for slot in ordered.suffix(quota) { mask |= 1 << slot }
            for slot in byArrival.prefix(quota) { mask |= 1 << slot }
            for slot in byWalk.prefix(quota) { mask |= 1 << slot }
            return (mask, count == quota ? last : nil)
        }
    }

    enum ScanOrder { case departure, arrival, walking }
    @inline(__always) static func insertIndex(_ slot: Int, into values: inout [Int],
        keys: [ScanKey?], order: ScanOrder) {
        let candidate = keys[slot]!
        var lower = 0; var upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let peer = keys[values[middle]]!
            let before: Bool = switch order {
            case .departure: peer.precedes(candidate)
            case .arrival: peer.arrivesBefore(candidate)
            case .walking: peer.walksBefore(candidate)
            }
            if before { lower = middle + 1 } else { upper = middle }
        }
        values.insert(slot, at: lower)
    }
}
