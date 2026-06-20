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
    @State private var previewID: String?        // big-preview overlay (loupe)
    @State private var loupeOpen = false          // true when loupe is showing
    @State private var protectedHintFrame: String? // frame showing "protected — ⇧X" hint
    @State private var showForceRejectAlert = false // ⇧X confirmation alert
    @State private var forceRejectTarget: (groupID: ReviewGroup.ID, frameID: String)? = nil
    @State private var showHelp = false
    @FocusState private var sidebarFocused: Bool
    @FocusState private var gridFocused: Bool
    @State private var banner: String?
    @State private var writingAlbums = false
    @AppStorage("snapsift.language") private var langRaw = Language.detect().rawValue
    // FIX 2: persistent delete-failure alert
    @State private var deleteErrorAlert = false

    private var language: Language { Language(rawValue: langRaw) ?? .en }
    private var t: L10n { L10n(language) }

    var body: some View {
        Group {
            switch model.auth {
            case .authorized:
                main
            // FIX 1: .limited ("Selected Photos") is iOS-only in practice, but
            // PHAuthorizationStatus includes the case in the enum on all platforms.
            // On macOS, requestAuthorization(for: .readWrite) never returns .limited
            // today, but we guard it explicitly: snapsift's whole purpose is
            // library-wide dedup+delete, which "Selected Photos" fundamentally
            // cannot do. Route it to a clear gate instead of the review UI where
            // deletes would silently fail.
            case .limited:
                limitedGate
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
                Button(button) {
                    Task {
                        await model.requestAccess()
                        model.loadAlbums()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.reefGround)
        // The permission screen has no main toolbar, so carry the language menu
        // here too — otherwise a non-default-language user is stuck on the gate.
        .toolbar { ToolbarItem { languageMenu } }
    }

    // FIX 1: gate shown when the user granted "Selected Photos" (limited) access.
    // snapsift needs to read and delete across the WHOLE library; limited access
    // fundamentally cannot satisfy that — and deleteAssets silently fails under it.
    // The only correct path is to ask the user to upgrade to Full Access in System
    // Settings. NSWorkspace.shared.open is the correct macOS API (no UIKit).
    private var limitedGate: some View {
        gate(message: t.gateLimitedBody(),
             button: t.gateLimitedButton()) {
            openPhotosPrivacySettings()
        }
    }

    /// Opens System Settings ▸ Privacy & Security ▸ Photos on macOS 13+.
    /// The `x-apple.systempreferences:com.apple.preference.security?Privacy_Photos`
    /// URL scheme is the documented macOS deep-link; NSWorkspace is the correct
    /// macOS-native API (no UIKit / no iOS-only PHPhotoLibrary picker).
    private func openPhotosPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else { return }
        NSWorkspace.shared.open(url)
    }

    /// gate() variant that also accepts an action closure for the button.
    private func gate(message: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 18) {
            Text("snapsift").font(.system(size: 30, weight: .bold)).foregroundStyle(Color.reefMint)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.reefTextDim)
                .frame(maxWidth: 460)
            if let button {
                Button(button, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.reefGround)
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
        .onAppear { model.loadAlbums() }
        // FIX 2: persistent alert when delete fails — never let a destructive
        // action fail silently. Gives the user a direct path to fix the permission.
        .alert(t.deleteErrorTitle(), isPresented: $deleteErrorAlert) {
            Button(t.deleteErrorOpenSettings()) { openPhotosPrivacySettings() }
            Button(t.deleteErrorDismiss(), role: .cancel) {}
        } message: {
            Text(t.deleteErrorBody())
        }
        // ⇧X force-reject confirmation: same dialog path as mouse "include protected".
        .alert(t.deleteProtectedAlertTitle(), isPresented: $showForceRejectAlert) {
            Button(t.deleteProtectedAlertConfirm(), role: .destructive) {
                if let target = forceRejectTarget {
                    model.forceReject(group: target.groupID, frameID: target.frameID)
                }
                forceRejectTarget = nil
            }
            Button(t.deleteProtectedAlertCancel(), role: .cancel) {
                forceRejectTarget = nil
            }
        } message: {
            Text(t.forceRejectAlertBody())
        }
    }

    @ViewBuilder private var previewOverlay: some View {
        if loupeOpen, let previewID, let g = selectedGroup {
            LoupeOverlay(
                group: g,
                currentID: previewID,
                model: model,
                t: t,
                onClose: {
                    loupeOpen = false
                    self.previewID = nil
                },
                onPrev: { moveFrame(-1, g) },
                onNext: { moveFrame(1, g) }
            )
            // Keep the focused frame in sync with the loupe's displayed frame.
            .onChange(of: focusedFrame) { _, new in
                if loupeOpen, let new { self.previewID = new }
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
        case "a": if let id = selection { model.keepAll(group: id) }; return .handled
        case "d": if let id = selection { model.rejectAll(group: id) }; return .handled
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
        loupeOpen = false
        previewID = nil
    }

    // MARK: keyboard — grid zone

    private func handleGridKey(_ kp: KeyPress) -> KeyPress.Result {
        if kp.characters == "?" { toggleHelp(); return .handled }
        guard let g = selectedGroup else { return .ignored }

        // If loupe is open, route navigation + frame actions through loupe.
        if loupeOpen {
            return handleLoupeKey(kp, g)
        }

        switch kp.key {
        case .leftArrow, .upArrow:   moveFrame(-1, g); return .handled
        case .rightArrow, .downArrow: moveFrame(1, g); return .handled
        case .escape:
            sidebarFocused = true; return .handled
        case .return:
            if let f = focusedFrame { model.promote(group: g.id, to: f) }
            return .handled
        case .delete:
            handleRejectKey(g, modifiers: kp.modifiers); return .handled
        default: break
        }
        switch kp.characters {
        case "h", "k": moveFrame(-1, g); return .handled
        case "l", "j": moveFrame(1, g);  return .handled
        case " ":
            if let f = focusedFrame { previewID = f; loupeOpen = true }
            return .handled
        case "a":      model.keepAll(group: g.id); return .handled
        case "d":      model.rejectAll(group: g.id); return .handled
        case "x", "X":
            handleRejectKey(g, modifiers: kp.modifiers); return .handled
        default: return .ignored
        }
    }

    /// Key handler while the loupe is open — same frame actions + prev/next + close.
    private func handleLoupeKey(_ kp: KeyPress, _ g: ReviewGroup) -> KeyPress.Result {
        switch kp.key {
        case .leftArrow:  moveFrame(-1, g); return .handled
        case .rightArrow: moveFrame(1, g);  return .handled
        case .escape:
            loupeOpen = false; previewID = nil; return .handled
        case .return:
            if let f = focusedFrame { model.promote(group: g.id, to: f) }
            return .handled
        case .delete:
            handleRejectKey(g, modifiers: kp.modifiers); return .handled
        default: break
        }
        switch kp.characters {
        case "h": moveFrame(-1, g); return .handled
        case "l": moveFrame(1, g);  return .handled
        case " ":
            loupeOpen = false; previewID = nil; return .handled
        case "x", "X":
            handleRejectKey(g, modifiers: kp.modifiers); return .handled
        default: return .ignored
        }
    }

    /// Shared reject-key logic for grid and loupe.
    /// Plain X/⌫: toggle reject. Protected → show inline hint instead.
    /// ⇧X: force-reject a protected frame → show confirmation alert.
    private func handleRejectKey(_ g: ReviewGroup, modifiers: EventModifiers) {
        guard let f = focusedFrame else { return }
        let isShift = modifiers.contains(.shift)
        if isShift {
            // ⇧X path: force-reject (may target a protected frame).
            if let p = g.photos.first(where: { $0.uuid == f }), p.isProtected {
                forceRejectTarget = (groupID: g.id, frameID: f)
                showForceRejectAlert = true
            } else {
                // Not protected — behaves same as plain X.
                model.toggleReject(group: g.id, frameID: f)
            }
        } else {
            // Plain X: toggle reject, but block on protected frames.
            let toggled = model.toggleReject(group: g.id, frameID: f)
            if !toggled {
                // Show inline hint.
                protectedHintFrame = f
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if protectedHintFrame == f { protectedHintFrame = nil }
                }
            }
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
            GroupReview(group: g, model: model, t: t,
                        focusedFrame: gridFocused ? focusedFrame : nil,
                        isExactDupeGroup: model.exactDupeGroupIDs.contains(g.id),
                        protectedHintFrame: protectedHintFrame)
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
                Text("v\(appVersion)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.reefTextDim.opacity(0.6))
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

    // MARK: scope bar (media type + source picker)

    /// The persistent bar atop the detail pane. Two controls side by side:
    ///   • Segmented tab — Photos only vs. Photos + Videos (applies to next scan)
    ///   • Source menu — Whole Library or a specific album
    /// Both are disabled while a scan is running.
    private var scopeBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.includeVideo) {
                Text(t.scopePhotosOnly()).tag(false)
                Text(t.scopeWithVideo()).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isScanning)
            .frame(maxWidth: 260)

            sourceMenu
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.reefBorder), alignment: .bottom)
    }

    /// A compact menu that lets the user pick "Whole Library" or a specific album.
    /// Albums are loaded once when access is granted; the list is sorted A→Z.
    private var sourceMenu: some View {
        Menu {
            // Whole-library option at the top, always visible.
            Button {
                model.scanSource = .wholeLibrary
            } label: {
                if case .wholeLibrary = model.scanSource {
                    Label(t.sourceWholeLibrary(), systemImage: "checkmark")
                } else {
                    Text(t.sourceWholeLibrary())
                }
            }

            if !model.albums.isEmpty {
                Divider()
                ForEach(model.albums) { album in
                    Button {
                        model.scanSource = .album(album)
                    } label: {
                        if case .album(let current) = model.scanSource, current.id == album.id {
                            Label(albumMenuLabel(album), systemImage: "checkmark")
                        } else {
                            Text(albumMenuLabel(album))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.stack")
                    .font(.caption)
                Text(sourceMenuTitle)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.reefMint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.reefDeep.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.reefBorder, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(model.isScanning)
        .help(t.sourcePickerLabel())
    }

    private var sourceMenuTitle: String {
        switch model.scanSource {
        case .wholeLibrary: return t.sourceWholeLibrary()
        case .album(let a): return a.title
        }
    }

    private func albumMenuLabel(_ album: AlbumItem) -> String {
        if album.estimatedCount >= 0 {
            return "\(album.title)  (\(album.estimatedCount))"
        }
        return album.title
    }

    // MARK: status bar (reclaim summary)

    /// Build version pulled from CFBundleShortVersionString at runtime — single
    /// source of truth is Info.plist; no literal that can drift.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

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
            Text("snapsift v\(appVersion)")
                .foregroundStyle(Color.reefTextDim.opacity(0.55))
            // FIX 3: always-visible commit button in the status bar.
            // The toolbar Delete button is the last of ~6 primaryAction items and
            // collapses into the » overflow on narrow windows, making it
            // unreachable. This button is ALWAYS visible and calls the same
            // runDelete() so the user can always commit their marked deletions.
            if model.totalDeletions > 0 {
                Button(role: .destructive) {
                    Task { await runDelete() }
                } label: {
                    Label(t.statusBarDeleteN(model.totalDeletions), systemImage: "trash.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.reefRed)
                .disabled(deleting)
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.reefBorder), alignment: .top)
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
            Button { Task { await runWriteAlbums() } } label: {
                Label(t.sortIntoAlbums(), systemImage: "rectangle.stack.badge.plus")
            }
            .help(t.tipSortIntoAlbums())
            .disabled(model.groups.isEmpty || model.isWritingAlbums || writingAlbums || model.isScanning)
            .keyboardShortcut("5", modifiers: .command)
        }
        // FIX 3: The toolbar Delete button stays for discoverability, but the
        // keyboard shortcut moves to the always-visible status-bar button so it
        // never disappears in » overflow. The toolbar button is a secondary path.
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) { Task { await runDelete() } } label: {
                Label(t.deleteN(model.totalDeletions), systemImage: "trash")
            }
            .tint(.reefRed)
            .disabled(model.totalDeletions == 0 || deleting)
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

    private func runWriteAlbums() async {
        writingAlbums = true
        defer { writingAlbums = false }
        do {
            let msg = try await model.writeAlbums(t)
            showBanner(msg)
        } catch {
            showBanner(error.localizedDescription)
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
            // FIX 2: failed delete must be LOUD and actionable, not a silent 3s banner.
            // A destructive action that fails invisibly breaks trust completely.
            // Show a persistent, dismissible alert with a direct fix path.
            deleteErrorAlert = true
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
    /// True when the parent confirmed this group as an exact-duplicate cluster.
    var isExactDupeGroup: Bool = false
    /// Frame currently showing the "protected — ⇧X to force" hint (from keyboard handler).
    var protectedHintFrame: String? = nil

    // FIX C: confirmation alert state for including protected frames in deletion.
    @State private var showDeleteProtectedAlert = false

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
                    // FIX C: "Include protected" toggle — only shown when the group
                    // has protected frames AND is armed (deleteAll). Hidden otherwise
                    // so it doesn't clutter groups that have no protected content.
                    if group.deleteAll && group.protectedCount > 0 {
                        if group.includeProtected {
                            // Toggling OFF clears the override immediately — no confirm needed.
                            Button {
                                model.setIncludeProtected(group: group.id, value: false)
                            } label: {
                                Label(t.includingProtected(group.protectedCount),
                                      systemImage: "lock.open.fill")
                            }
                            .buttonStyle(.bordered)
                            .tint(.reefAmber)
                            .help(t.tipIncludeProtected())
                        } else {
                            // Toggling ON shows a confirmation alert before taking effect.
                            Button {
                                showDeleteProtectedAlert = true
                            } label: {
                                Label(t.includeProtected(group.protectedCount),
                                      systemImage: "lock.open")
                            }
                            .buttonStyle(.bordered)
                            .tint(Color.reefTextDim)
                            .help(t.tipIncludeProtected())
                        }
                    }
                    // FIX 4: distinguish "armed with actual deletions" from
                    // "armed but all frames are protected → nothing will be deleted".
                    // The all-protected case must NOT show a solid-red "Deleting all"
                    // label — that implies a delete will happen, which it won't.
                    // Use amber + a distinct "All protected" label instead so the
                    // visual state truthfully reflects what will happen.
                    if group.deleteAll && group.deletionIDs.isEmpty {
                        // Armed but all-protected: show a non-red "all protected" pill.
                        Label(t.deleteAllProtected(), systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(Color.reefAmber)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.reefAmber.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.reefAmber.opacity(0.4), lineWidth: 1)
                            )
                            .help(t.tipDeleteAllProtected())
                            .onTapGesture { model.toggleDeleteAll(group: group.id) }
                    } else {
                        Button { model.toggleDeleteAll(group: group.id) } label: {
                            Label(group.deleteAll ? t.deletingAll() : t.deleteAll(),
                                  systemImage: group.deleteAll ? "trash.fill" : "trash")
                        }
                        .buttonStyle(.bordered)
                        .tint(group.deleteAll ? .reefRed : .reefTeal)
                        .help(t.tipDeleteAll())
                    }
                    Button { model.keepAll(group: group.id) } label: {
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
        // FIX C: confirmation alert before protected frames enter the deletion set.
        // The model is only updated when the user explicitly confirms — Cancel is a
        // full no-op so accidentally tapping "Include protected" is reversible.
        .alert(t.deleteProtectedAlertTitle(), isPresented: $showDeleteProtectedAlert) {
            Button(t.deleteProtectedAlertConfirm(), role: .destructive) {
                model.setIncludeProtected(group: group.id, value: true)
            }
            Button(t.deleteProtectedAlertCancel(), role: .cancel) { }
        } message: {
            Text(t.deleteProtectedAlertBody(group.protectedCount))
        }
    }

    private func card(for p: Photo, index: Int) -> some View {
        let keep = group.isKeeper(p)
        let del = group.isDelete(p)
        let focused = p.uuid == focusedFrame
        // An exact-dup non-keeper earns the teal "safe to remove" badge ONLY when
        // the group passed the strict predicate (dHash 0 + feature ≈0 + same size).
        // Protected frames stay amber regardless — they are never auto-deletable.
        // FIX D: exact-dup suggestions now use TEAL (reefTeal) not amber, to avoid
        // the color collision where "protected" and "interchangeable safe copy" both
        // showed amber despite having opposite meanings.
        let isExactSuggested = isExactDupeGroup && !keep && !p.isProtected
        // Protected frames (favorite / edited / document) are never auto-deletable
        // — show them amber + lock/reason badges, never red.
        let border: Color = keep ? .reefGreen
            : (p.isProtected ? .reefAmber
            : (isExactSuggested ? Color.reefTeal   // FIX D: teal = "safe to remove", not amber
            : (del ? .reefRed : .clear)))
        // Exact-dup non-keepers dim just like regular delete candidates.
        let dimmed = del || isExactSuggested
        return VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                AssetThumbnail(asset: model.asset(for: p.uuid), manager: model.imageManager, side: 160)
                    .opacity(dimmed ? 0.34 : 1)
                badge(p: p, keep: keep, del: del, exactSuggested: isExactSuggested)
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
        .overlay(alignment: .bottom) {
            if protectedHintFrame == p.uuid {
                Text(t.protectedHint())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.reefAmber.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.promote(group: group.id, to: p.uuid) }
        .help(
            p.isProtected && isExactDupeGroup ? t.tipExactDupeProtected()
            : p.isProtected ? t.tipProtectedFrame()
            : isExactSuggested ? t.tipExactDupe()
            : keep ? t.tipKeeper()
            : t.tipDelete()
        )
    }

    /// Badge row for a single frame card.
    ///
    /// FIX A: protected frames show individual reason badges so the user always
    ///        knows exactly WHY a frame won't be deleted:
    ///          ★   = favorite
    ///          ✎   = edited (user applied adjustments)
    ///          doc = document / scan / receipt / ID
    ///        A frame can have multiple reasons (e.g. a favorited edited photo
    ///        shows both ★ and ✎). The shared amber badge color + tooltip
    ///        makes it clear these are all "protected" states.
    ///
    /// FIX D: exact-dup "safe to remove" badge moves from amber to TEAL so it is
    ///        never confused with the amber protection badges.
    private func badge(p: Photo, keep: Bool, del: Bool, exactSuggested: Bool) -> some View {
        HStack(spacing: 4) {
            if keep { tag(t.keep(), .reefGreen, Color(hex: 0x04110a)) }
            // FIX D: exact-dup badge is now teal, not amber — "safe to remove" ≠ "protected".
            if exactSuggested { tag(t.exactDupeBadge(), .reefTeal, Color(hex: 0x04181a)) }
            else if del { tag(t.delete(), .reefRed, .white) }
            // FIX A: per-reason protection badges (amber, consistent with the border).
            // Show each applicable badge independently so the reason is never guessed.
            if p.favorite  { tag("★",       .reefAmber, Color(hex: 0x1a1203)) }
            if p.edited    { tag("✎",       .reefAmber, Color(hex: 0x1a1203)) }
            if p.isDocument { tag("doc",    .reefAmber, Color(hex: 0x1a1203)) }
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

/// Full-screen loupe overlay with position HUD, nav, and frame-action keys.
/// Space / Esc close it; ←→ / h l navigate; X/⌫/⏎/⇧X judge from here.
struct LoupeOverlay: View {
    let group: ReviewGroup
    let currentID: String
    @ObservedObject var model: LibraryModel
    let t: L10n
    let onClose: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void

    private var currentIndex: Int {
        group.photos.firstIndex { $0.uuid == currentID } ?? 0
    }
    private var currentPhoto: Photo? {
        group.photos.first { $0.uuid == currentID }
    }

    var body: some View {
        ZStack {
            // Dim background.
            Color.black.opacity(0.88)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            // Photo.
            if let asset = model.asset(for: currentID) {
                BigPreview(asset: asset, manager: model.imageManager, t: t, onClose: onClose)
            } else {
                ProgressView().tint(.white)
            }

            // Top-left HUD: "<i> / <n> · <filename> · <status>"
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(hudText)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 14).padding(.leading, 14)
                    Spacer()
                    // Close button.
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 14).padding(.trailing, 14)
                }
                Spacer()
            }
        }
    }

    /// "<i> / <n> · <filename> · <status>" — always legible.
    private var hudText: String {
        let i = currentIndex + 1
        let n = group.photos.count
        let fname = currentPhoto.map { p in
            p.filename.isEmpty ? String(p.uuid.prefix(8)) : p.filename
        } ?? "?"
        var parts: [String] = []
        if let p = currentPhoto {
            if p.uuid == group.keeperID && !group.rejected.contains(p.uuid) { parts.append("★ keeper") }
            else if group.isDelete(p) { parts.append("✕ reject") }
            if p.favorite   { parts.append("★ fav") }
            if p.edited     { parts.append("✎ edited") }
            if p.isDocument { parts.append("doc") }
        }
        let status = parts.isEmpty ? "no decision" : parts.joined(separator: " · ")
        return "\(i) / \(n)  ·  \(fname)  ·  \(status)"
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
