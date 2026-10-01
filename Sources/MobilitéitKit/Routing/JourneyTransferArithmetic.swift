import Foundation

/// GTFS and rider minima are TOTAL interchange times. Only a boarding buffer is additive.
public enum JourneyTransferArithmetic {
    public static func requiredAfterWalking(totalMinimum: Int, walkingSeconds: TimeInterval,
                                            boardingBufferSeconds: Int = 0) -> Int {
        // Round UP the residual; fractional movement must not authorize a short transfer.
        Int(ceil(max(Double(boardingBufferSeconds), Double(totalMinimum) - walkingSeconds)))
    }
    static func recalculating(_ original: [JourneyLeg], boardingBufferSeconds: Int) -> [JourneyLeg] {
        var legs = original
        var hasIncoming = false
        var movement = 0.0
        for index in legs.indices {
            switch legs[index] {
            case let .walk(walk): if hasIncoming { movement += walk.duration }
            case var .transit(ride):
                if hasIncoming, let total = ride.requiredTotalTransferSeconds {
                    ride.requiredTransferSecondsAfterWalking = requiredAfterWalking(totalMinimum: total,
                        walkingSeconds: movement, boardingBufferSeconds: boardingBufferSeconds)
                    legs[index] = .transit(ride)
                }
                hasIncoming = true; movement = 0
            case .inSeatContinuation: hasIncoming = false; movement = 0
            }
        }
        return legs
    }
}
