import Foundation

public let didSectorSize = 0x1000
public let didPageSize = 0x100
public let didKnownPriorityStart = 0x2000
public let didKnownPriorityEnd = 0x20FF

public func didSectorIndex(_ did: UInt16) -> Int {
    Int(did) >> 12
}

public func didPageIndex(_ did: UInt16) -> Int {
    Int(did) >> 8
}

public func didSectorBounds(_ sector: Int) -> ClosedRange<UInt16>? {
    guard (0...15).contains(sector) else { return nil }
    let start = sector * didSectorSize
    return UInt16(start)...UInt16(start + didSectorSize - 1)
}

public func didPageBounds(_ page: Int) -> ClosedRange<UInt16>? {
    guard (0...255).contains(page) else { return nil }
    let start = page * didPageSize
    return UInt16(start)...UInt16(start + didPageSize - 1)
}

public func didOverlappingSectors(start: UInt16, end: UInt16) -> [Int] {
    guard start <= end else { return [] }
    return Array((Int(start) >> 12)...(Int(end) >> 12))
}

public func didPagesInSector(_ sector: Int, start: UInt16, end: UInt16) -> [Int] {
    guard start <= end, let bounds = didSectorBounds(sector) else { return [] }
    let lo = max(Int(start), Int(bounds.lowerBound))
    let hi = min(Int(end), Int(bounds.upperBound))
    guard lo <= hi else { return [] }
    return Array((lo >> 8)...(hi >> 8))
}

public func didKnownPriority(start: UInt16, end: UInt16) -> [UInt16] {
    guard start <= end else { return [] }
    let lo = max(Int(start), didKnownPriorityStart)
    let hi = min(Int(end), didKnownPriorityEnd)
    guard lo <= hi else { return [] }
    return (lo...hi).map(UInt16.init)
}

public func didSectorHeads(start: UInt16, end: UInt16, width: Int = 4) -> [UInt16] {
    guard start <= end else { return [] }
    let width = max(1, width)
    var result: [UInt16] = []

    for sector in didOverlappingSectors(start: start, end: end) {
        guard let bounds = didSectorBounds(sector) else { continue }
        let lo = max(Int(start), Int(bounds.lowerBound))
        let hi = min(Int(end), Int(bounds.upperBound))
        guard lo <= hi else { continue }
        let last = min(hi, lo + width - 1)
        result.append(contentsOf: (lo...last).map(UInt16.init))
    }
    return result
}

public func didPageSentinels(
    sector: Int,
    start: UInt16,
    end: UInt16,
    offsets: [Int] = [0x00, 0x80]
) -> [UInt16] {
    guard start <= end else { return [] }
    var result: [UInt16] = []

    for page in didPagesInSector(sector, start: start, end: end) {
        guard let bounds = didPageBounds(page) else { continue }
        let lo = max(Int(start), Int(bounds.lowerBound))
        let hi = min(Int(end), Int(bounds.upperBound))

        for offset in offsets {
            let did = Int(bounds.lowerBound) + offset
            if lo <= did, did <= hi, (0...0xFFFF).contains(did) {
                result.append(UInt16(did))
            }
        }
    }
    return result
}

public func didOutcomeInterestScore(status: DidProbeStatus, nrc: UInt8?) -> Int {
    switch status {
    case .positive, .positivePartial:
        return 100
    case .nrc:
        return nrc != nil && nrc != 0x31 ? 25 : 0
    default:
        return 0
    }
}

public func didPrioritizedSectors(
    start: UInt16,
    end: UInt16,
    scores: [Int: Int]
) -> [Int] {
    didOverlappingSectors(start: start, end: end).sorted {
        let left = scores[$0, default: 0]
        let right = scores[$1, default: 0]
        if left != right { return left > right }
        return $0 < $1
    }
}

public func didPrioritizedPages(
    sector: Int,
    start: UInt16,
    end: UInt16,
    scores: [Int: Int]
) -> [Int] {
    didPagesInSector(sector, start: start, end: end).sorted {
        let left = scores[$0, default: 0]
        let right = scores[$1, default: 0]
        if left != right { return left > right }
        return $0 < $1
    }
}

public func didEstimatedScanSeconds(
    ecuCount: Int,
    start: UInt16,
    end: UInt16,
    rateHz: Double,
    alreadyCompleted: Int = 0
) -> Double? {
    guard ecuCount >= 0, start <= end, rateHz > 0 else { return nil }
    let total = max(
        0,
        ecuCount * (Int(end) - Int(start) + 1) - max(0, alreadyCompleted)
    )
    return Double(total) / rateHz
}
