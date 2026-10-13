/// Shared source policy. Apps that require consent opt into `localOnly`.
/// The default preserves the macOS app's existing request behavior.
public enum ICloudDownloadPolicy: Sendable {
    case allowed
    case localOnly
}
