import Foundation

public func isReadOnlyVehicleCommand(_ command: String) -> Bool {
    let c = command.uppercased().filter { !$0.isWhitespace }
    if c.hasPrefix("AT") { return true }
    if c.count == 4, c.hasPrefix("01") || c.hasPrefix("09") { return UInt64(c, radix: 16) != nil }
    if c.count == 6, c.hasPrefix("22") { return UInt64(c, radix: 16) != nil }
    return false
}
