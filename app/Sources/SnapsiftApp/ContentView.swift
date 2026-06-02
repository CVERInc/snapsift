import SwiftUI
import Photos
import SnapsiftCore

struct ContentView: View {
    @StateObject private var model = LibraryModel()
    @State private var selection: ReviewGroup.ID?
    @State private var deleting = false
    @State private var errorText: String?

    var body: some View {
        Group {
            switch model.auth {
            case .authorized, .limited:
                main
            case .denied, .restricted:
                gate(message: "snapsift needs access to your Photos library. Enable it in System Settings ▸ Privacy & Security ▸ Photos.",
                     button: nil)
            default:
                gate(message: "snapsift reads your Photos library on-device to find near-duplicate bursts. Nothing leaves your Mac.",
                     button: "Grant access")
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Color.reefGround)
        .preferredColorScheme(.dark)
        .tint(.reefTeal)
    }

    // MARK: permission gate

    private func gate(message: String, button: String?) -> some View {
        VStack(spacing: 18) {
            Text("snapsift").font(.system(size: 30, weight: .bold)).foregroundStyle(Color.reefMint)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.reefTextDim)
                .frame(maxWidth: 420)
            if let button {
                Button(button) { Task { await model.requestAccess() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.reefGround)
    }

    // MARK: main split

    private var main: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar { toolbar }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(model.groups) { g in
                let sel = g.id == selection
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(g.photos.count) frames")
                            .font(.headline)
                            .foregroundStyle(sel ? .white : Color.reefMint)
                        if g.hasFavorite { Text("★").foregroundStyle(Color.reefAmber) }
                        if g.hasVideo { Image(systemName: "video.fill").font(.caption2).foregroundStyle(Color.reefAmber) }
                    }
                    Text("spans \(g.spanSec, specifier: "%.1f")s · delete \(g.deletionIDs.count)")
                        .font(.caption)
                        .foregroundStyle(sel ? Color.white.opacity(0.85) : Color.reefTextDim)
                }
                .padding(.vertical, 4)
                .tag(g.id)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(sel ? Color.reefTeal : Color.clear)
                        .padding(.vertical, 1)
                )
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.reefDeep)
        .navigationTitle("snapsift")
        .frame(minWidth: 240)
        .overlay {
            if model.groups.isEmpty { emptyState }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if model.isScanning {
                ProgressView().tint(.reefMint)
                Text(model.progress).font(.caption).foregroundStyle(Color.reefTextDim)
            } else {
                Image(systemName: "rectangle.stack.badge.minus")
                    .font(.system(size: 34)).foregroundStyle(Color.reefBorder)
                Text("Scan to find near-duplicate bursts")
                    .font(.caption).foregroundStyle(Color.reefTextDim)
            }
        }
        .padding()
    }

    @ViewBuilder private var detail: some View {
        if let id = selection, let g = model.groups.first(where: { $0.id == id }) {
            GroupReview(group: g, model: model)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 40)).foregroundStyle(Color.reefBorder)
                Text("Select a cluster").foregroundStyle(Color.reefTextDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.reefGround)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Toggle("Videos", isOn: $model.includeVideo).toggleStyle(.switch).tint(.reefTeal)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.scan() }
            } label: { Label("Scan", systemImage: "sparkle.magnifyingglass") }
            .disabled(model.isScanning)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.scanLookAlikes() }
            } label: { Label("Look-alikes", systemImage: "rectangle.on.rectangle") }
            .help("Find the same photo saved across different days (neural, on-device)")
            .disabled(model.isScanning)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.refineWithFaces() }
            } label: {
                Label(model.facesApplied ? "Faces ✓" : "Faces", systemImage: "face.smiling")
            }
            .help("Re-pick keepers using on-device face + open-eyes analysis")
            .disabled(model.groups.isEmpty || model.refiningFaces || model.isScanning)
        }
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) {
                Task { await runDelete() }
            } label: {
                Label("Delete \(model.totalDeletions)", systemImage: "trash")
            }
            .tint(.reefRed)
            .disabled(model.totalDeletions == 0 || deleting)
        }
    }

    private func runDelete() async {
        deleting = true
        defer { deleting = false }
        do {
            let n = try await model.deleteReviewed()
            if !model.groups.contains(where: { $0.id == selection }) { selection = nil }
            errorText = n == 0 ? nil : nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// The side-by-side review grid for one cluster.
struct GroupReview: View {
    let group: ReviewGroup
    @ObservedObject var model: LibraryModel

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("\(group.photos.count) frames · spans \(group.spanSec, specifier: "%.1f")s · keep 1, delete \(group.deletionIDs.count)")
                        .font(.callout).foregroundStyle(Color.reefTextDim)
                    if model.qualityAvailable {
                        Label("Apple-ranked", systemImage: "wand.and.stars")
                            .font(.caption2).foregroundStyle(Color.reefMint)
                            .help("Keeper chosen using Apple's on-device quality scores")
                    }
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(group.photos) { p in
                        card(for: p)
                    }
                }
            }
            .padding(16)
        }
        .background(Color.reefGround)
        .navigationTitle("Review")
    }

    private func card(for p: Photo) -> some View {
        let keep = group.isKeeper(p)
        let del = group.isDelete(p)
        let border: Color = keep ? .reefGreen : (p.favorite ? .reefAmber : (del ? .reefRed : .clear))
        return VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                AssetThumbnail(asset: model.asset(for: p.uuid), manager: model.imageManager, side: 160)
                    .opacity(del ? 0.34 : 1)
                badge(keep: keep, del: del, fav: p.favorite)
            }
            Text(p.filename.isEmpty ? String(p.uuid.prefix(8)) : p.filename)
                .font(.caption2).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(Color.reefTextDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 5)
        }
        .background(Color.reefDeep)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { model.promote(group: group.id, to: p.uuid) }
        .help(p.favorite ? "Favorite — always kept" : (keep ? "Keeper" : "Will be deleted · click to keep this one"))
    }

    private func badge(keep: Bool, del: Bool, fav: Bool) -> some View {
        HStack(spacing: 4) {
            if keep { tag("KEEP", .reefGreen, Color(hex: 0x04110a)) }
            if del { tag("DELETE", .reefRed, .white) }
            if fav { tag("★", .reefAmber, Color(hex: 0x1a1203)) }
        }
        .padding(6)
    }

    private func tag(_ text: String, _ bg: Color, _ fg: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(bg).foregroundStyle(fg)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
