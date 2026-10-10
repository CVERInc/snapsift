import Foundation

/// User album names for presentation, excluding snapsift's current and legacy
/// organizational titles. Repeated names appear once, in first-seen order.
/// Album counts remain separate: distinct albums can have the same title.
public func userAlbumNames(titles: [String], snapsiftTitles: Set<String>) -> [String] {
    var seen: Set<String> = []
    return titles.filter { !snapsiftTitles.contains($0) && seen.insert($0).inserted }
}
