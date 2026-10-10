import Foundation

struct LiveSignalSample: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let rpm: Double?
    let speedKmh: Double?
    let hvPowerKW: Double?
}
