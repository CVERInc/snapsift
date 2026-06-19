import SwiftUI
import Photos
import SnapsiftCore
import Signet

struct ContentView: View {
    @StateObject private var model = LibraryModel()
    @State private var selection: ReviewGroup.ID?
    @State private var categorySelection: CategoryBucket.ID?
    @State private var deleting = false
    @State private var focusedFrame: String?     // uuid of the focused grid cell
    @State private var previewID: String?        // big-preview overlay
    @State private var showHelp = false
    @FocusState private var sidebarFocused: Bool
    @FocusState private var gridFocused: Bool
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
                gate(message: t.privacyPitch(), button: t.gateRequestButton())
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
        // The permission screen has no main toolbar, so carry the language menu
        // here too — otherwise a non-default-language user is stuck on the gate.
        .toolbar { ToolbarItem { languageMenu } }
    }

    /// Globe language switcher, shared by the gate and the main toolbar.
    private var languageMenu: some View {
        Menu {
            Picker("", selection: $langRaw) {
                ForEach(Language.allCases) { l in Text(l.endonym).tag(l.rawValue) }
            }.pickerStyle(.inline)
        } label: { Image(systemName: "globe") }
    }

    // MARK: main split

    private var main: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            // Help docks as a manual trailing column rather than .inspector —
            // .inspector quietly forces the NavigationSplitView toolbar into its
            // overflow (»), collapsing the action buttons regardless of window
            // width. A plain HStack keeps the toolbar laid out normally.
            HStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity)
                    .safeAreaInset(edge: .top) { scopeBar }
                if showHelp {
                    Divider()
                    helpPanel
                        .frame(width: 290)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { statusBar }
        .overlay(alignment: .top) { bannerView }
        .overlay { if previewID != nil { previewOverlay } }
    }

    @ViewBuilder private var previewOverlay: some View {
        if let previewID {
            // Space opens this — the one deliberate moment we DO fetch the full
            // original from iCloud, so the user can zoom in and be sure before
            // deciding keep/delete. The scan itself stays fully offline.
            BigPreview(asset: model.asset(for: previewID), manager: model.imageManager, t: t) {
                self.previewID = nil
            }
        }
    }

    private func toggleHelp() {
        withAnimation(.easeOut(duration: 0.18)) { showHelp.toggle() }
    }

    /// The keyboard cheat sheet, docked as a non-modal column on the trailing
    /// edge. It stays put — filling the otherwise-empty right side — until "?" is
    /// pressed again or the ✕ is tapped.
    private var helpPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(t.helpTitle()).font(.title3.bold()).foregroundStyle(Color.reefMint)
                    Spacer()
                    Button { toggleHelp() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.reefTextDim)
                    .help(t.helpClose())
                }
                ForEach(t.helpRows(), id: \.0) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Text(row.0).font(.system(.callout, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.white).frame(width: 116, alignment: .leading)
                        Text(row.1).foregroundStyle(Color.reefText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .background(Color.reefDeep)
    }

    private var sidebar: some View {
        ScrollViewReader { proxy in
            sidebarList
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                // Frosted teal sidebar: keep the reef tint, gain depth (chrome,
                // not canvas — the photo grid stays fully opaque for color truth).
                .background(Color.reefDeep.opacity(0.55))
                .background(.ultraThinMaterial)
                .navigationTitle("snapsift")
                .frame(minWidth: 240)
                .overlay { if model.groups.isEmpty && model.categories.isEmpty { emptyState } }
                .focusable(!model.groups.isEmpty || !model.categories.isEmpty)
                .focused($sidebarFocused)
                .onKeyPress { handleListKey($0, proxy) }
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

    private var selectedGroup: ReviewGroup? { model.groups.first { $0.id == selection } }

    // MARK: keyboard — list zone

    private func handleListKey(_ kp: KeyPress, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        if kp.characters == "?" { toggleHelp(); return .handled }
        switch kp.key {
        case .upArrow:    moveSelection(-1, proxy); return .handled
        case .downArrow:  moveSelection(1, proxy);  return .handled
        case .rightArrow, .return: enterGrid(); return .handled
        default: break
        }
        switch kp.characters {
        case "k": moveSelection(-1, proxy); return .handled
        case "j": moveSelection(1, proxy);  return .handled
        case "l": enterGrid(); return .handled
        case "a": if let id = selection { model.toggleKeepAll(group: id) }; return .handled
        case "d": if let id = selection { model.toggleDeleteAll(group: id) }; return .handled
        case let c where c.count == 1 && c.first!.isNumber:
            if let n = Int(c), n >= 1 { pickNth(n - 1) }; return .handled
        default: return .ignored
        }
    }

    private func pickNth(_ i: Int) {
        guard let g = selectedGroup, i >= 0, i < g.photos.count else { return }
        model.promote(group: g.id, to: g.photos[i].uuid)
    }

    private func enterGrid() {
        guard !model.browseMode, let g = selectedGroup, !g.photos.isEmpty else { return }
        focusedFrame = g.keeperID
        gridFocused = true
    }

    // MARK: keyboard — grid zone

    private func handleGridKey(_ kp: KeyPress) -> KeyPress.Result {
        if kp.characters == "?" { toggleHelp(); return .handled }
        guard let g = selectedGroup else { return .ignored }
        switch kp.key {
        case .leftArrow, .upArrow:   moveFrame(-1, g); return .handled
        case .rightArrow, .downArrow: moveFrame(1, g); return .handled
        case .escape:  sidebarFocused = true; return .handled
        case .return:  if let f = focusedFrame { model.promote(group: g.id, to: f) }; return .handled
        default: break
        }
        switch kp.characters {
        case "h", "k": moveFrame(-1, g); return .handled
        case "l", "j": moveFrame(1, g);  return .handled
        case " ":      previewID = focusedFrame; return .handled
        case "a":      model.toggleKeepAll(group: g.id); return .handled
        case "d":      model.toggleDeleteAll(group: g.id); return .handled
        default: return .ignored
        }
    }

    private func moveFrame(_ delta: Int, _ g: ReviewGroup) {
        let ids = g.photos.map(\.uuid)
        if let next = step(ids, current: focusedFrame, delta: delta) { focusedFrame = next }
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
            GroupReview(group: g, model: model, t: t, focusedFrame: gridFocused ? focusedFrame : nil)
                .focusable()
                .focused($gridFocused)
                .onKeyPress { handleGridKey($0) }
        } else if model.groups.isEmpty {
            // Focusable so the bare "?" cheat-sheet key works on the first-run
            // screen too (the sidebar isn't focusable until groups exist). The
            // focus ring is suppressed so the whole pane doesn't glow.
            onboarding
                .focusable()
                .focusEffectDisabled()
                .onKeyPress { kp in
                    if kp.characters == "?" { toggleHelp(); return .handled }
                    return .ignored
                }
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
      ScrollView {
        VStack(spacing: 16) {
            if model.isScanning || model.refiningFaces {
                ProgressView().controlSize(.large).tint(.reefMint)
                Text(model.progress).foregroundStyle(Color.reefTextDim)
            } else {
                Image(systemName: "rectangle.stack.badge.minus")
                    .font(.system(size: 52)).foregroundStyle(Color.reefMint)
                Text("snapsift").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                Text(t.privacyPitch())
                    .font(.callout)
                    .foregroundStyle(Color.reefTextDim)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
                Text(t.scanHint())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.reefMint)
                    .padding(.top, 2)
                LazyVGrid(columns: onboardColumns, spacing: 14) {
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
                .frame(maxWidth: 720)
                .padding(.top, 8)
                .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 460)
        .padding(.vertical, 24)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.reefGround)
    }

    /// Adaptive columns so the start cards wrap (and never clip) as the window
    /// narrows: three across when there's room, down to one on a slim pane.
    private let onboardColumns = [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 14)]

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
            .frame(maxWidth: .infinity, minHeight: 140)
            .padding(12)
            .onboardCardSurface(prominent: prominent)
        }
        .buttonStyle(.plain)
    }

    // MARK: scope tab (which media the scans cover)

    /// A persistent segmented tab atop the detail pane — photos only, or photos
    /// plus videos. It's a scope (what to scan over), distinct from the three
    /// task cards. Changing it applies to the next scan you run.
    private var scopeBar: some View {
        Picker("", selection: $model.includeVideo) {
            Text(t.scopePhotosOnly()).tag(false)
            Text(t.scopeWithVideo()).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(model.isScanning)
        .frame(maxWidth: 320)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.reefBorder), alignment: .bottom)
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
            .keyboardShortcut("1", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await model.scanLookAlikes(t) } } label: {
                Label(t.lookAlikes(), systemImage: "rectangle.on.rectangle")
            }
            .help(t.tipLookAlikes())
            .disabled(model.isScanning)
            .keyboardShortcut("2", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await model.scanSimilarSets(t) } } label: {
                Label(t.similarSets(), systemImage: "square.grid.3x3.topleft.filled")
            }
            .help(t.tipSimilarSets())
            .disabled(model.isScanning)
            .keyboardShortcut("3", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await model.refineWithFaces(t) } } label: {
                Label(t.faces(model.facesApplied), systemImage: "face.smiling")
            }
            .help(t.tipFaces())
            .disabled(model.groups.isEmpty || model.refiningFaces || model.isScanning)
            .keyboardShortcut("4", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) { Task { await runDelete() } } label: {
                Label(t.deleteN(model.totalDeletions), systemImage: "trash")
            }
            .tint(.reefRed)
            .disabled(model.totalDeletions == 0 || deleting)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        ToolbarItem {
            Button { toggleHelp() } label: {
                Image(systemName: "questionmark.circle")
            }
            .help(t.helpTitle())
            .keyboardShortcut("?", modifiers: .command)
        }
        ToolbarItem { languageMenu }
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
    var focusedFrame: String? = nil

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
                    Button { model.toggleDeleteAll(group: group.id) } label: {
                        Label(group.deleteAll ? t.deletingAll() : t.deleteAll(),
                              systemImage: group.deleteAll ? "trash.fill" : "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(group.deleteAll ? .reefRed : .reefTeal)
                    .help(t.tipDeleteAll())
                    Button { model.toggleKeepAll(group: group.id) } label: {
                        Label(group.keepAll ? t.keepingAll() : t.keepAll(),
                              systemImage: group.keepAll ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(group.keepAll ? .reefGreen : .reefTeal)
                    .help(t.tipKeepAll())
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(group.photos.enumerated()), id: \.element.id) { idx, p in
                        card(for: p, index: idx)
                    }
                }
            }
            .padding(16)
        }
        .background(Color.reefGround)
        .navigationTitle(t.frames(group.photos.count))
    }

    private func card(for p: Photo, index: Int) -> some View {
        let keep = group.isKeeper(p)
        let del = group.isDelete(p)
        let focused = p.uuid == focusedFrame
        // Protected frames (favorite / edited / document) are never deletable —
        // show them amber, never red, so the UI can't imply a protected frame
        // will be removed.
        let border: Color = keep ? .reefGreen : (p.isProtected ? .reefAmber : (del ? .reefRed : .clear))
        return VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                AssetThumbnail(asset: model.asset(for: p.uuid), manager: model.imageManager, side: 160)
                    .opacity(del ? 0.34 : 1)
                badge(keep: keep, del: del, fav: p.favorite)
                if index < 9 {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(width: 18, height: 18)
                        .background(Color.reefGround.opacity(0.75), in: Circle())
                        .foregroundStyle(Color.reefMint)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
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
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .padding(2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.promote(group: group.id, to: p.uuid) }
        .help(p.isProtected ? t.tipFavorite() : (keep ? t.tipKeeper() : t.tipDelete()))
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

private extension View {
    /// Start-card surface: the prominent card is a solid mint CTA; the rest are
    /// Signet frosted-glass cards. Both share the design-system card radius.
    @ViewBuilder func onboardCardSurface(prominent: Bool) -> some View {
        if prominent {
            background(Color.reefMint,
                       in: RoundedRectangle(cornerRadius: CVERRadius.card, style: .continuous))
        } else {
            liquidGlassCard(cornerRadius: CVERRadius.card)
        }
    }
}
