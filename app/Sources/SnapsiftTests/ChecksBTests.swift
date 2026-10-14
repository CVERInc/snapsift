import Foundation
import SnapsiftCore

// Check round 2026-10-11, part b (PR #8), restacked onto the shared Photos
// session and Folder Mode: the whole review works by pointer and by
// VoiceOver, and the sidebar's pane dimming stays readable. Only the UI half
// of #8 is here; its album ledger is not part of this branch.
//
// The views themselves cannot be imported by this runner, so what is pinned is
// the Core rules both modes' cards call (`cardRejectVerb`, `cardVerbIsReadOnly`,
// `cardSpokenState`, `cardControlsHittable`, `PaneDim`) and the words the
// cards, buttons and announcements say (L10n is compiled into this target).

@MainActor
func checkChecksB() async {
    print("checks-b (d): the pointer's cross-out is the keys' X / ⇧X, chosen from state")
    do {
        let table: [(Bool, Bool, Bool, CardRejectVerb)] = [
            // marked, protected, unverifiable
            (false, false, false, .crossOut),
            (false, true,  false, .crossOutProtected),
            (false, false, true,  .explainUnverifiable),
            (false, true,  true,  .explainUnverifiable),
            (true,  false, false, .undoCrossOut),
            (true,  true,  false, .undoCrossOut),
            (true,  false, true,  .undoCrossOut),
            (true,  true,  true,  .undoCrossOut),
        ]
        for (marked, prot, unver, want) in table {
            check(cardRejectVerb(isMarked: marked, isProtected: prot, isUnverifiable: unver) == want,
                  "marked=\(marked) protected=\(prot) unverifiable=\(unver) ⇒ \(want)")
        }
        for marked in [true, false] { for prot in [true, false] { for unver in [true, false] {
            let v = cardRejectVerb(isMarked: marked, isProtected: prot, isUnverifiable: unver)
            if prot || unver {
                check(!v.marksImmediately,
                      "a protected/unverifiable card (marked=\(marked) p=\(prot) u=\(unver)) is never marked by one click")
            }
            if unver { check(!v.usesShift, "an unverifiable card (marked=\(marked) p=\(prot)) never reaches the ⇧X override") }
        } } }
        check(cardVerbIsReadOnly(.focus) && cardVerbIsReadOnly(.preview),
              "a click (focus) and a double-click (preview) change nothing")
        check(!cardVerbIsReadOnly(.keep) && !cardVerbIsReadOnly(.reject) && !cardVerbIsReadOnly(.keepOnly),
              "keep / cross out / keep only are the only card verbs that mutate")
    }

    print("checks-b (d1): the card's ⇧X choice matches Folder Mode's own ⇧X gate")
    do {
        // FolderContentView's key handler asks for the confirmation when
        // `shift && isProtected && !isUnverifiable && !marked`. The card sends
        // ⇧X exactly when Core says `.crossOutProtected`; the two must agree
        // on every state, or the pointer would skip (or invent) a confirmation.
        for marked in [true, false] { for prot in [true, false] { for unver in [true, false] {
            let folderAsks = prot && !unver && !marked
            let cardAsks = cardRejectVerb(isMarked: marked, isProtected: prot, isUnverifiable: unver).usesShift
            check(folderAsks == cardAsks,
                  "marked=\(marked) protected=\(prot) unverifiable=\(unver): card ⇧X ⇔ Folder confirmation")
        } } }
    }

    print("checks-b (e): what a card says about itself")
    do {
        let table: [(Bool, Bool, Bool, Bool, CardSpokenState)] = [
            // keeper, delete, protected, unverifiable
            (true,  false, false, false, .willKeep),
            (true,  false, true,  true,  .willKeep),
            (false, true,  false, false, .willDelete),
            (false, true,  true,  false, .willDelete),      // ⇧X-confirmed favourite
            (false, false, false, true,  .pleaseConfirm),
            (false, false, true,  true,  .pleaseConfirm),
            (false, false, true,  false, .protected),
            (false, false, false, false, .undecided),
        ]
        for (keep, del, prot, unver, want) in table {
            check(cardSpokenState(isKeeper: keep, isDelete: del, isProtected: prot, isUnverifiable: unver) == want,
                  "keeper=\(keep) delete=\(del) protected=\(prot) unverifiable=\(unver) ⇒ \(want)")
        }
        for keep in [true, false] { for del in [true, false] { for prot in [true, false] {
            check(cardSpokenState(isKeeper: keep, isDelete: del, isProtected: prot, isUnverifiable: true) != .undecided,
                  "unclassifiable (keeper=\(keep) delete=\(del) protected=\(prot)) is never announced as 'no decision'")
        } } }
    }

    print("checks-b (f): dimmed sidebar rows stay readable")
    do {
        // Signet ReefTheme tokens (packages/native/Sources/Signet/Themes/ReefTheme.swift):
        let reefDeep = RGB(hex: 0x052f30)       // sidebar colour
        let reefText = RGB(hex: 0xe6f4f3)       // caption = reefTextDim = this at 0.62
        let reefMint = RGB(hex: 0xaceace)       // row title
        let textDimAlpha = 0.62
        // The value is a PROPOSAL (see `PaneDim.proposal`); what is pinned here
        // is the floor any value must clear, and the Increase Contrast rule.
        let dim = PaneDim.sidebarRowOpacity(contentActive: true, selected: false, increaseContrast: false)
        let caption = contrastRatio(reefText, alpha: textDimAlpha * dim, over: reefDeep)
        let title = contrastRatio(reefMint, alpha: dim, over: reefDeep)
        print(String(format: "    caption %.2f:1, title %.2f:1 at row opacity %.2f", caption, title, dim))
        check(caption >= 4.5, "dimmed caption ≥ 4.5:1 on the sidebar colour")
        check(title >= 4.5, "dimmed title ≥ 4.5:1 on the sidebar colour")
        // Control: the ruler reproduces the audit's numbers for the old 0.35.
        let oldCaption = contrastRatio(reefText, alpha: textDimAlpha * 0.35, over: reefDeep)
        let oldTitle = contrastRatio(reefMint, alpha: 0.35, over: reefDeep)
        print(String(format: "    (old 0.35: caption %.2f:1, title %.2f:1)", oldCaption, oldTitle))
        check(abs(oldCaption - 1.89) < 0.02 && abs(oldTitle - 2.58) < 0.02,
              "the same ruler gives the audit's 1.89 / 2.58 for the old 0.35")
        check(oldCaption < 4.5, "control: the old 0.35 fails the floor this ruler enforces")
        check(abs(contrastRatio(RGB(255, 255, 255), over: RGB(0, 0, 0)) - 21) < 0.001, "white on black = 21:1")
        for active in [true, false] { for sel in [true, false] {
            check(PaneDim.sidebarRowOpacity(contentActive: active, selected: sel, increaseContrast: true) == 1,
                  "Increase Contrast: no dimming (active=\(active) selected=\(sel))")
        } }
        check(PaneDim.sidebarRowOpacity(contentActive: true, selected: true, increaseContrast: false) == 1
                && PaneDim.sidebarRowOpacity(contentActive: false, selected: false, increaseContrast: false) == 1,
              "a selected row, and any row while the sidebar is active, never dims")
        check(PaneDim.proposal.selectedRowOutlineWidth > 0,
              "the selected row has an outline to turn into while the content pane is active")
    }

    print("checks-b (d2): a double-click never lands on a button the first click summoned")
    do {
        let table: [(Bool, Double, Double, Double, Bool)] = [
            // focused, age since focus, age since hover, double-click interval ⇒ hittable
            (true,  0.0,  9.0,  0.5, false),  // just focused: a long hover does not arm it
            (true,  0.49, 0.0,  0.5, false),
            (true,  0.5,  0.0,  0.5, true),
            (true,  2.0,  0.0,  0.5, true),
            (false, 0.0,  0.0,  0.5, false),  // pointer just arrived at the corner
            (false, 0.0,  0.49, 0.5, false),
            (false, 0.0,  0.5,  0.5, true),   // hovered long enough: visible before the click
            (true,  0.3,  0.0,  0.35, false), // the iOS window
            (true,  0.35, 0.0,  0.35, true),
        ]
        for (focused, age, hover, interval, want) in table {
            check(cardControlsHittable(isFocused: focused, focusAge: age, hoverAge: hover,
                                       doubleClickInterval: interval) == want,
                  "focused=\(focused) focusAge=\(age) hoverAge=\(hover) interval=\(interval) ⇒ \(want ? "live" : "inert")")
        }
    }

    print("checks-b (g): the words a click, a card and an announcement say")
    do {
        let clickWords = ["click", "Click", "クリック", "按一下"]
        for language in Language.allCases {
            let t = L10n(language)
            let tag = language.rawValue
            // A click only focuses now; no tooltip may promise it keeps.
            for (name, s) in [("tipDelete", t.tipDelete()), ("folderMarkedTip", t.folderMarkedTip())] {
                check(!clickWords.contains { s.contains($0) }, "\(tag): \(name) no longer says a click keeps it")
            }
            check(!t.keepOnlyUndone().contains("⇧K"),
                  "\(tag): the keep-only undo banner names no key (the context menu reaches it too)")
            // The destructive buttons' spoken labels start with the visible title.
            check(t.preCommitConfirmSpoken(3).hasPrefix(t.preCommitConfirm()) && t.preCommitConfirmSpoken(3).contains("30"),
                  "\(tag): Photos confirm is spoken as its visible title, then the count and the 30 days")
            check(t.folderPreCommitConfirmSpoken(3).hasPrefix(t.folderMoveToTrash())
                    && !t.folderPreCommitConfirmSpoken(3).contains("⌘"),
                  "\(tag): Folder confirm is spoken as its visible title, without the ⌘⏎ glyphs")
            // Photos announcements carry the destination and the 30 days;
            // Folder ones must not claim Recently Deleted (a mark moves nothing).
            let photos = [t.annCrossedOut(1, of: 4), t.annCrossOutUndone(0, of: 4),
                          t.annKeeping(2, 3, of: 4), t.annKeepOnly(2, 3, of: 4),
                          t.annSetChanged(3, of: 4), t.a11yWillDelete("x")]
            let folder = [t.annCrossedOut(1, of: 4, folder: true), t.annCrossOutUndone(0, of: 4, folder: true),
                          t.annKeeping(2, 3, of: 4, folder: true), t.annKeepOnly(2, 3, of: 4, folder: true),
                          t.annSetChanged(3, of: 4, folder: true), t.a11yFolderMarked("x")]
            check(photos.allSatisfy { $0.contains("30") }, "\(tag): every Photos announcement says 30 days")
            check(folder.allSatisfy { !$0.contains("30") && !$0.contains("Recently") && !$0.contains("最近") },
                  "\(tag): no Folder announcement or label claims Recently Deleted")
            // The unclassifiable card never says "no decision".
            check(t.a11yPleaseConfirm("r") != t.a11yUndecided() && !t.a11yPleaseConfirm("r").contains(t.a11yUndecided()),
                  "\(tag): 'please confirm' is not 'no decision'")
        }
    }
}
