import SwiftUI
import Photos
import SnapsiftCore

struct ContentView: View {
    @StateObject private var model = LibraryModel()
    @State private var selection: ReviewGroup.ID?
    @State private var categorySelection: CategoryBucket.ID?
    @State private var deleting = false
    @FocusState private var sidebarFocused: Bool
    @State private var banner: String?
    @AppStorage("snapsift.language") private var langRaw = Language.detect().rawValue

    private var language: Language { Language(rawValue: langRaw) ?? .en }
    private var t: L10n { L10n(language) }

    var body: some View {
        Group {
            switch model.auth {
            case .authorized, .limited:
                main
            case .denied, .restricted:
                gate(message: t.gateDeniedBody(), button: nil)
            default:
                gate(message: t.gateRequestBody(), button: t.gateRequestButton())
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
                .frame(maxWidth: 440)
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
        .safeAreaInset(edge: .bottom) { statusBar }
        .overlay(alignment: .top) { bannerView }
    }

    private var sidebar: some View {
        ScrollViewReader { proxy in
            sidebarList
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Color.reefDeep)
                .navigationTitle("snapsift")
                .frame(minWidth: 240)
                .overlay { if model.groups.isEmpty && model.categories.isEmpty { emptyState } }
                .focusable(!model.groups.isEmpty || !model.categories.isEmpty)
                .focused($sidebarFocused)
                .onKeyPress(.downArrow) { moveSelection(1, proxy); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1, proxy); return .handled }
                .onChange(of: model.groups.count) { _, n in if n > 0 { sidebarFocused = true } }
                .onChange(of: model.categories.count) { _, n in if n > 0 { sidebarFocused = true } }
        }
    }

    /// Arrow-key navigation through the visible rows (groups, or categories in
    /// browse mode), scrolling the new selection into view.
    private func moveSelection(_ delta: Int, _ proxy: ScrollViewProxy) {
        if model.browseMode {
            let ids = model.filteredCategories.map(\.id)
            if let next = step(ids, current: categorySelection, delta: delta) {
                categorySelection = next
                withAnimation { proxy.scrollTo(next, anchor: .center) }
            }
        } else {
            let ids = model.confidentGroups.map(\.id) + model.pendingGroups.map(\.id)
            if let next = step(ids, current: selection, delta: delta) {
                selection = next
                withAnimation { proxy.scrollTo(next, anchor: .center) }
            }
        }
    }

    private func step<ID: Hashable>(_ ids: [ID], current: ID?, delta: Int) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let i = ids.firstIndex(of: current) else { return delta > 0 ? ids.first : ids.last }
        let j = i + delta
        return (j >= 0 && j < ids.count) ? ids[j] : nil   // clamp at ends
    }

    // Manual selection (no List(selection:)) so the system accent highlight never
    // flashes orange behind our teal row background.
    @ViewBuilder private var sidebarList: some View {
        if model.browseMode {
            List {
                Section(t.similarSets()) {
                    ForEach(model.filteredCategories) { categoryRow($0) }
                }
            }
            .searchable(text: $model.searchQuery, placement: .sidebar,
                        prompt: t.searchPrompt(model.apfelAvailable))
            .onSubmit(of: .search) { Task { await model.runApfelSearch() } }
        } else {
            List {
                if !model.confidentGroups.isEmpty {
                    Section(t.sectionConfident(model.confidentGroups.count)) {
                        ForEach(model.confidentGroups) { sidebarRow($0) }
                    }
                }
                if !model.pendingGroups.isEmpty {
                    Section(t.sectionPending(model.pendingGroups.count)) {
                        ForEach(model.pendingGroups) { sidebarRow($0) }
                    }
                }
            }
        }
    }

    private func categoryRow(_ c: CategoryBucket) -> some View {
        let sel = c.id == categorySelection
        return VStack(alignment: .leading, spacing: 3) {
            Text(c.display).font(.headline)
                .foregroundStyle(sel ? .white : Color.reefMint)
            Text(t.frames(c.count)).font(.caption)
                .foregroundStyle(sel ? Color.white.opacity(0.85) : Color.reefTextDim)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { categorySelection = c.id }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(sel ? Color.reefTeal : Color.clear)
                .padding(.vertical, 1)
        )
    }

    private func sidebarRow(_ g: ReviewGroup) -> some View {
        let sel = g.id == selection
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(t.frames(g.photos.count))
                    .font(.headline)
                    .foregroundStyle(sel ? .white : Color.reefMint)
                if g.hasFavorite { Text("★").foregroundStyle(Color.reefAmber) }
                if g.hasVideo { Image(systemName: "video.fill").font(.caption2).foregroundStyle(Color.reefAmber) }
                if g.keepAll { Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(Color.reefGreen) }
            }
            Text(t.sidebarSubtitle(span: g.spanSec, delete: g.deletionIDs.count))
                .font(.caption)
                .foregroundStyle(sel ? Color.white.opacity(0.85) : Color.reefTextDim)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { selection = g.id }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(sel ? Color.reefTeal : Color.clear)
                .padding(.vertical, 1)
        )
        .id(g.id)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if model.isScanning || model.refiningFaces {
                ProgressView().tint(.reefMint)
                Text(model.progress).font(.caption).foregroundStyle(Color.reefTextDim)
                    .multilineTextAlignment(.center).padding(.horizontal)
            } else {
                Image(systemName: "rectangle.stack.badge.minus")
                    .font(.system(size: 34)).foregroundStyle(Color.reefBorder)
                Text(t.scanHint())
                    .font(.caption).foregroundStyle(Color.reefTextDim)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    @ViewBuilder private var detail: some View {
        if model.browseMode {
            if let id = categorySelection, let c = model.categories.first(where: { $0.id == id }) {
                CategoryBrowse(category: c, model: model, t: t)
            } else {
                placeholder("square.grid.2x2", t.selectCategory())
            }
        } else if let id = selection, let g = model.groups.first(where: { $0.id == id }) {
            GroupReview(group: g, model: model, t: t)
        } else if model.groups.isEmpty {
            onboarding
        } else {
            placeholder("photo.on.rectangle.angled", t.selectCluster())
        }
    }

    private func placeholder(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Color.reefBorder)
            Text(text).foregroundStyle(Color.reefTextDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.reefGround)
    }

    /// First-run call to action in the big detail pane — gives a brand-new user
    /// an obvious place to start instead of hunting for a toolbar icon.
    private var onboarding: some View {
        VStack(spacing: 16) {
            if model.isScanning || model.refiningFaces {
                ProgressView().controlSize(.large).tint(.reefMint)
                Text(model.progress).foregroundStyle(Color.reefTextDim)
            } else {
                Image(systemName: "rectangle.stack.badge.minus")
                    .font(.system(size: 52)).foregroundStyle(Color.reefMint)
                Text("snapsift").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                Text(t.scanHint())
                    .foregroundStyle(Color.reefTextDim)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
                HStack(spacing: 14) {
                    onboardCard(title: t.scan(), icon: "sparkle.magnifyingglass",
                                caption: t.tipScan(), prominent: true) {
                        Task { await model.scan(t) }
                    }
                    onboardCard(title: t.lookAlikes(), icon: "rectangle.on.rectangle",
                                caption: t.tipLookAlikes(), prominent: false) {
                        Task { await model.scanLookAlikes(t) }
                    }
                    onboardCard(title: t.similarSets(), icon: "square.grid.3x3.topleft.filled",
                                caption: t.tipSimilarSets(), prominent: false) {
                        Task { await model.scanSimilarSets(t) }
                    }
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.reefGround)
    }

    private func onboardCard(title: String, icon: String, caption: String,
                             prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 22))
                    .foregroundStyle(prominent ? Color.reefGround : Color.reefMint)
                    .frame(height: 26)
                Text(title).font(.headline)
                    .foregroundStyle(prominent ? Color.reefGround : .white)
                Text(caption).font(.caption)
                    .foregroundStyle(prominent ? Color.reefGround.opacity(0.8) : Color.reefTextDim)
                    .multilineTextAlignment(.center).lineLimit(3)
            }
            .frame(width: 220, height: 140)
            .padding(12)
            .background(prominent ? Color.reefMint : Color.reefDeep,
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.reefBorder, lineWidth: prominent ? 0 : 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: status bar (reclaim summary)

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.totalDeletions > 0 {
                Image(systemName: "internaldrive").foregroundStyle(Color.reefMint)
                Text(t.reclaimSummary(count: model.totalDeletions, bytes: model.reclaimableBytes))
                    .foregroundStyle(Color.reefText)
            }
            Spacer()
            if model.qualityAvailable {
                Label(t.appleRanked(), systemImage: "wand.and.stars")
                    .foregroundStyle(Color.reefMint)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.reefBorder), alignment: .top)
        .opacity(model.totalDeletions > 0 || model.qualityAvailable ? 1 : 0)
    }

    @ViewBuilder private var bannerView: some View {
        if let banner {
            Text(banner)
                .font(.callout).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.reefTeal, in: Capsule())
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await model.scan(t) } } label: {
                Label(t.scan(), systemImage: "sparkle.magnifyingglass")
            }
            .help(t.tipScan())
            .disabled(model.isScanning)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await model.scanLookAlikes(t) } } label: {
                Label(t.lookAlikes(), systemImage: "rectangle.on.rectangle")
            }
            .help(t.tipLookAlikes())
            .disabled(model.isScanning)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await model.scanSimilarSets(t) } } label: {
                Label(t.similarSets(), systemImage: "square.grid.3x3.topleft.filled")
            }
            .help(t.tipSimilarSets())
            .disabled(model.isScanning)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await model.refineWithFaces(t) } } label: {
                Label(t.faces(model.facesApplied), systemImage: "face.smiling")
            }
            .help(t.tipFaces())
            .disabled(model.groups.isEmpty || model.refiningFaces || model.isScanning)
        }
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) { Task { await runDelete() } } label: {
                Label(t.deleteN(model.totalDeletions), systemImage: "trash")
            }
            .tint(.reefRed)
            .disabled(model.totalDeletions == 0 || deleting)
        }
        ToolbarItem {
            Menu {
                Toggle(t.contentCheck(), isOn: $model.verifyContent)
                Toggle(t.videos(), isOn: $model.includeVideo)
            } label: { Image(systemName: "slider.horizontal.3") }
        }
        ToolbarItem {
            Menu {
                Picker("", selection: $langRaw) {
                    ForEach(Language.allCases) { l in Text(l.endonym).tag(l.rawValue) }
                }.pickerStyle(.inline)
            } label: { Image(systemName: "globe") }
        }
    }

    private func runDelete() async {
        deleting = true
        defer { deleting = false }
        do {
            let n = try await model.deleteReviewed()
            if !model.groups.contains(where: { $0.id == selection }) { selection = nil }
            if n > 0 { showBanner(t.deletedBanner(n)) }
        } catch {
            showBanner(error.localizedDescription)
        }
    }

    private func showBanner(_ text: String) {
        withAnimation(.spring(duration: 0.3)) { banner = text }
        Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            withAnimation(.easeOut) { banner = nil }
        }
    }
}

/// The side-by-side review grid for one cluster.
struct GroupReview: View {
    let group: ReviewGroup
    @ObservedObject var model: LibraryModel
    let t: L10n

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(t.clusterHeader(count: group.photos.count,
                                         span: group.spanSec, delete: group.deletionIDs.count))
                        .font(.callout).foregroundStyle(Color.reefTextDim)
                    if model.qualityAvailable {
                        Label(t.appleRanked(), systemImage: "wand.and.stars")
                            .font(.caption2).foregroundStyle(Color.reefMint)
                            .help(t.tipAppleRanked())
                    }
                    Spacer()
                    Button { model.toggleKeepAll(group: group.id) } label: {
                        Label(group.keepAll ? t.keepingAll() : t.keepAll(),
                              systemImage: group.keepAll ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(group.keepAll ? .reefGreen : .reefTeal)
                    .help(t.tipKeepAll())
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(group.photos) { p in card(for: p) }
                }
            }
            .padding(16)
        }
        .background(Color.reefGround)
        .navigationTitle(t.frames(group.photos.count))
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
        .help(p.favorite ? t.tipFavorite() : (keep ? t.tipKeeper() : t.tipDelete()))
    }

    private func badge(keep: Bool, del: Bool, fav: Bool) -> some View {
        HStack(spacing: 4) {
            if keep { tag(t.keep(), .reefGreen, Color(hex: 0x04110a)) }
            if del { tag(t.delete(), .reefRed, .white) }
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

/// Browse one semantic category from the "Similar sets" pass — a plain grid of
/// the photos Vision tagged with that label. No keeper/delete; this is curation.
struct CategoryBrowse: View {
    let category: CategoryBucket
    @ObservedObject var model: LibraryModel
    let t: L10n

    private static let cap = 400
    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 10)]

    var body: some View {
        let shown = Array(category.photos.prefix(Self.cap))
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(category.display).font(.title3.bold()).foregroundStyle(Color.reefMint)
                    Text(t.categoryHeader(count: category.count, shown: shown.count))
                        .font(.callout).foregroundStyle(Color.reefTextDim)
                }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(shown) { p in
                        AssetThumbnail(asset: model.asset(for: p.uuid), manager: model.imageManager, side: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .topTrailing) {
                                if p.favorite {
                                    Text("★").font(.system(size: 10, weight: .bold))
                                        .padding(3).background(Color.reefAmber)
                                        .foregroundStyle(Color(hex: 0x1a1203))
                                        .clipShape(RoundedRectangle(cornerRadius: 4)).padding(4)
                                }
                            }
                    }
                }
            }
            .padding(16)
        }
        .background(Color.reefGround)
        .navigationTitle(category.display)
    }
}
