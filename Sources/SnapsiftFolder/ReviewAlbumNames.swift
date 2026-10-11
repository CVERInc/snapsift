import Foundation

/// Show at most three names, with the number of remaining names when needed.
/// Empty or unreadable membership has no presentation line.
public func reviewAlbumNamesSummary(_ names: [String]) -> String? {
    guard !names.isEmpty else { return nil }
    let visible = names.prefix(3).joined(separator: ", ")
    return names.count > 3 ? "\(visible) +\(names.count - 3)" : visible
}
