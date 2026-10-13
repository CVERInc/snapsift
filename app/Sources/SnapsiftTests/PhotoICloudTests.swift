import Foundation
import AppKit
import Photos
import SnapsiftCore
import SnapsiftVision
@testable import SnapsiftPhotoKit

private final class ICloudTestAsset: PHAsset, @unchecked Sendable {
    let id: String
    init(_ id: String) { self.id = id; super.init() }
    override var localIdentifier: String { id }
}

/// Exercises the real provider's options and callbacks without opening Photos.
private final class ICloudTestImageManager: PHCachingImageManager, @unchecked Sendable {
    struct Call {
        let id: String
        let target: CGSize
        let contentMode: PHImageContentMode
        let options: PHImageRequestOptions
        let reply: (NSImage?, [AnyHashable: Any]?) -> Void
    }
    private let lock = NSLock()
    private var stored: [Call] = []
    var hold = false
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return stored }

    override func requestImage(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode,
                               options: PHImageRequestOptions?,
                               resultHandler: @escaping (NSImage?, [AnyHashable: Any]?) -> Void) -> PHImageRequestID {
        lock.lock()
        stored.append(Call(id: asset.localIdentifier, target: targetSize, contentMode: contentMode,
                           options: options!, reply: resultHandler))
        let shouldHold = hold
        lock.unlock()
        if !shouldHold { resultHandler(nil, nil) }
        return 1
    }
}

private func reportProgress(_ call: ICloudTestImageManager.Call, _ progress: Double, error: Error? = nil) {
    var stop: ObjCBool = false
    call.options.progressHandler?(progress, error, &stop, nil)
}

@MainActor
func checkPhotoICloudPolicy() async {
    print("Photos iCloud policy and accounting")
    let asset = ICloudTestAsset("cloud")
    let manager = ICloudTestImageManager()
    let accounting = PhotoKitDownloadAccounting()
    let defaults = PhotoKitImageProvider(assetsByID: ["cloud": asset], manager: manager,
                                        downloadAccounting: accounting)
    let expected: [(ImageRequestProfile, CGFloat, CGFloat, PHImageContentMode, Bool,
                    PHImageRequestOptionsDeliveryMode, PHImageRequestOptionsResizeMode)] = [
        (.dHash, 9, 8, .aspectFill, false, .opportunistic, .fast),
        (.featurePrint, 160, 160, .aspectFit, false, .opportunistic, .fast),
        (.faceScoring, 512, 512, .aspectFit, true, .highQualityFormat, .exact),
        (.categoryLabels, 256, 256, .aspectFit, true, .highQualityFormat, .fast),
        (.documentLocal, 512, 512, .aspectFit, false, .opportunistic, .fast),
        (.documentHighQuality, 512, 512, .aspectFit, true, .highQualityFormat, .fast),
    ]
    for (profile, width, height, mode, network, delivery, resize) in expected {
        _ = await defaults.image(for: "cloud", profile: profile)
        let call = manager.calls.last!
        check(call.target == CGSize(width: width, height: height) && call.contentMode == mode
              && call.options.isNetworkAccessAllowed == network && call.options.deliveryMode == delivery
              && call.options.resizeMode == resize && call.options.version == .current
              && !call.options.isSynchronous,
              "Photos allowed default: legacy options preserved for \(profile)")
    }
    check(accounting.snapshot.downloadedAssetIDs.isEmpty && accounting.snapshot.downloadingAssetCount == 0,
          "Photos accounting: network permission and nil results alone count no downloads")
    let local = PhotoKitImageProvider(assetsByID: ["cloud": asset], manager: manager,
                                     iCloudDownloadPolicy: .localOnly, downloadAccounting: accounting)
    for profile in ImageRequestProfile.allCases {
        _ = await local.retaining(["cloud"]).image(for: "cloud", profile: profile)
        let opts = manager.calls.last!.options
        check(!opts.isNetworkAccessAllowed && opts.progressHandler == nil,
              "Photos localOnly: network forbidden for \(profile), including retained provider")
    }

    manager.hold = true
    let first = Task { await defaults.image(for: "cloud", profile: .faceScoring) }
    while manager.calls.count < 13 { await Task.yield() }
    let firstCall = manager.calls.last!
    reportProgress(firstCall, 0.2)
    check(accounting.snapshot.downloadingAssetCount == 1 && accounting.snapshot.downloadedAssetIDs.isEmpty,
          "Photos accounting: progress starts an active download without claiming completion")
    let second = Task { await defaults.image(for: "cloud", profile: .categoryLabels) }
    while manager.calls.count < 14 { await Task.yield() }
    let secondCall = manager.calls.last!
    reportProgress(secondCall, 0.4)
    check(accounting.snapshot.downloadingAssetCount == 1,
          "Photos accounting: overlapping requests count distinct assets, not requests")
    reportProgress(firstCall, 1)
    firstCall.reply(nil, nil)
    _ = await first.value
    check(accounting.snapshot.downloadedAssetIDs == ["cloud"] && accounting.snapshot.downloadingAssetCount == 1,
          "Photos accounting: completed progress counts once while another request is active")
    secondCall.reply(nil, [PHImageErrorKey: NSError(domain: "fixture", code: 1)])
    _ = await second.value
    check(accounting.snapshot.downloadedAssetIDs == ["cloud"] && accounting.snapshot.downloadingAssetCount == 0,
          "Photos accounting: failure drains activity without adding a second download")

    let late = Task { await defaults.image(for: "cloud", profile: .faceScoring) }
    while manager.calls.count < 15 { await Task.yield() }
    let lateCall = manager.calls.last!
    reportProgress(lateCall, 0.5)
    accounting.reset()
    reportProgress(lateCall, 1)
    lateCall.reply(nil, nil)
    _ = await late.value
    check(accounting.snapshot.downloadedAssetIDs.isEmpty && accounting.snapshot.downloadingAssetCount == 0,
          "Photos accounting: reset clears state and ignores late prior-operation callbacks")

    let storage = PhotoLibraryStorage(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("snapsift-cloud-session-\(UUID())"))
    defer { try? FileManager.default.removeItem(at: storage.snapshotURL.deletingLastPathComponent()) }
    let title = PhotoLibraryAlbumTitle(name: "fixture", candidateTitles: [])
    let session = PhotoLibrarySession(storage: storage,
        albumTitles: .init(bursts: title, blurry: title, documents: title, exact: title, needsLook: title),
        imageManager: manager)
    session.iCloudDownloadPolicy = .localOnly
    let sessionProvider = session.makeImageProvider(assetsByID: ["cloud": asset])
    check(sessionProvider.iCloudDownloadPolicy == .localOnly,
          "Photos session: changed policy is propagated to constructed providers")
    session.iCloudDownloadPolicy = .allowed
    let tracked = session.makeImageProvider(assetsByID: ["cloud": asset])
    var observed = 0
    session.onChange = { observed += 1 }
    let request = Task { await tracked.image(for: "cloud", profile: .faceScoring) }
    while manager.calls.count < 16 { await Task.yield() }
    let trackedCall = manager.calls.last!
    reportProgress(trackedCall, 0.3)
    while session.downloadingAssetCount == 0 { await Task.yield() }
    check(session.downloadingAssetCount == 1 && observed > 0,
          "Photos session: live download state notifies observers on the main actor")
    reportProgress(trackedCall, 1)
    trackedCall.reply(nil, nil)
    _ = await request.value
    while session.downloadedAssetIDs.isEmpty { await Task.yield() }
    check(session.downloadedAssetIDs == ["cloud"], "Photos session: reported download is exposed to the app")
    await session.refineWithFaces() // Empty fixture pass cannot request real assets.
    check(session.downloadedAssetIDs.isEmpty && !session.refiningFaces,
          "Photos session: faces pass starts a fresh download operation")
    let rescanRequest = Task { await tracked.image(for: "cloud", profile: .faceScoring) }
    while manager.calls.count < 17 { await Task.yield() }
    let rescanCall = manager.calls.last!
    reportProgress(rescanCall, 1)
    rescanCall.reply(nil, nil)
    _ = await rescanRequest.value
    while session.downloadedAssetIDs.isEmpty { await Task.yield() }
    // Exercise startScan's synchronous boundary; never schedule a real Photos scan.
    check(session.beginScan(.burst) && session.downloadedAssetIDs.isEmpty && session.downloadingAssetCount == 0,
          "Photos session: new scan resets accounting synchronously")
}
