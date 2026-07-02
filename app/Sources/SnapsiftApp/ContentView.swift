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
    // Album-write failure: persistent alert (same stance as delete failure —
    // a mutation of the user's library must never fail as a vanishing banner).
    @State private var albumErrorMessage: String?
    // Pass 2b: save-rotation state
    @State private var saveRotationErrorAlert = false
    // Feature 1: pre-commit review sheet
    /// The pre-commit sheet's entire payload, built atomically in runDelete().
    /// Presented via .sheet(item:) — with isPresented + separate @State the
    /// sheet closure can capture the PREVIOUS tick's (empty) data and show
    /// "delete 0 photos" over an empty list (observed live).
    struct PreCommitPayload: Identifiable {
        let id = UUID()
        let groups: [PreCommitGroup]
        let deletions: Int
        let bytes: Int
        let protectedCount: Int
        let noSurvivor: Int
    }
    @State private var preCommitPayload: PreCommitPayload?
    // Feature 4: deletion history sheet
    @State private var showHistorySheet = false
    // FIX 3 (safety hardening): stale-asset warning alert state.
    // Populated when some IDs can no longer be resolved at delete time.
    @State private var staleAlertData: (staleCount: Int, foundCount: Int)?
    // Continuation used to return the user's choice from the stale-asset alert
    // back to the async performDelete() that's waiting on it.
    @State private var staleAlertContinuation: CheckedContinuation<Bool, Never>?
    // Dead-focus rescue (see installFocusRescue): local keyDown monitor token.
    @State private var keyMonitor: Any?

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
        .desktopMinimumFrame()   // macOS-only 820×560 floor; iPhone sizes itself
        .background(Color.reefGround)
        .preferredColorScheme(.dark)
        .tint(.reefTeal)
        // Pass 2b: save-rotation confirmation alert.
        // Anchored at the outermost level so it fires regardless of which sub-view
        // set `model.showSaveRotationConfirm = true` (grid button OR loupe button).
        .alert(t.saveRotationConfirmTitle(), isPresented: $model.showSaveRotationConfirm) {
            Button(t.saveRotationConfirmButton()) {
                if let frameID = focusedFrame {
                    Task { await model.saveRotationToPhotos(frameID: frameID) }
                }
            }
            Button(t.saveRotationCancelButton(), role: .cancel) { }
        } message: {
            Text(t.saveRotationConfirmBody())
        }
        // Pass 2b: save-rotation error alert — persistent, never silent.
        .alert(t.saveRotationErrorTitle(), isPresented: $saveRotationErrorAlert) {
            Button(t.saveRotationErrorDismiss(), role: .cancel) {
                model.saveRotationError = nil
            }
        } message: {
            if let err = model.saveRotationError {
                Text(err.localizedDescription)
            }
        }
        // Pass 2b: observe save-rotation result published values.
        .onReceive(model.$saveRotationError) { err in
            if err != nil { saveRotationErrorAlert = true }
        }
        .onChange(of: model.saveRotationSuccess) { _, success in
            if success {
                showBanner(t.saveRotationSuccessBanner())
                model.saveRotationSuccess = false
            }
        }
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
        #if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else { return }
        NSWorkspace.shared.open(url)
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }

    /// Deep-link to the Full Disk Access pane (size/quality sidecar needs it).
    /// macOS-only concept — the sidecar itself doesn't exist on iOS.
    private func openFullDiskAccessSettings() {
        #if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
        #endif
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
        // While the delete (and its system confirmation) is in flight, the
        // window must be inert: a stray keypress reaching the grid can promote
        // or un-reject frames mid-delete (verified live — a blind Return
        // cleared the pending mark). The overlay blocks the mouse; the key
        // handlers guard on `deleting` for the keyboard.
        .overlay { if deleting { deletingLock } }
        .onAppear {
            model.loadAlbums()
            installFocusRescue()
            // Reopen onto the last working state (groups + decisions) instead
            // of an empty window that demands a multi-minute rescan.
            model.restoreSnapshot(t)
        }
        // Scan-completion feedback: every scan ends with an explicit banner
        // ("found N" / "nothing found" / "album gone") so finishing is never
        // silent and an empty result is distinguishable from not having run.
        .onChange(of: model.scanNotice) { _, notice in
            if let notice {
                showBanner(notice)
                model.scanNotice = nil
            }
        }
        // Keep the grid focus in sync when the selection changes by mouse —
        // otherwise focusedFrame keeps pointing into the previously selected
        // group and arrow keys / ⇧⌘R act on a stale frame.
        .onChange(of: selection) { _, id in
            if let g = model.groups.first(where: { $0.id == id }) {
                focusedFrame = g.keeperID
            }
        }
        // Feature 1: pre-commit review sheet
        .sheet(item: $preCommitPayload) { payload in
            // All totals are precomputed once in runDelete(): recomputing them
            // in this closure re-ran O(all groups) reductions on every parent
            // render while the modal was open.
            PreCommitReviewSheet(
                groups: payload.groups,
                totalDeletions: payload.deletions,
                reclaimableBytes: payload.bytes,
                totalProtected: payload.protectedCount,
                noSurvivorCount: payload.noSurvivor,
                model: model,
                t: t,
                onConfirm: {
                    preCommitPayload = nil
                    Task { await performDelete() }
                },
                onCancel: {
                    preCommitPayload = nil
                }
            )
        }
        // Feature 4: history sheet
        .sheet(isPresented: $showHistorySheet) {
            DeletionHistoryView(t: t, onClose: { showHistorySheet = false })
        }
        // FIX 2: persistent alert when delete fails — never let a destructive
        // action fail silently. Gives the user a direct path to fix the permission.
        .alert(t.deleteErrorTitle(), isPresented: $deleteErrorAlert) {
            Button(t.deleteErrorOpenSettings()) { openPhotosPrivacySettings() }
            Button(t.deleteErrorDismiss(), role: .cancel) {}
        } message: {
            Text(t.deleteErrorBody())
        }
        // Album-write failure — persistent, same trust bar as delete failure.
        .alert(t.albumsWriteFailedTitle(), isPresented: Binding(
            get: { albumErrorMessage != nil },
            set: { if !$0 { albumErrorMessage = nil } }
        )) {
            Button(t.deleteErrorDismiss(), role: .cancel) { albumErrorMessage = nil }
        } message: {
            if let msg = albumErrorMessage { Text(msg) }
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
        // FIX 3: stale-asset warning — shown when some IDs could not be found at
        // delete time (the library changed since the scan). The user can proceed
        // with the assets that WERE found or cancel entirely.
        .alert(t.staleAssetAlertTitle(), isPresented: Binding(
            get: { staleAlertData != nil },
            set: { if !$0 { staleAlertData = nil } }
        )) {
            if let data = staleAlertData {
                Button(t.staleAssetAlertProceed(data.foundCount), role: .destructive) {
                    staleAlertData = nil
                    staleAlertContinuation?.resume(returning: true)
                    staleAlertContinuation = nil
                }
            }
            Button(t.staleAssetAlertCancel(), role: .cancel) {
                staleAlertData = nil
                staleAlertContinuation?.resume(returning: false)
                staleAlertContinuation = nil
            }
        } message: {
            if let data = staleAlertData {
                Text(t.staleAssetAlertBody(stale: data.staleCount, found: data.foundCount))
            }
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

    /// Input lock shown while a delete is committing (see the .overlay note).
    private var deletingLock: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 12) {
                ProgressView().tint(.reefMint)
                Text(t.deletingOverlay())
                    .font(.callout).foregroundStyle(Color.reefText)
            }
            .padding(24)
            .background(Color.reefDeep, in: RoundedRectangle(cornerRadius: 12))
        }
        .contentShape(Rectangle())   // swallow all mouse input underneath
    }

    /// Touch platforms open the loupe from a thumbnail tap; on the desktop this
    /// is nil so clicks keep their promote semantics.
    private var touchOpenLoupe: ((String) -> Void)? {
        #if os(iOS)
        { uuid in
            focusedFrame = uuid
            previewID = uuid
            loupeOpen = true
        }
        #else
        nil
        #endif
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

    /// Dead-focus rescue. SwiftUI's focus can end up nowhere (first responder
    /// = the NSWindow itself) after launch-path differences, TCC dialogs, or
    /// app switching — and once it does, no `.onKeyPress` handler in the
    /// window fires again and there is no mouse path that restores it
    /// (verified live: rows select but j/k/x/? are all dead). This local
    /// monitor never swallows events; it only detects the dead state and
    /// re-arms the sidebar focus, so the very next keystroke lands normally.
    private func installFocusRescue() {
        #if os(macOS)
        guard keyMonitor == nil else { return }
        // Also watch mouse-downs so a row click re-arms focus by itself and
        // the first keystroke after it is not sacrificed to the rescue.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            let fr = NSApp.keyWindow?.firstResponder
            if fr == nil || fr is NSWindow {
                if !model.groups.isEmpty || !model.categories.isEmpty {
                    sidebarFocused = true
                }
            }
            return event
        }
        #endif
        // iOS: no NSEvent, and the touch/hardware-keyboard focus model doesn't
        // exhibit the dead-window-first-responder failure this rescues.
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
        guard !deleting else { return .handled }   // input locked mid-delete
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
        guard !deleting else { return .handled }   // input locked mid-delete
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
        // FIX 3: display-only rotate. R = clockwise, ⇧R = counter-clockwise.
        // Pass 2b: ⇧⌘R (Shift+Command+R) triggers save-rotation confirm.
        case "r", "R":
            if kp.modifiers.contains(.shift) && kp.modifiers.contains(.command) {
                handleSaveRotationKey(); return .handled
            }
            handleRotateKey(modifiers: kp.modifiers); return .handled
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
        // FIX 3: display-only rotate works in the loupe too.
        // Pass 2b: ⇧⌘R in the loupe triggers save-rotation confirm.
        case "r", "R":
            if kp.modifiers.contains(.shift) && kp.modifiers.contains(.command) {
                handleSaveRotationKey(); return .handled
            }
            handleRotateKey(modifiers: kp.modifiers); return .handled
        default: return .ignored
        }
    }

    /// Pass 2b — trigger save-rotation confirmation (⇧⌘R).
    /// Only arms the confirm alert if the focused frame has a pending rotation.
    private func handleSaveRotationKey() {
        guard let f = focusedFrame, model.rotation(for: f) % 4 != 0 else { return }
        model.showSaveRotationConfirm = true
    }

    /// FIX 3 — non-destructive display rotate of the focused frame.
    /// R = 90° clockwise, ⇧R = 90° counter-clockwise. Session-only (never written
    /// back to Photos — that is the Pass 2b hook). Works in grid and loupe; the
    /// justified layout reflows because the rotated aspect is recomputed.
    private func handleRotateKey(modifiers: EventModifiers) {
        guard let f = focusedFrame else { return }
        model.rotate(frameID: f, clockwise: !modifiers.contains(.shift))
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
        .onTapGesture { categorySelection = c.id; sidebarFocused = true }
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
                // FIX 6: sidebar info badges use reefMint, not amber.
                // Amber is reserved strictly for "protected — won't delete" warnings
                // (frame borders, protection badges in the grid, the "All protected"
                // label). Informational indicators must not borrow the same colour
                // or they blur the meaning of the protection signal.
                if g.hasFavorite { Text("★").foregroundStyle(Color.reefMint) }
                if g.hasVideo { Image(systemName: "video.fill").font(.caption2).foregroundStyle(Color.reefMint) }
                if g.keepAll { Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(Color.reefGreen) }
            }
            Text(t.sidebarSubtitle(span: g.spanSec, delete: g.deletionIDs.count))
                .font(.caption)
                .foregroundStyle(sel ? Color.white.opacity(0.85) : Color.reefTextDim)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Clicking a row must also reclaim keyboard focus: once first-responder
        // is lost (relaunch, app switching), no scan-end onChange will re-arm
        // it, and without this the whole keyboard flow silently dies.
        .onTapGesture { selection = g.id; sidebarFocused = true }
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
                if let frac = model.progressFraction {
                    ProgressView(value: frac).tint(.reefMint).frame(maxWidth: 180)
                } else {
                    ProgressView().tint(.reefMint)
                }
                Text(model.progress).font(.caption).foregroundStyle(Color.reefTextDim)
                    .multilineTextAlignment(.center).padding(.horizontal)
                if model.isScanning {
                    Button(t.cancelScanButton()) { model.cancelScan() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                }
            } else {
                Image(systemName: model.hasScanned ? "checkmark.circle" : "rectangle.stack.badge.minus")
                    .font(.system(size: 34)).foregroundStyle(Color.reefBorder)
                Text(model.hasScanned ? t.scannedEmptyHint() : t.scanHint())
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
                        protectedHintFrame: protectedHintFrame,
                        onOpenLoupe: touchOpenLoupe)
                .focusable()
                .focused($gridFocused)
                .onKeyPress { handleGridKey($0) }
                // Belt-and-braces Esc: macOS may deliver Esc as the cancel
                // COMMAND rather than a key press depending on input source,
                // so route the exit command explicitly alongside onKeyPress.
                .onExitCommand {
                    if loupeOpen { loupeOpen = false; previewID = nil }
                    else { sidebarFocused = true }
                }
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
                        model.startScan(.burst, t)
                    }
                    onboardCard(title: t.lookAlikes(), icon: "rectangle.on.rectangle",
                                caption: t.tipLookAlikes(), prominent: false) {
                        model.startScan(.lookAlikes, t)
                    }
                    onboardCard(title: t.similarSets(), icon: "square.grid.3x3.topleft.filled",
                                caption: t.tipSimilarSets(), prominent: false) {
                        model.startScan(.similarSets, t)
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
            } else if model.hasScanned {
                // The missing "X MB freed" estimate must be explained, not
                // silently absent: without Full Disk Access the sidecar (quality
                // scores + real file sizes) can't be read.
                Button { openFullDiskAccessSettings() } label: {
                    Label(t.fdaHint(), systemImage: "internaldrive.badge.questionmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.reefTextDim)
                .help(t.fdaHintHelp())
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
        #if os(iOS)
        // iPhone nav bars fit ~3 items — the six desktop actions collapse into
        // one menu. Every action stays reachable; hardware keyboards still get
        // the ⌘-shortcuts via the shared handlers.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { model.startScan(.burst, t) } label: {
                    Label(t.scan(), systemImage: "sparkle.magnifyingglass")
                }.disabled(model.isScanning)
                Button { model.startScan(.lookAlikes, t) } label: {
                    Label(t.lookAlikes(), systemImage: "rectangle.on.rectangle")
                }.disabled(model.isScanning)
                Button { model.startScan(.similarSets, t) } label: {
                    Label(t.similarSets(), systemImage: "square.grid.3x3.topleft.filled")
                }.disabled(model.isScanning)
                Divider()
                Button { Task { await model.refineWithFaces(t) } } label: {
                    Label(t.faces(model.facesApplied), systemImage: "face.smiling")
                }.disabled(model.groups.isEmpty || model.refiningFaces || model.isScanning)
                Button { Task { await runWriteAlbums() } } label: {
                    Label(t.sortIntoAlbums(), systemImage: "rectangle.stack.badge.plus")
                }.disabled(model.groups.isEmpty || model.isWritingAlbums || writingAlbums || model.isScanning)
                Divider()
                Button { showHistorySheet = true } label: {
                    Label(t.historyTitle(), systemImage: "clock.arrow.circlepath")
                }
            } label: {
                Image(systemName: "sparkle.magnifyingglass")
            }
        }
        ToolbarItem { languageMenu }
        #else
        ToolbarItem(placement: .primaryAction) {
            Button { model.startScan(.burst, t) } label: {
                Label(t.scan(), systemImage: "sparkle.magnifyingglass")
            }
            .help(t.tipScan())
            .disabled(model.isScanning)
            .keyboardShortcut("1", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.startScan(.lookAlikes, t) } label: {
                Label(t.lookAlikes(), systemImage: "rectangle.on.rectangle")
            }
            .help(t.tipLookAlikes())
            .disabled(model.isScanning)
            .keyboardShortcut("2", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.startScan(.similarSets, t) } label: {
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
        // Feature 4: history toolbar button
        ToolbarItem {
            Button { showHistorySheet = true } label: {
                Label(t.historyTitle(), systemImage: "clock.arrow.circlepath")
            }
            .help(t.historyTitle())
        }
        ToolbarItem {
            Button { toggleHelp() } label: {
                Image(systemName: "questionmark.circle")
            }
            .help(t.helpTitle())
            .keyboardShortcut("?", modifiers: .command)
        }
        ToolbarItem { languageMenu }
        #endif
    }

    private func runWriteAlbums() async {
        writingAlbums = true
        defer { writingAlbums = false }
        do {
            let msg = try await model.writeAlbums(t)
            showBanner(msg)
        } catch {
            albumErrorMessage = error.localizedDescription
        }
    }

    /// Step 1: build the pre-commit data and show the review sheet.
    /// The actual PHPhotoLibrary delete only happens after the user confirms.
    private func runDelete() async {
        guard model.totalDeletions > 0 else { return }
        // Build PreCommitGroup snapshots from current group state.
        let pendingGroups = model.groups.compactMap { g -> PreCommitGroup? in
            let toRemove = g.photos.filter { g.isDelete($0) }
            guard !toRemove.isEmpty else { return nil }
            // keeper == nil is the no-survivor case (user force-rejected every
            // frame). Such groups MUST still appear in the sheet — dropping
            // them here would delete photos the confirmation never displayed.
            let keeper = g.photos.first(where: { g.isKeeper($0) })
            let why = keeperReason(photos: g.photos, keeperID: g.keeperID)
            return PreCommitGroup(
                id: g.id,
                keeper: keeper,
                keeperReason: why,
                toRemove: toRemove,
                includeProtected: g.includeProtected
            )
        }
        preCommitPayload = PreCommitPayload(
            groups: pendingGroups,
            deletions: model.totalDeletions,
            bytes: model.reclaimableBytes,
            protectedCount: pendingGroups.reduce(0) { $0 + $1.toRemove.filter(\.isProtected).count },
            noSurvivor: noSurvivorCountForCurrentGroups()
        )
    }

    /// Step 2: the actual delete — called only after the user confirmed the sheet.
    private func performDelete() async {
        deleting = true
        defer { deleting = false }
        do {
            let n = try await model.deleteReviewed { [self] staleCount, foundCount in
                // FIX 3: stale-asset warning — suspend until the user responds.
                // We surface an alert, then resume via CheckedContinuation.
                return await withCheckedContinuation { cont in
                    staleAlertData = (staleCount: staleCount, foundCount: foundCount)
                    staleAlertContinuation = cont
                }
            }
            if !model.groups.contains(where: { $0.id == selection }) { selection = nil }
            // FIX 5: success banner explicitly states the 30-day recovery window
            // (mirrors the pre-commit sheet language — same promise, same place).
            if n > 0 { showBanner(t.deletedBanner(n)) }
        } catch {
            // Cancelling macOS's own delete-confirmation sheet is a normal user
            // decision, not a failure — it must never trigger the scary
            // "delete failed, open Settings" alert.
            if let ph = error as? PHPhotosError, ph.code == .userCancelled { return }
            // FIX 2: failed delete must be LOUD and actionable, not a silent 3s banner.
            // A destructive action that fails invisibly breaks trust completely.
            // Show a persistent, dismissible alert with a direct fix path.
            deleteErrorAlert = true
        }
    }

    /// Compute no-survivor group count for the current model state.
    private func noSurvivorCountForCurrentGroups() -> Int {
        let inputs = model.groups.map { g in
            (photos: g.photos, rejected: g.rejected, includeProtected: g.includeProtected)
        }
        return noSurvivorGroupCount(inputs)
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
    /// Touch platforms: tapping a thumbnail opens the loupe here instead of
    /// promoting (the desktop click behaviour) — set by ContentView on iOS.
    var onOpenLoupe: ((String) -> Void)? = nil

    // FIX C: confirmation alert state for including protected frames in deletion.
    @State private var showDeleteProtectedAlert = false

    // Pass 2a (FIX 2): measured content width for the justified-rows layout.
    @State private var contentWidth: CGFloat = 0

    /// Horizontal gap between frames in a row (and vertical gap between rows).
    private let gallerySpacing: CGFloat = 8

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
                    // Pass 2b: Save Rotation — visible only when the focused frame
                    // has a pending display rotation. Tapping arms the confirmation
                    // alert; ⇧⌘R is the keyboard path (handled via onKeyPress above).
                    saveRotationButton
                }
                // Pass 2a (FIX 2): aspect-true JUSTIFIED-ROWS gallery (Photos.app /
                // Lightroom pattern) replaces the square-crop LazyVGrid. Frames keep
                // their real shape; the pure JustifiedLayout helper packs them into
                // rows that fill the width. Width is captured via a background reader
                // so the row math reflows on window resize.
                justifiedGallery
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

    // MARK: - Pass 2b — Save Rotation button

    /// "Save Rotation" affordance: visible only when the focused frame has a
    /// pending display rotation. Tapping sets model.showSaveRotationConfirm = true;
    /// the actual confirmation alert is anchored at the top-level ContentView.
    @ViewBuilder private var saveRotationButton: some View {
        if let focused = focusedFrame, model.rotation(for: focused) % 4 != 0 {
            Button { model.showSaveRotationConfirm = true } label: {
                Label(t.saveRotationButton(), systemImage: "arrow.clockwise.circle.fill")
            }
            .buttonStyle(.bordered)
            .tint(.reefMint)
            .help(t.tipSaveRotation())
            .keyboardShortcut("r", modifiers: [.shift, .command])
        }
    }

    // MARK: - Pass 2a — justified-rows gallery (FIX 2)

    /// Nominal row height, responsive to window width: a bit shorter on a slim
    /// pane, taller on a wide one, clamped to a sensible band.
    private var targetRowHeight: CGFloat {
        let w = contentWidth
        guard w > 0 else { return 200 }
        // ~200pt baseline; scale gently with width so wide windows breathe.
        return min(260, max(150, w / 4.2))
    }

    /// The aspect-true gallery: pure JustifiedLayout math packs frames (using
    /// each frame's orientation- + rotation-corrected aspect) into rows that fill
    /// the measured content width; the trailing row keeps the target height. The
    /// focus highlight, keeper/reject/protected borders, reason badges, keyboard
    /// focus model and click-to-focus are all preserved per card.
    private var justifiedGallery: some View {
        let aspects = group.photos.map { model.displayAspect(for: $0) }
        let rows = JustifiedLayout.rows(
            aspectRatios: aspects,
            containerWidth: Double(contentWidth),
            targetHeight: Double(targetRowHeight),
            spacing: Double(gallerySpacing)
        )
        return VStack(alignment: .leading, spacing: gallerySpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: gallerySpacing) {
                    ForEach(row.items, id: \.index) { item in
                        let p = group.photos[item.index]
                        card(for: p, index: item.index,
                             imageSize: CGSize(width: item.width, height: row.height))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Measure the available content width (already inside the .padding(16)).
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: GalleryWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(GalleryWidthKey.self) { w in
            if abs(w - contentWidth) > 0.5 { contentWidth = w }
        }
    }

    private func card(for p: Photo, index: Int, imageSize: CGSize) -> some View {
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
        return ZStack(alignment: .topLeading) {
            // True-aspect, orientation-upright, display-rotatable image (FIX 1 + 3).
            // The thumbnail self-sizes to `box` and applies rotation correctly
            // (it swaps the pre-rotation layout box internally, so an odd turn is
            // never fill-cropped against the wrong shape).
            AssetThumbnail(asset: model.asset(for: p.uuid),
                           manager: model.imageManager,
                           box: imageSize,
                           quarterTurns: model.rotation(for: p.uuid),
                           fill: true)   // fill the exact aspect-true box (no letterbox)
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
            // Filename caption overlaid on a gradient strip so the card height
            // stays equal to the row height (justified rows need uniform height).
            Text(p.filename.isEmpty ? String(p.uuid.prefix(8)) : p.filename)
                .font(.caption2).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(Color.reefText)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(colors: [.clear, Color.reefGround.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: imageSize.width, height: imageSize.height)
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
        .onTapGesture {
            // Desktop click = promote (mouse users have hover context and the
            // keeper-why tooltip). Touch tap = open the loupe — inspect first,
            // decide with swipes there; promotion happens inside the loupe.
            if let onOpenLoupe { onOpenLoupe(p.uuid) }
            else { model.promote(group: group.id, to: p.uuid) }
        }
        .help(
            p.isProtected && isExactDupeGroup ? t.tipExactDupeProtected()
            : p.isProtected ? t.tipProtectedFrame()
            : isExactSuggested ? t.tipExactDupe()
            : keep ? keeperWhyTooltip(for: p, group: group, t: t)
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
    ///
    /// Pass 2a (FIX 4): the per-frame reason badges were too small to read at tile
    /// size on the real app. They are now legible icon CHIPS — a proper SF Symbol
    /// glyph + larger type, solid high-contrast fill, a subtle shadow so they read
    /// over any photo, corner-anchored top-leading. Keeper ★ and reject ✕ get the
    /// same chip treatment so the WHY of every state is always obvious.
    private func badge(p: Photo, keep: Bool, del: Bool, exactSuggested: Bool) -> some View {
        HStack(spacing: 5) {
            if keep { chip(symbol: "checkmark", text: t.keep(), .reefGreen, Color(hex: 0x04110a)) }
            // FIX D: exact-dup badge is teal, not amber — "safe to remove" ≠ "protected".
            if exactSuggested { chip(symbol: "doc.on.doc", text: t.exactDupeBadge(), .reefTeal, Color(hex: 0x04181a)) }
            else if del { chip(symbol: "xmark", text: t.delete(), .reefRed, .white) }
            // FIX A + FIX 4: per-reason protection chips (amber) — each applicable
            // reason shown independently with an icon so it's never guessed.
            if p.favorite   { chip(symbol: "star.fill",        text: nil, .reefAmber, Color(hex: 0x1a1203)) }
            if p.edited     { chip(symbol: "slider.horizontal.3", text: nil, .reefAmber, Color(hex: 0x1a1203)) }
            if p.isDocument { chip(symbol: "doc.text.fill",    text: nil, .reefAmber, Color(hex: 0x1a1203)) }
            // FIX #4 (slice 1): iCloud-eviction indicator — document classification
            // was skipped (original not on-device); the frame is left un-marked.
            if p.documentEvalDegraded {
                chip(symbol: "icloud.slash", text: nil,
                     Color.reefTextDim.opacity(0.9), Color.reefGround)
                    .help(t.tipDocumentEvalDegraded())
            }
        }
        .padding(7)
    }

    /// A legible badge chip: SF Symbol glyph + optional label, solid fill, shadow.
    /// Sized so it stays readable even on a small justified tile.
    @ViewBuilder
    private func chip(symbol: String, text: String?, _ bg: Color, _ fg: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 11, weight: .heavy))
            if let text {
                Text(text).font(.system(size: 11, weight: .bold))
            }
        }
        .foregroundStyle(fg)
        .padding(.horizontal, text == nil ? 5 : 7)
        .padding(.vertical, 4)
        .background(bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
    }
}

/// Pass 2a (FIX 2): preference key that carries the measured content width up to
/// the gallery so the justified row-packing math can reflow on window resize.
private struct GalleryWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    // Last-writer wins: there is a single background reader, and a narrowing
    // window must be able to REDUCE the width (a `max` reducer would latch to the
    // widest value ever seen and overflow the rows).
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
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
                        // Curation grid stays square-cropped (fill) — this is a
                        // contact-sheet, not the aspect-true review gallery.
                        AssetThumbnail(asset: model.asset(for: p.uuid),
                                       manager: model.imageManager,
                                       box: CGSize(width: 130, height: 130), fill: true)
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
                BigPreview(asset: asset, manager: model.imageManager, t: t,
                           quarterTurns: model.rotation(for: currentID),
                           onClose: onClose)
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
                    // Pass 2b: Save Rotation button in loupe HUD — visible only when
                    // the current frame has a pending display rotation.
                    if model.rotation(for: currentID) % 4 != 0 {
                        Button {
                            model.showSaveRotationConfirm = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.callout)
                                Text(t.saveRotationButton())
                                    .font(.callout.weight(.semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 14)
                        .help(t.tipSaveRotation())
                    }
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
        #if os(iOS)
        // Touch gestures mirror the keyboard verbs: swipe left/right = ←/→
        // (prev/next), swipe up = X (toggle reject), swipe down = ⏎ (keep +
        // set keeper). Protected frames stay blocked exactly like plain X.
        .highPriorityGesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                if abs(dx) > abs(dy) {
                    dx > 0 ? onPrev() : onNext()
                } else if dy < 0 {
                    model.toggleReject(group: group.id, frameID: currentID)
                } else {
                    model.promote(group: group.id, to: currentID)
                }
            }
        )
        #endif
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
            if p.uuid == group.keeperID && !group.rejected.contains(p.uuid) { parts.append(t.loupeKeeper()) }
            else if group.isDelete(p) { parts.append(t.loupeReject()) }
            if p.favorite   { parts.append(t.loupeFav()) }
            if p.edited     { parts.append(t.loupeEdited()) }
            if p.isDocument { parts.append(t.loupeDoc()) }
        }
        let status = parts.isEmpty ? t.loupeNoDecision() : parts.joined(separator: " · ")
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

// MARK: - Feature 2: keeper-why tooltip helper

/// Build a tooltip for the keeper card that explains WHY this frame was chosen.
/// Calls SnapsiftCore's keeperReason() and maps to a localized label.
private func keeperWhyTooltip(for photo: Photo, group: ReviewGroup, t: L10n) -> String {
    let reason = keeperReason(photos: group.photos, keeperID: photo.uuid)
    let whyLabel: String
    switch reason {
    case .favorite:       whyLabel = t.keeperWhyFavorite()
    case .quality:        whyLabel = t.keeperWhyQuality()
    case .originalCamera: whyLabel = t.keeperWhyOriginalCamera()
    case .sharpness:      whyLabel = t.keeperWhySharpness()
    case .format:         whyLabel = t.keeperWhyFormat()
    case .size:           whyLabel = t.keeperWhySize()
    case .earliest:       whyLabel = t.keeperWhyEarliest()
    }
    return "\(t.tipKeeper()) · \(whyLabel)"
}
