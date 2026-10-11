import Foundation

/// Creation title and every localized/retired title recognized for one app-owned album.
public struct PhotoLibraryAlbumTitle: Sendable {
    public let name: String
    public let candidateTitles: [String]
    public init(name: String, candidateTitles: [String]) {
        self.name = name
        self.candidateTitles = Array(Set(candidateTitles + [name])).sorted()
    }
}

/// App-localized album names. Supplying legacy titles preserves existing memberships.
public struct PhotoLibraryAlbumTitles: Sendable {
    public let bursts: PhotoLibraryAlbumTitle
    public let blurry: PhotoLibraryAlbumTitle
    public let documents: PhotoLibraryAlbumTitle
    public let exact: PhotoLibraryAlbumTitle
    public let needsLook: PhotoLibraryAlbumTitle
    public var allTitles: Set<String> {
        Set(bursts.candidateTitles + blurry.candidateTitles + documents.candidateTitles
            + exact.candidateTitles + needsLook.candidateTitles)
    }
    public init(bursts: PhotoLibraryAlbumTitle, blurry: PhotoLibraryAlbumTitle,
                documents: PhotoLibraryAlbumTitle, exact: PhotoLibraryAlbumTitle,
                needsLook: PhotoLibraryAlbumTitle) {
        self.bursts = bursts; self.blurry = blurry; self.documents = documents
        self.exact = exact; self.needsLook = needsLook
    }
}
