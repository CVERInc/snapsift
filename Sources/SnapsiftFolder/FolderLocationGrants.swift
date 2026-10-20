import Foundation

public enum FolderLocationGrantStatus: Sendable {
    case notAsked, granted, declined
}

/// The app owns persistence and picking. Access returns an already-started
/// storage-root scope, used only for Trash operations and their recovery.
@MainActor
public struct FolderLocationGrants {
    public var status: (URL) -> FolderLocationGrantStatus = { _ in .notAsked }
    public var access: (URL) -> FolderResolvedItem? = { _ in nil }

    public init(status: @escaping (URL) -> FolderLocationGrantStatus,
                access: @escaping (URL) -> FolderResolvedItem?) {
        self.status = status
        self.access = access
    }

    private nonisolated init() {}

    public nonisolated static let none = FolderLocationGrants()
}

/// Recognizes the location shape independently of the host platform.
/// A picked top-level grant must equal this root after path normalization.
public func folderGrantLocation(for url: URL) -> URL? {
    fileProviderStorageRoot(at: url)
}

/// One operation retains each root once, including failed access attempts.
@MainActor
final class FolderLocationGrantAccess {
    private let grants: FolderLocationGrants
    private let port: FolderTrashPort
    private var attempted: Set<URL> = []
    private var scopes: [URL: FolderResolvedItem] = [:]

    init(grants: FolderLocationGrants, port: FolderTrashPort) {
        self.grants = grants
        self.port = port
    }

    func missing(for urls: [URL]) -> URL? {
        for url in urls {
            guard let root = port.grantLocation(url) else { continue }
            if attempted.insert(root).inserted, grants.status(root) != .declined,
               let scope = grants.access(root) {
                if scope.url.isFileURL, folderLocationComponents(scope.url) == folderLocationComponents(root) {
                    scopes[root] = scope
                } else { scope.stopAccessing() }
            }
            if scopes[root] == nil { return root }
        }
        return nil
    }

    func stop() {
        scopes.values.forEach { $0.stopAccessing() }
        scopes.removeAll()
    }
}
