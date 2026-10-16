import Foundation

/// ATCP18 survives ATSH header changes until the adapter is reset.
/// Reset the cache on reinitialization or disconnection.
public func elmCanHeaderSetupCommands(
    header: String,
    activeHeader: String?,
    priority18Configured: Bool
) -> [String] {
    guard header != activeHeader else { return [] }
    return (priority18Configured ? [] : ["ATCP18"]) + [header]
}
