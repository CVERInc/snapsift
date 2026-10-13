import SnapsiftPhotoKit

extension ScanSource {
    enum Kind: Hashable { case photos, folder }
    var kind: Kind { .photos }
}
