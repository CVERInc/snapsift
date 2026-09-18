import Foundation
import SnapsiftCore

/// All user-facing strings, resolved for one ``Language``. Every message is an
/// exhaustive `switch`, so the compiler refuses to build until a newly added
/// language is fully translated.
struct L10n: Sendable {
    let language: Language
    init(_ language: Language) { self.language = language }

    // MARK: source picker

    /// Menu label for the whole-library option.
    func sourceWholeLibrary() -> String {
        switch language {
        case .en: return "Whole Library"
        case .ja: return "ライブラリ全体"
        case .zhTW: return "整個圖庫"
        }
    }
    /// Picker header — appears as a section title above the album list.
    func sourcePickerLabel() -> String {
        switch language {
        case .en: return "Source"
        case .ja: return "ソース"
        case .zhTW: return "來源"
        }
    }
    /// Shown when the album has no cached count yet.
    func albumCountUnknown() -> String {
        switch language {
        case .en: return "—"
        case .ja: return "—"
        case .zhTW: return "—"
        }
    }

    // MARK: chrome

    /// Scope tab: which media the scans operate on. "篩" echoes the app's name.
    func scopePhotosOnly() -> String {
        switch language {
        case .en: return "Photos only"
        case .ja: return "写真のみ"
        case .zhTW: return "只篩照片"
        }
    }
    func scopeWithVideo() -> String {
        switch language {
        case .en: return "Include videos"
        case .ja: return "動画も含める"
        case .zhTW: return "包含影片"
        }
    }
    func scan() -> String {
        switch language {
        case .en: return "Scan"
        case .ja: return "スキャン"
        case .zhTW: return "掃描"
        }
    }
    func lookAlikes() -> String {
        switch language {
        case .en: return "Look-alikes"
        case .ja: return "そっくり写真"
        case .zhTW: return "找相似"
        }
    }
    func faces(_ done: Bool) -> String {
        switch language {
        case .en: return done ? "Faces ✓" : "Faces"
        case .ja: return done ? "顔 ✓" : "顔"
        case .zhTW: return done ? "人臉 ✓" : "人臉"
        }
    }
    func deleteN(_ n: Int) -> String {
        switch language {
        case .en: return "Delete \(n)"
        case .ja: return "\(n)枚を削除"
        case .zhTW: return "刪除 \(n)"
        }
    }
    func similarSets() -> String {
        switch language {
        case .en: return "Similar sets"
        case .ja: return "テーマ別"
        case .zhTW: return "同主題"
        }
    }
    func tipSimilarSets() -> String {
        switch language {
        case .en: return "Gathers the sets where you took several shots of the same thing into named albums — nothing deleted"
        case .ja: return "同じ被写体を何枚も撮ったセットを、名前付きアルバムにまとめる（削除しない）"
        case .zhTW: return "把你對同一個東西拍了好幾張的成組，整理成有名字的相簿（不刪任何東西）"
        }
    }
    func progNaming(_ i: Int, _ total: Int) -> String {
        switch language {
        case .en: return "Naming sets \(i)/\(total)…"
        case .ja: return "セットに名前を付け中 \(i)/\(total)…"
        case .zhTW: return "為相簿命名 \(i)/\(total)…"
        }
    }
    func categoryHeader(count: Int, shown: Int) -> String {
        switch language {
        case .en: return shown < count ? "\(count) photos · showing first \(shown)" : "\(count) photos"
        case .ja: return shown < count ? "\(count)枚 · 先頭\(shown)枚を表示" : "\(count)枚"
        case .zhTW: return shown < count ? "\(count) 張 · 顯示前 \(shown) 張" : "\(count) 張"
        }
    }
    func selectCategory() -> String {
        switch language {
        case .en: return "Select a category"
        case .ja: return "カテゴリを選択"
        case .zhTW: return "選一個類別"
        }
    }
    func helpTitle() -> String {
        switch language {
        case .en: return "Keyboard"
        case .ja: return "キーボード"
        case .zhTW: return "鍵盤快速鍵"
        }
    }
    func helpClose() -> String {
        switch language {
        case .en: return "Close"
        case .ja: return "閉じる"
        case .zhTW: return "關閉"
        }
    }
    /// VoiceOver label / tooltip for the globe language switcher (icon-only).
    /// Accessibility label for the scope bar's media-type segmented picker.
    func scopeMediaLabel() -> String {
        switch language {
        case .en: return "Media types to scan"
        case .ja: return "スキャン対象のメディア"
        case .zhTW: return "掃描的媒體類型"
        }
    }
    /// Menu-bar menu title holding every primary action.
    func menuActions() -> String {
        switch language {
        case .en: return "Actions"
        case .ja: return "操作"
        case .zhTW: return "動作"
        }
    }
    /// Menu item: commit the marked deletions (count-less, unlike the toolbar).
    /// Menu-item wording for ⌘. — the hero screen's button can say just
    /// "Cancel" because it sits under the thing it cancels; a menu item cannot.
    func menuStopScan() -> String {
        switch language {
        case .en: return "Stop Scanning"
        case .ja: return "スキャンを停止"
        case .zhTW: return "停止掃描"
        }
    }
    func menuDeleteMarked() -> String {
        switch language {
        case .en: return "Delete Marked Photos…"
        case .ja: return "マークした写真を削除…"
        case .zhTW: return "刪除已標記的照片…"
        }
    }
    /// App-menu item (Sparkle-driven, macOS only): explicit user-triggered
    /// update check.
    func checkForUpdates() -> String {
        switch language {
        case .en: return "Check for Updates…"
        case .ja: return "アップデートを確認…"
        case .zhTW: return "檢查更新…"
        }
    }
    /// Settings (⌘,) language picker label.
    func settingsLanguage() -> String {
        switch language {
        case .en: return "Language"
        case .ja: return "言語"
        case .zhTW: return "語言"
        }
    }
    func languageMenuLabel() -> String {
        switch language {
        case .en: return "Language"
        case .ja: return "言語"
        case .zhTW: return "語言"
        }
    }
    /// VoiceOver label for the iOS toolbar actions menu (icon-only).
    func actionsMenuLabel() -> String {
        switch language {
        case .en: return "Actions"
        case .ja: return "操作"
        case .zhTW: return "動作"
        }
    }
    /// VoiceOver label for the full-screen loupe close button (icon-only).
    func loupeCloseLabel() -> String {
        switch language {
        case .en: return "Close preview"
        case .ja: return "プレビューを閉じる"
        case .zhTW: return "關閉預覽"
        }
    }
    /// THE keyboard map — one table, not two.
    ///
    /// The cheat sheet and the handlers used to be two hand-written lists, and
    /// they had already drifted apart: ⌘. and ⌘Y were implemented and appeared
    /// in no documentation at all, while j/k/l/h were documented right up to
    /// the day they were removed. The KEYS are written once, here, next to the
    /// case that the handler switches on; only the description is per-language.
    ///
    /// (The full single-source version — the same table registering the menu
    /// items AND the handlers — is `CVERKeyMap` in signet, W3.)
    enum KeyMapRow: CaseIterable {
        // List zone
        case listMove, listEnter, listKeepAll, listRejectAll
        // Grid zone
        case gridMove, gridRowMove, gridBackOut, gridCrown, gridKeep, gridKeepOnly, gridPreview
        case gridReject, gridForceReject, gridRotate, gridSaveRotation
        // Preview (loupe)
        case loupeMove, loupeCrown, loupeKeep, loupeKeepOnly, loupeReject, loupeForceReject
        case loupeRotate, loupeClose
        // Anywhere
        case escape, commit, sheetConfirm, scans, stop, history, help

        /// Exactly what the handlers bind — see `handleListKey`,
        /// `handleGridKey`, `handleLoupeKey` and `SnapsiftMenuCommands`.
        var keys: String {
            switch self {
            case .listMove:         return "↑ ↓"
            case .listEnter:        return "→ / ⏎"
            case .listKeepAll:      return "A"
            case .listRejectAll:    return "D"
            case .gridMove:         return "← →"
            case .gridRowMove:      return "↑ ↓"
            case .gridBackOut:      return "←"
            case .gridCrown:        return "1–9"
            case .gridKeep:         return "K"
            case .gridKeepOnly:     return "⇧K"
            case .gridPreview:      return "Space / ⏎"
            case .gridReject:       return "X / ⌫"
            case .gridForceReject:  return "⇧X"
            case .gridRotate:       return "R / ⇧R"
            case .gridSaveRotation: return "⇧⌘R"
            case .loupeMove:        return "← → ↑ ↓"
            case .loupeCrown:       return "1–9"
            case .loupeKeep:        return "K"
            case .loupeKeepOnly:    return "⇧K"
            case .loupeReject:      return "X / ⌫"
            case .loupeForceReject: return "⇧X"
            case .loupeRotate:      return "R / ⇧R"
            case .loupeClose:       return "Space / Esc"
            case .escape:           return "Esc"
            case .commit:           return "⌘⌫"
            case .sheetConfirm:     return "⌘⏎"
            case .scans:            return "⌘1–⌘5"
            case .stop:             return "⌘."
            case .history:          return "⌘Y"
            case .help:             return "? / ⌘?"
            }
        }
    }

    /// (keys, what it does) rows for the keyboard cheat sheet.
    func helpRows() -> [(String, String)] {
        KeyMapRow.allCases.map { ($0.keys, helpRowText($0)) }
    }

    private func helpRowText(_ row: KeyMapRow) -> String {
        switch language {
        case .en:
            switch row {
            case .listMove:         return "Move between groups"
            case .listEnter:        return "Go into the photos"
            case .listKeepAll:      return "Keep the whole group"
            case .listRejectAll:    return "Cross out the whole group"
            case .gridMove:         return "Previous / next photo"
            case .gridRowMove:      return "One row up / down"
            case .gridBackOut:      return "On the first photo: back to the list"
            case .gridCrown:        return "Keep the nth photo"
            case .gridKeep:         return "Keep THIS one — the way to reach photo 10 and beyond"
            case .gridKeepOnly:     return "Keep ONLY this one — crosses out the rest of the group (nothing is removed yet)"
            case .gridPreview:      return "Open the preview"
            case .gridReject:       return "Cross this one out · press again to undo"
            case .gridForceReject:  return "Cross out a protected photo (asks first)"
            case .gridRotate:       return "Turn it — on screen only"
            case .gridSaveRotation: return "Save the turn to Photos (grid or preview)"
            case .loupeMove:        return "Preview: previous / next photo"
            case .loupeCrown:       return "Preview: keep the nth photo"
            case .loupeKeep:        return "Preview: keep THIS one"
            case .loupeKeepOnly:    return "Preview: keep ONLY this one — crosses out the rest"
            case .loupeReject:      return "Preview: cross out · press again to undo"
            case .loupeForceReject: return "Preview: cross out a protected photo (asks first)"
            case .loupeRotate:      return "Preview: turn it — on screen only"
            case .loupeClose:       return "Close the preview"
            case .escape:           return "One level up — nothing changes"
            case .commit:           return "See what would be removed"
            case .sheetConfirm:     return "On that screen: move them to Recently Deleted"
            case .scans:            return "Scans · Faces · Sort into albums"
            case .stop:             return "Stop whatever is running"
            case .history:          return "What was removed, and how long you can still get it back"
            case .help:             return "This list"
            }
        case .ja:
            switch row {
            case .listMove:         return "グループを移動"
            case .listEnter:        return "写真へ入る"
            case .listKeepAll:      return "グループ全部を残す"
            case .listRejectAll:    return "グループ全部を外す"
            case .gridMove:         return "前の写真／次の写真"
            case .gridRowMove:      return "1行上／1行下"
            case .gridBackOut:      return "先頭の写真で押すとリストへ戻る"
            case .gridCrown:        return "n 番目を残す"
            case .gridKeep:         return "この1枚を残す — 10枚目以降はこれで"
            case .gridKeepOnly:     return "この1枚だけを残す — 同じグループの残りを外す（まだ削除はされません）"
            case .gridPreview:      return "プレビューを開く"
            case .gridReject:       return "この1枚を外す・もう一度で取り消し"
            case .gridForceReject:  return "保護された写真も外す（確認あり）"
            case .gridRotate:       return "回す — 画面の中だけ"
            case .gridSaveRotation: return "回転を「写真」に保存（グリッド／プレビュー）"
            case .loupeMove:        return "プレビュー：前／次"
            case .loupeCrown:       return "プレビュー：n 番目を残す"
            case .loupeKeep:        return "プレビュー：この1枚を残す"
            case .loupeKeepOnly:    return "プレビュー：この1枚だけを残す — 残りを外す"
            case .loupeReject:      return "プレビュー：外す・もう一度で取り消し"
            case .loupeForceReject: return "プレビュー：保護された写真も外す（確認あり）"
            case .loupeRotate:      return "プレビュー：回す — 画面の中だけ"
            case .loupeClose:       return "プレビューを閉じる"
            case .escape:           return "1つ上へ — 何も変わりません"
            case .commit:           return "外すものを確認する"
            case .sheetConfirm:     return "その画面で：「最近削除した項目」へ移動"
            case .scans:            return "スキャン・顔・アルバムに仕分け"
            case .stop:             return "実行中の処理を止める"
            case .history:          return "外した記録と、戻せる残り日数"
            case .help:             return "このキー一覧"
            }
        case .zhTW:
            switch row {
            case .listMove:         return "上一群／下一群"
            case .listEnter:        return "進入照片"
            case .listKeepAll:      return "整群保留"
            case .listRejectAll:    return "整群劃掉"
            case .gridMove:         return "上一張／下一張"
            case .gridRowMove:      return "上一列／下一列"
            case .gridBackOut:      return "在第一張上按，回到清單"
            case .gridCrown:        return "把第 n 張留下"
            case .gridKeep:         return "留下這一張 —— 第 10 張以後就靠它"
            case .gridKeepOnly:     return "只留這張 —— 同一群其餘的都劃掉（還不會刪除）"
            case .gridPreview:      return "打開預覽"
            case .gridReject:       return "劃掉這張 · 再按一次取消"
            case .gridForceReject:  return "連受保護的也劃掉（會先問你）"
            case .gridRotate:       return "轉一下 —— 只有畫面上"
            case .gridSaveRotation: return "把轉向存回「照片」（格線與預覽都可以）"
            case .loupeMove:        return "預覽：上一張／下一張"
            case .loupeCrown:       return "預覽：把第 n 張留下"
            case .loupeKeep:        return "預覽：留下這一張"
            case .loupeKeepOnly:    return "預覽：只留這張 —— 其餘都劃掉"
            case .loupeReject:      return "預覽：劃掉這張 · 再按一次取消"
            case .loupeForceReject: return "預覽：連受保護的也劃掉（會先問你）"
            case .loupeRotate:      return "預覽：轉一下 —— 只有畫面上"
            case .loupeClose:       return "關閉預覽"
            case .escape:           return "回上一層 —— 什麼都不會變"
            case .commit:           return "看看有哪些會被移除"
            case .sheetConfirm:     return "在那個畫面：移到「最近刪除」"
            case .scans:            return "掃描 · 人臉 · 整理進相簿"
            case .stop:             return "停下正在進行的事"
            case .history:          return "移除過什麼，還能救回多久"
            case .help:             return "這張小抄"
            }
        }
    }
    func searchPrompt(_ smart: Bool) -> String {
        switch language {
        case .en: return smart ? "Search · ↩ for smart match" : "Filter categories"
        case .ja: return smart ? "検索 · ↩ でスマート検索" : "カテゴリを絞り込む"
        case .zhTW: return smart ? "搜尋 · ↩ 智慧比對" : "篩選類別"
        }
    }
    /// In-flight label while an apfel (Apple Intelligence) smart match runs.
    func smartMatching() -> String {
        switch language {
        case .en: return "Smart matching…"
        case .ja: return "スマート検索中…"
        case .zhTW: return "智慧比對中…"
        }
    }
    /// Shown in the sidebar when a search filters every set out.
    func noSearchMatches(_ query: String) -> String {
        switch language {
        case .en: return "No matches for “\(query)” — clear the search to see all sets"
        case .ja: return "「\(query)」に一致なし — 検索を消すとすべて表示"
        case .zhTW: return "沒有符合「\(query)」的結果 —— 清除搜尋即可看全部"
        }
    }

    // MARK: permission gate
    //
    // The request screen reuses privacyPitch() for its body — it's the same
    // promise as the first-run onboarding, so there's only one set of strings to
    // keep honest. The "Grant access" button supplies the call to action.

    func gateRequestButton() -> String {
        switch language {
        case .en: return "Allow access to Photos"
        case .ja: return "写真へのアクセスを許可"
        case .zhTW: return "允許存取照片"
        }
    }
    func gateDeniedBody() -> String {
        switch language {
        case .en: return "snapsift needs access to your Photos library. Enable it in System Settings ▸ Privacy & Security ▸ Photos."
        case .ja: return "snapsift には写真ライブラリへのアクセスが必要です。システム設定 ▸ プライバシーとセキュリティ ▸ 写真 で許可してください。"
        case .zhTW: return "snapsift 需要存取你的照片圖庫。請到 系統設定 ▸ 隱私權與安全性 ▸ 照片 開啟。"
        }
    }

    // FIX 1: Limited ("Selected Photos") access gate strings.
    // snapsift needs Full Photos access to find and delete duplicates across
    // the whole library; "Selected Photos" fundamentally cannot satisfy that.

    /// Body text shown when the user granted "Selected Photos" (limited) access.
    func gateLimitedBody() -> String {
        switch language {
        case .en: return "Right now snapsift can only see the photos you picked, so it can't find — or remove — anything outside that selection.\n\nOpen System Settings ▸ Privacy & Security ▸ Photos and set snapsift to Full Access."
        case .ja: return "いま snapsift に見えているのは、あなたが選んだ写真だけです。その外にある重複写真は、見つけることも削除することもできません。\n\nシステム設定 ▸ プライバシーとセキュリティ ▸ 写真 で、snapsift を「フルアクセス」にしてください。"
        case .zhTW: return "你目前只讓 snapsift 看到你選取的那些照片，所以選取範圍以外的重複照片，它找不到也刪不掉。\n\n請到「系統設定」▸「隱私權與安全性」▸「照片」，把 snapsift 改成「完整取用權限」。"
        }
    }

    /// Button label on the limited-access gate — opens System Settings Photos pane.
    func gateLimitedButton() -> String {
        switch language {
        case .en: return "Open System Settings ▸ Photos"
        case .ja: return "システム設定 ▸ 写真 を開く"
        case .zhTW: return "開啟系統設定 ▸ 照片"
        }
    }

    // FIX 2: delete-failure alert strings.

    /// Alert title when deleteAssets fails.
    func deleteErrorTitle() -> String {
        switch language {
        case .en: return "Photos couldn't be deleted"
        case .ja: return "写真を削除できませんでした"
        case .zhTW: return "無法刪除照片"
        }
    }

    /// Alert body — plain-language explanation with a fix path.
    func deleteErrorBody() -> String {
        switch language {
        case .en: return "snapsift couldn't delete the photos. This usually means Photos access is set to \"Selected Photos\" rather than Full Access.\n\nOpen System Settings ▸ Privacy & Security ▸ Photos and set snapsift to Full Access, then try again."
        case .ja: return "写真を削除できませんでした。多くの場合、写真のアクセスが「フルアクセス」ではなく「選択した写真」に設定されているのが原因です。\n\nシステム設定 ▸ プライバシーとセキュリティ ▸ 写真 で snapsift を「フルアクセス」に変更してから再試行してください。"
        case .zhTW: return "snapsift 無法刪除照片。通常是因為照片存取權限設為「受限制的取用權限」而非「完整取用權限」。\n\n請到 系統設定 ▸ 隱私權與安全性 ▸ 照片，把 snapsift 改成「完整取用權限」，再試一次。"
        }
    }

    /// Alert button that opens System Settings Photos pane.
    func deleteErrorOpenSettings() -> String {
        switch language {
        case .en: return "Open System Settings"
        case .ja: return "システム設定を開く"
        case .zhTW: return "開啟系統設定"
        }
    }

    /// Alert dismiss button.
    func deleteErrorDismiss() -> String {
        switch language {
        case .en: return "Dismiss"
        case .ja: return "閉じる"
        case .zhTW: return "關閉"
        }
    }

    /// Title for a non-permission delete failure (nothing was deleted).
    func deleteFailedTitle() -> String {
        switch language {
        case .en: return "Delete didn't complete"
        case .ja: return "削除が完了しませんでした"
        case .zhTW: return "刪除未完成"
        }
    }

    /// Body for a non-permission delete failure — nothing changed, retry (and for
    /// very large selections, in smaller batches). Settings is NOT the remedy here.
    func deleteFailedBody() -> String {
        switch language {
        case .en: return "Something went wrong and no photos were deleted — nothing was changed. You can try again; for a very large selection, try deleting in smaller batches."
        case .ja: return "問題が発生し、写真は削除されませんでした（変更はありません）。もう一度お試しください。選択枚数が非常に多い場合は、少しずつ削除してみてください。"
        case .zhTW: return "發生問題，沒有刪除任何照片，狀態也沒有改變。你可以再試一次；如果一次選取的數量很多，可以分批刪除。"
        }
    }

    // FIX 3: status-bar commit button label.

    /// Always-visible commit button in the status bar: "Delete N · ⌘⌫"
    func statusBarDeleteN(_ n: Int) -> String {
        switch language {
        case .en: return "Delete \(n) · ⌘⌫"
        case .ja: return "\(n)枚を削除 · ⌘⌫"
        case .zhTW: return "刪除 \(n) · ⌘⌫"
        }
    }

    // FIX 4: all-protected group label.

    /// Label shown instead of "Deleting all" when the group is armed (deleteAll)
    /// but every frame is protected — nothing can actually be deleted.
    func deleteAllProtected() -> String {
        switch language {
        case .en: return "All protected"
        case .ja: return "すべて保護済み"
        case .zhTW: return "全部受保護"
        }
    }

    /// Tooltip for the "All protected" label on an all-protected armed group.
    func tipDeleteAllProtected() -> String {
        switch language {
        case .en: return "Every frame in this group is protected (favorite / edited / document) — nothing will be deleted. Click to disarm."
        case .ja: return "このグループのすべてのフレームは保護されています（お気に入り・編集済み・書類）。何も削除されません。タップで解除。"
        case .zhTW: return "這群的每張都受保護（最愛／已編輯／文件）—— 不會刪任何東西。按一下可解除。"
        }
    }

    // FIX A: per-frame protection reason badge tooltip.

    /// Tooltip shown on a protected frame's reason badge(s) — explains why it
    /// won't be deleted and what the badges mean. Shown as a single help string
    /// since macOS only surfaces one tooltip per view.
    func tipProtectedFrame() -> String {
        switch language {
        case .en: return "Protected — snapsift won't delete favorites (★), edited photos (✎), or documents (doc) unless you choose to."
        case .ja: return "保護対象 — お気に入り（★）・編集済み（✎）・書類（doc）はあなたが選ばない限り削除しません。"
        case .zhTW: return "受保護 —— snapsift 不會刪最愛（★）、已編輯（✎）或文件（doc）照片，除非你主動選擇。"
        }
    }

    // FIX #4: iCloud-eviction degraded eval indicator tooltip.

    /// Tooltip for the `icloud.slash` badge shown on cards whose document
    /// classification was skipped because the original image wasn't on-device
    /// (iCloud-evicted or timed out). The frame is left un-marked (not
    /// auto-seeded for deletion) because we couldn't confirm it is not a document.
    func tipDocumentEvalDegraded() -> String {
        switch language {
        case .en:   return "Couldn't fully check this photo — its original isn't on this Mac. Left un-marked to be safe."
        case .ja:   return "この写真を完全に確認できませんでした — オリジナルがこの Mac にありません。安全のためマークなしのままにしています。"
        case .zhTW: return "無法完整檢查這張照片 —— 原始檔不在這台 Mac 上。為了安全起見，保持未標記狀態。"
        }
    }

    /// Tooltip for the per-frame "edit state unknown" chip.
    func tipEditedUndetermined() -> String {
        switch language {
        case .en:   return "Couldn't read whether this photo has been edited, so it's protected — snapsift never assumes \"not edited\". Grant Full Disk Access, or rescan, to check it."
        case .ja:   return "この写真が編集済みかどうかを読み取れなかったため、保護しています — snapsift は「未編集」と決めつけません。フルディスクアクセスを許可するか、再スキャンしてください。"
        case .zhTW: return "讀不到這張照片是否被編輯過，因此予以保護 —— snapsift 不會逕自假設「沒編輯」。請給予「完整磁碟取用權限」或重新掃描以確認。"
        }
    }

    // FIX C: include-protected override strings.

    /// Button label for the per-group "include protected" toggle (N = protected frame count).
    func includeProtected(_ n: Int) -> String {
        switch language {
        case .en: return "Include protected (\(n))"
        case .ja: return "保護対象も削除 (\(n))"
        case .zhTW: return "也刪受保護的 (\(n))"
        }
    }

    /// Button label when include-protected is already ON for this group.
    func includingProtected(_ n: Int) -> String {
        switch language {
        case .en: return "Including protected (\(n))"
        case .ja: return "保護対象も含む (\(n))"
        case .zhTW: return "受保護也列入 (\(n))"
        }
    }

    /// Tooltip for the include-protected toggle button.
    func tipIncludeProtected() -> String {
        switch language {
        case .en: return "Explicitly include favorites, edited photos, and documents in the deletion set for this group. Use with care — this overrides snapsift's protection for frames you've usually marked as special."
        case .ja: return "このグループのお気に入り・編集済み・書類を削除対象に含めます。通常は特別にマークしたフレームの保護が解除されます。慎重に使ってください。"
        case .zhTW: return "把這群的最愛、已編輯、文件也列入刪除範圍。這會解除 snapsift 對你平時標為特別的照片的保護，請謹慎操作。"
        }
    }

    /// Alert title shown before deleting protected frames (after user toggled include-protected).
    func deleteProtectedAlertTitle() -> String {
        switch language {
        case .en: return "Delete these? They're favorites, edited photos, or documents"
        case .ja: return "削除しますか？ これらはお気に入り・編集済み・書類です"
        case .zhTW: return "確定要刪除嗎？這幾張是你的最愛、有編輯過，或是文件"
        }
    }

    /// Alert body — N = count of protected frames about to be deleted.
    func deleteProtectedAlertBody(_ n: Int) -> String {
        switch language {
        case .en: return "This will delete \(n) protected photo\(n == 1 ? "" : "s") — favorites, edited photos, or documents you'd normally keep. They'll go to Recently Deleted and can be recovered within 30 days."
        case .ja: return "保護された写真 \(n)枚（お気に入り・編集済み・書類）を削除します。通常は残しておくものです。「最近削除した項目」に移動され、30日以内は復元できます。"
        case .zhTW: return "即將刪除 \(n) 張受保護的照片（最愛、已編輯或文件），這些通常是你會保留的。它們會移到「最近刪除」，30 天內可以復原。"
        }
    }

    /// Confirmation button for the delete-protected alert.
    func deleteProtectedAlertConfirm() -> String {
        switch language {
        case .en: return "Delete Anyway"
        case .ja: return "それでも削除"
        case .zhTW: return "仍然刪除"
        }
    }

    /// Cancel button for the delete-protected alert.
    func deleteProtectedAlertCancel() -> String {
        switch language {
        case .en: return "Cancel"
        case .ja: return "キャンセル"
        case .zhTW: return "取消"
        }
    }

    // MARK: per-frame keyboard actions

    /// Inline hint shown when the user presses X on a protected frame.
    func protectedHint() -> String {
        switch language {
        case .en: return "Protected — ⇧X to force-reject"
        case .ja: return "保護対象 — ⇧X で強制却下"
        case .zhTW: return "受保護 —— ⇧X 強制標刪"
        }
    }

    /// Touch (iOS) variant of the protected block: swipe-up can't reject a
    /// protected frame, and there is no keyboard ⇧X to mention on touch.
    func protectedHintTouch() -> String {
        switch language {
        case .en: return "Protected — won't be deleted"
        case .ja: return "保護対象 — 削除されません"
        case .zhTW: return "受保護 —— 不會刪除"
        }
    }

    /// Inline hint shown when the user presses X (or ⇧X) on an UNVERIFIABLE
    /// frame — distinct from `protectedHint()`: there is no ⇧X override here,
    /// because there is no fact to consent to overriding (`Photo
    /// .isUnverifiable`). Points at the one place the human CAN act on it.
    func unverifiableHint() -> String {
        switch language {
        case .en: return "We can't tell about this one — sort into albums and it waits for you in “Please confirm”"
        case .ja: return "これは判断できません — 「アルバムに仕分け」すると「要確認」で確認できます"
        case .zhTW: return "這張我們判斷不了 —— 用「整理進相簿」收進「請你確認」再決定"
        }
    }

    /// Touch (iOS) variant of the unverifiable block.
    func unverifiableHintTouch() -> String {
        switch language {
        case .en: return "We can't tell about this one — see it in “Please confirm”"
        case .ja: return "これは判断できません — 「要確認」で確認してください"
        case .zhTW: return "這張我們判斷不了 —— 到「請你確認」相簿看看"
        }
    }

    /// Alert body for the ⇧X force-reject confirmation (single frame).
    func forceRejectAlertBody() -> String {
        switch language {
        case .en: return "This photo is protected (favorite, edited, or document). Force-rejecting it adds it to the deletion set — it will go to Recently Deleted and can be recovered within 30 days."
        case .ja: return "この写真は保護対象（お気に入り・編集済み・書類）です。強制却下すると削除対象に追加されます。「最近削除した項目」に移動し、30日以内は復元できます。"
        case .zhTW: return "這張照片受保護（最愛、已編輯或文件）。強制標刪後會加入刪除清單，移到「最近刪除」，30 天內可復原。"
        }
    }

    // MARK: sidebar / detail

    func frames(_ n: Int) -> String {
        switch language {
        case .en: return "\(n) frame\(n == 1 ? "" : "s")"
        case .ja: return "\(n)枚"
        case .zhTW: return "\(n) 張"
        }
    }
    func sidebarSubtitle(span: Double, delete: Int) -> String {
        let s = String(format: "%.1f", span)
        switch language {
        case .en: return "spans \(s)s · delete \(delete)"
        case .ja: return "約\(s)秒 · 削除\(delete)枚"
        case .zhTW: return "跨距 \(s) 秒 · 刪除 \(delete)"
        }
    }
    /// Group header. The sidebar row already says how many frames and the time
    /// span, and the window title names the section — so this line carries only
    /// what nothing else on screen says: how many stay and how many go (owner
    /// ruling 2026-09-17: a fact shown once per screen). `keep` is computed, not
    /// the literal "1" it used to be — a keep-all group keeps them all.
    func clusterHeader(count: Int, span: Double, delete: Int) -> String {
        let keep = max(count - delete, 0)
        switch language {
        case .en: return "Keep \(keep) · delete \(delete)"
        case .ja: return "残す \(keep) · 削除 \(delete)"
        case .zhTW: return "留 \(keep) · 刪 \(delete)"
        }
    }
    func sectionConfidentName() -> String {
        switch language { case .en: return "Near-identical"; case .ja: return "ほぼ同じ"; case .zhTW: return "幾乎一樣" }
    }
    func sectionPendingName() -> String {
        switch language { case .en: return "A bit alike — you choose"; case .ja: return "少し似ている — あなたが選ぶ"; case .zhTW: return "有點像 · 你決定" }
    }
    func appleRanked() -> String {
        switch language {
        case .en: return "Picked by Apple's quality scores"
        case .ja: return "Apple 品質スコアで選択"
        case .zhTW: return "Apple 品質分數挑選"
        }
    }
    func selectCluster() -> String {
        switch language {
        case .en: return "Select a cluster"
        case .ja: return "グループを選択"
        case .zhTW: return "選一個群組"
        }
    }
    func scanHint() -> String {
        switch language {
        case .en: return "Pick what to look for"
        case .ja: return "何を探すか選んでください"
        case .zhTW: return "選一個你想找的"
        }
    }
    /// The privacy line, reduced to what the app can actually keep.
    ///
    /// It used to promise "nothing ever sent", which the updater's own
    /// "Check for Updates…" breaks the moment anyone uses it. What is true, and
    /// is the only thing she is asking about, is that her PHOTOS stay here.
    ///
    /// The second half is conditional for the same reason: the quality scores
    /// are only there when the library's own scores are readable, and the gate
    /// says this sentence before anything at all is known — so it promised a
    /// feature that may not exist on her Mac.
    func privacyPitch(qualityAvailable: Bool = false) -> String {
        switch language {
        case .en:
            let base = "Your photos never leave this Mac."
            return qualityAvailable
                ? base + " Picking uses the quality scores your photo library already keeps; naming and search use Apple Intelligence — all of it here."
                : base + " Naming and search use Apple Intelligence, here on your Mac."
        case .ja:
            let base = "あなたの写真がこの Mac から出ることはありません。"
            return qualityAvailable
                ? base + "1枚選ぶときは写真ライブラリ自身の品質スコアを、名前づけと検索は Apple Intelligence を使います。すべてこの Mac の中で。"
                : base + "名前づけと検索は Apple Intelligence を使います。すべてこの Mac の中で。"
        case .zhTW:
            let base = "你的照片不會離開這台 Mac。"
            return qualityAvailable
                ? base + "挑哪一張時會用圖庫自己的品質分數，命名與搜尋用 Apple 智慧，全部都在這台 Mac 上。"
                : base + "命名與搜尋用 Apple 智慧，就在這台 Mac 上。"
        }
    }

    // MARK: badges + tooltips

    func keep() -> String {
        switch language {
        case .en: return "KEEP"
        case .ja: return "残す"
        case .zhTW: return "保留"
        }
    }
    func delete() -> String {
        switch language {
        case .en: return "DELETE"
        case .ja: return "削除"
        case .zhTW: return "刪除"
        }
    }
    func tipKeeper() -> String {
        switch language {
        case .en: return "The one we'll keep"
        case .ja: return "残すのはこの1枚"
        case .zhTW: return "會留下的就這張"
        }
    }
    func tipDelete() -> String {
        switch language {
        case .en: return "This one gets deleted — click it to keep it instead"
        case .ja: return "これは削除されます — クリックすれば残せます"
        case .zhTW: return "這張會被刪 —— 按一下改成留它"
        }
    }
    /// For a card NOBODY has decided about. The tooltip used to hand these the
    /// delete copy, which told a woman her untouched photo was going to be
    /// deleted — in the very groups snapsift deliberately did not mark.
    ///
    /// It names the two verbs that change something — X and its mirror K — and
    /// neither is a navigation key (SPEC §2: Return opens the preview now, it
    /// does not keep; K is the verb that took over that job).
    func tipUndecided() -> String {
        switch language {
        case .en: return "Not decided yet — X crosses this one out, K keeps it"
        case .ja: return "まだ決まっていません — X で外す、K で残す"
        case .zhTW: return "還沒決定 —— X 劃掉它，K 留下它"
        }
    }

    /// WHY a photo is marked for removal. Keeping had seven answers available
    /// and removing had none.
    ///
    /// `.userRejected` deliberately does NOT say which key she used: X on one
    /// frame and D on the group are both "she marked it", and W1 has no
    /// recorded state that tells them apart (review P2-1 — `deleteMarkReason`
    /// has the detail). `.notPicked` is written and translated, and is
    /// unreachable until W2 records the fact it claims.
    ///
    /// These are also the words the history panel speaks: `historyReasonName`
    /// forwards to this function, so the chip, the tooltip, the VoiceOver label
    /// and the log cannot describe one deletion four ways.
    func deleteWhy(_ reason: DeleteMarkReason) -> String {
        switch language {
        case .en:
            switch reason {
            case .exactDuplicate: return "Same photo · copy 2"
            case .notPicked:      return "Not the one picked"
            case .userRejected:   return "You marked it"
            }
        case .ja:
            switch reason {
            case .exactDuplicate: return "同じ写真 · 2枚目"
            case .notPicked:      return "選ばれなかった"
            case .userRejected:   return "自分で外した"
            }
        case .zhTW:
            switch reason {
            case .exactDuplicate: return "同一張 · 第 2 份"
            case .notPicked:      return "沒被選中"
            case .userRejected:   return "你標的"
            }
        }
    }

    func tipScan() -> String {
        switch language {
        case .en: return "Clears the burst of near-identical shots from holding the shutter — keeps the best one"
        case .ja: return "シャッターを押し続けて撮れたそっくりな連写を片付け、ベストの1枚を残す"
        case .zhTW: return "把你按住快門連拍出的一堆幾乎一樣的，留最好一張、清掉其餘"
        }
    }
    func tipLookAlikes() -> String {
        switch language {
        case .en: return "Finds the same photo saved more than once — re-downloaded, screenshotted, AirDropped back — even days apart"
        case .ja: return "同じ写真を何度も保存したもの（再ダウンロード・スクショ・AirDrop）を、別の日でも見つける"
        case .zhTW: return "找出同一張被存了好幾份的（重新下載、截圖、AirDrop 回來），就算隔了好幾天"
        }
    }
    func tipFaces() -> String {
        switch language {
        case .en: return "Re-picks which photo to keep — the one where faces look best, eyes open. Only re-orders; never changes what can be deleted."
        case .ja: return "顔がいちばん良く写った1枚（目が開いている）を残すよう選び直す。並べ替えだけで、削除対象は変わりません。"
        case .zhTW: return "改挑大家臉拍得最好、眼睛有張開的那張當保留。只重新排序，永遠不會改變哪些照片可被刪。"
        }
    }
    func tipAppleRanked() -> String {
        switch language {
        case .en: return "Picks the best frame using Apple's on-device photo quality scores (sharpness, framing…)"
        case .ja: return "Apple が端末で算出した写真品質スコア（鮮明さ・構図…）でベストの1枚を選択"
        case .zhTW: return "用 Apple 裝置端算好的照片品質分數（銳利度、構圖…）挑最好的一張"
        }
    }

    // MARK: progress

    func progFetching() -> String {
        switch language {
        case .en: return "Fetching library…"
        case .ja: return "ライブラリを読み込み中…"
        case .zhTW: return "讀取圖庫中…"
        }
    }
    func progReadingQuality() -> String {
        switch language {
        case .en: return "Reading Apple quality scores…"
        case .ja: return "Apple 品質スコアを読み込み中…"
        case .zhTW: return "讀取 Apple 品質分數中…"
        }
    }
    func progClustering(_ n: Int) -> String {
        switch language {
        case .en: return "Clustering \(n) photos…"
        case .ja: return "\(n)枚をグループ化中…"
        case .zhTW: return "分群 \(n) 張中…"
        }
    }
    func progHashing(_ i: Int, _ total: Int) -> String {
        switch language {
        case .en: return "Hashing \(i)/\(total)…"
        case .ja: return "ハッシュ計算 \(i)/\(total)…"
        case .zhTW: return "雜湊計算 \(i)/\(total)…"
        }
    }
    func progConfirming(_ i: Int, _ total: Int) -> String {
        switch language {
        case .en: return "Confirming \(i)/\(total) candidate groups…"
        case .ja: return "候補グループを確認中 \(i)/\(total)…"
        case .zhTW: return "確認候選群組 \(i)/\(total)…"
        }
    }
    /// Variant that also reports how many thumbnails were actually readable —
    /// distinguishes "slow but working" from "can't read the library".
    func progConfirming(_ i: Int, _ total: Int, loaded: Int) -> String {
        switch language {
        case .en: return "Confirming \(i)/\(total) · read \(loaded)…"
        case .ja: return "確認中 \(i)/\(total) · 読込 \(loaded)…"
        case .zhTW: return "確認 \(i)/\(total) · 讀到 \(loaded)…"
        }
    }
    /// Shown when oversized dHash-collision clusters were skipped (noise guard).
    func progSkippedClusters(_ n: Int) -> String {
        switch language {
        case .en: return "Skipped \(n) oversized noise cluster\(n == 1 ? "" : "s")"
        case .ja: return "過大なノイズ群 \(n) 件をスキップ"
        case .zhTW: return "略過 \(n) 個過大的噪音群"
        }
    }
    func progFaces(_ i: Int, _ total: Int) -> String {
        switch language {
        case .en: return "Analyzing faces \(i)/\(total)…"
        case .ja: return "顔を解析中 \(i)/\(total)…"
        case .zhTW: return "分析人臉 \(i)/\(total)…"
        }
    }
    func progVerifying(_ i: Int, _ total: Int) -> String {
        switch language {
        case .en: return "Verifying clusters \(i)/\(total)…"
        case .ja: return "グループを確認中 \(i)/\(total)…"
        case .zhTW: return "驗證群組 \(i)/\(total)…"
        }
    }
    /// Shown when the chosen album can no longer be resolved (deleted between
    /// showing the picker and starting the scan).
    func progAlbumGone() -> String {
        switch language {
        case .en: return "Album not found — it may have been deleted. Choose a source and try again."
        case .ja: return "アルバムが見つかりません（削除された可能性があります）。ソースを選び直して再試行してください。"
        case .zhTW: return "找不到相簿（可能已被刪除）。請重新選擇來源後再試。"
        }
    }
    func sectionConfident(_ n: Int) -> String {
        switch language {
        case .en: return "Near-identical · \(n)"
        case .ja: return "ほぼ同じ · \(n)"
        case .zhTW: return "幾乎一樣 · \(n)"
        }
    }
    func sectionPending(_ n: Int) -> String {
        switch language {
        case .en: return "A bit alike — you choose · \(n)"
        case .ja: return "少し似ている — あなたが選ぶ · \(n)"
        case .zhTW: return "有點像 · 你決定 · \(n)"
        }
    }
    func keepAll() -> String {
        switch language {
        case .en: return "Keep all"
        case .ja: return "すべて残す"
        case .zhTW: return "整群保留"
        }
    }
    func keepingAll() -> String {
        switch language {
        case .en: return "Keeping all"
        case .ja: return "すべて残す"
        case .zhTW: return "整群保留中"
        }
    }
    func tipKeepAll() -> String {
        switch language {
        case .en: return "Keep every frame in this group — delete nothing"
        case .ja: return "このグループは全て残す（何も削除しない）"
        case .zhTW: return "這群全部保留 —— 不刪任何一張"
        }
    }
    /// Big-preview loader caption — shows the iCloud download % while fetching
    /// the full-resolution original.
    func previewLoading(_ pct: Double) -> String {
        let p = Int(pct * 100)
        switch language {
        case .en: return (pct > 0 && pct < 1) ? "Fetching original from iCloud… \(p)%" : "Loading…"
        case .ja: return (pct > 0 && pct < 1) ? "iCloud から原本を取得中… \(p)%" : "読み込み中…"
        case .zhTW: return (pct > 0 && pct < 1) ? "從 iCloud 取回原檔… \(p)%" : "載入中…"
        }
    }
    /// Big-preview terminal failure — the original couldn't be fetched (offline,
    /// iCloud error, damaged asset). Never leave the inspection step of a
    /// deletion tool on a forever-spinner.
    func previewFailed() -> String {
        switch language {
        case .en: return "Couldn't fetch the original from iCloud"
        case .ja: return "iCloud から原本を取得できませんでした"
        case .zhTW: return "無法從 iCloud 取回原檔"
        }
    }
    /// Retry button for the big-preview failure state.
    func previewRetry() -> String {
        switch language {
        case .en: return "Try again"
        case .ja: return "再試行"
        case .zhTW: return "再試一次"
        }
    }
    func deleteAll() -> String {
        switch language {
        case .en: return "Delete all"
        case .ja: return "すべて削除"
        case .zhTW: return "整群刪除"
        }
    }
    func deletingAll() -> String {
        switch language {
        case .en: return "Deleting all"
        case .ja: return "すべて削除"
        case .zhTW: return "整群刪除中"
        }
    }
    func tipDeleteAll() -> String {
        switch language {
        case .en: return "Delete every frame in this group (protected photos stay safe)"
        case .ja: return "このグループを全て削除（保護対象は残ります）"
        case .zhTW: return "這群全部刪除（受保護的照片不會被刪）"
        }
    }
    /// Tooltip variant for an armed delete-all group whose include-protected
    /// override is ON — protection no longer spares anything, so say so plainly.
    func tipDeleteAllIncludingProtected() -> String {
        switch language {
        case .en: return "Delete every frame in this group — including protected photos (override is on)"
        case .ja: return "このグループを全て削除 — 保護対象も含みます（上書き有効）"
        case .zhTW: return "這群全部刪除 —— 受保護的照片也會被刪（已開啟覆寫）"
        }
    }

    // MARK: reclaim summary + post-delete banner

    func reclaimSummary(count: Int, bytes: Int) -> String {
        guard count > 0 else { return "" }
        let size = bytes > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " · "
            : ""
        switch language {
        case .en: return "\(size)\(count) photo\(count == 1 ? "" : "s") to delete"
        case .ja: return "\(size)削除予定 \(count)枚"
        case .zhTW: return "\(size)待刪 \(count) 張"
        }
    }
    func deletedBanner(_ n: Int) -> String {
        // FIX 5: state the point-of-no-return clearly — "permanent after 30 days"
        // mirrors the pre-commit sheet language so the recovery window is obvious
        // both before AND after committing.
        switch language {
        case .en: return "Moved \(n) to Recently Deleted — permanent after 30 days"
        case .ja: return "\(n)枚を「最近削除した項目」へ — 30日後は完全削除"
        case .zhTW: return "已將 \(n) 張移到「最近刪除」— 30 天後永久刪除"
        }
    }
    /// Shown after a commit when frames became protected (favorited/edited in
    /// Photos) since the scan and were kept back out of the deletion.
    func commitProtectedKept(_ n: Int) -> String {
        switch language {
        case .en: return "kept \(n) favorited or edited since the scan"
        case .ja: return "スキャン後にお気に入り／編集された\(n)枚は残しました"
        case .zhTW: return "掃描後被加入最愛或編輯的 \(n) 張已保留"
        }
    }
    /// Shown after a commit when frames were dropped because their edited state
    /// could not be read (sidecar unreadable / unverified library / sync-lane
    /// breaker). They are UN-MARKED and now carry the "edit state unknown" chip,
    /// so the message must not promise a mark that is no longer there.
    func commitUndeterminedSkipped(_ n: Int) -> String {
        switch language {
        case .en: return "kept \(n) — couldn't read whether they were edited, so they're protected and unmarked; rescan to check"
        case .ja: return "\(n)枚は編集されたかどうかを読み取れなかったため保護し、マークを解除しました — 再スキャンで確認できます"
        case .zhTW: return "有 \(n) 張因為讀不到是否被編輯過而受保護，標記已取消 —— 重新掃描即可確認"
        }
    }
    /// Shown after a commit when burst representatives were skipped to avoid
    /// taking unreviewed stack siblings — the user should handle them in Photos.
    func commitBurstSkipped(_ n: Int) -> String {
        switch language {
        case .en: return "skipped \(n) burst — delete those in Photos"
        case .ja: return "バースト\(n)件はスキップ — 写真アプリで削除してください"
        case .zhTW: return "跳過 \(n) 個連拍 —— 請在「照片」中刪除"
        }
    }

    // MARK: FIX 3 — stale-asset warning alert

    /// Alert title when some IDs can't be resolved at delete time.
    func staleAssetAlertTitle() -> String {
        switch language {
        case .en:   return "Some photos can't be found"
        case .ja:   return "一部の写真が見つかりません"
        case .zhTW: return "部分照片找不到"
        }
    }

    /// Alert body explaining the stale-asset situation.
    func staleAssetAlertBody(stale: Int, found: Int) -> String {
        switch language {
        case .en:
            return "\(stale) photo\(stale == 1 ? "" : "s") couldn't be found — they may have been moved or deleted by another app. Delete the \(found) that were found?"
        case .ja:
            return "\(stale)枚の写真が見つかりませんでした（別のアプリで移動または削除された可能性があります）。見つかった\(found)枚を削除しますか？"
        case .zhTW:
            return "\(stale) 張照片找不到 —— 可能已被其他 App 移動或刪除。要刪除找得到的 \(found) 張嗎？"
        }
    }

    /// Proceed button label — delete the N photos that were found.
    func staleAssetAlertProceed(_ found: Int) -> String {
        switch language {
        case .en:   return "Delete \(found) Found"
        case .ja:   return "見つかった\(found)枚を削除"
        case .zhTW: return "刪除找到的 \(found) 張"
        }
    }

    /// Cancel button label for the stale-asset alert.
    func staleAssetAlertCancel() -> String {
        switch language {
        case .en:   return "Cancel"
        case .ja:   return "キャンセル"
        case .zhTW: return "取消"
        }
    }

    // MARK: album-write (Part A / Part B)

    // ── Album names ─────────────────────────────────────────────────────────
    // Prefixed with "Snapsift · " by AlbumWriter.prefix. The suffix is
    // localized here; the prefix stays ASCII so the round-trip through the
    // source picker is unambiguous regardless of OS locale.

    /// Near-duplicate / burst candidates — for human review, NOT a delete bucket.
    func albumNameBursts() -> String {
        switch language {
        case .en:   return "Burst Candidates"
        case .ja:   return "バースト候補"
        case .zhTW: return "近重複照片"
        }
    }

    /// Frames that appear blurry relative to the best frame in their cluster.
    func albumNameBlurry() -> String {
        switch language {
        case .en:   return "Blurry"
        case .ja:   return "ブレ写真"
        case .zhTW: return "模糊照片"
        }
    }

    /// Documents, IDs, receipts, scans — organizational, never a delete bucket.
    func albumNameDocs() -> String {
        switch language {
        case .en:   return "Documents & IDs"
        case .ja:   return "書類・証明書"
        case .zhTW: return "文件與證件"
        }
    }

    /// Exact duplicates (dHash distance 0 + feature ≈0 + same size). The ONLY
    /// bucket where the UI may show a delete suggestion badge.
    func albumNameExact() -> String {
        switch language {
        case .en:   return "Exact Duplicates"
        case .ja:   return "完全に同じ写真"
        case .zhTW: return "完全相同"
        }
    }

    /// Frames snapsift could NOT classify at all — edit state unreadable,
    /// document eval ran blind, or (for a video) Live Photo pairing
    /// undetermined. NEVER a delete bucket and never even a review-for-
    /// deletion bucket: these frames are collected here strictly so a human
    /// can decide in Photos.app (ruling, chodaict, 2026-09-16).
    func albumNameNeedsLook() -> String {
        switch language {
        case .en:   return "Please confirm"
        case .ja:   return "要確認"
        case .zhTW: return "請你確認"
        }
    }

    // ── Toolbar button + progress ────────────────────────────────────────────

    func sortIntoAlbums() -> String {
        switch language {
        case .en:   return "Sort into Albums"
        case .ja:   return "アルバムに仕分け"
        case .zhTW: return "整理進相簿"
        }
    }
    func tipSortIntoAlbums() -> String {
        switch language {
        case .en:   return "Write candidates into named Snapsift albums — non-destructive; nothing is deleted"
        case .ja:   return "候補を名前付き Snapsift アルバムに仕分ける（非破壊・何も削除しない）"
        case .zhTW: return "把候選照片整理進具名的 Snapsift 相簿 —— 不破壞原檔，不刪任何東西"
        }
    }
    func progWritingAlbums() -> String {
        switch language {
        case .en:   return "Writing albums…"
        case .ja:   return "アルバムに書き込み中…"
        case .zhTW: return "寫入相簿中…"
        }
    }
    func albumsWritten(bursts: Int, blurry: Int, docs: Int, exact: Int, needsLook: Int,
                       moved: Int = 0) -> String {
        // Compact summary: "Sorted into albums · 12 bursts, 3 blurry, 1 exact dup"
        var parts: [String] = []
        if bursts > 0 { parts.append(albumsWrittenBursts(bursts)) }
        if blurry > 0 { parts.append(albumsWrittenBlurry(blurry)) }
        if docs   > 0 { parts.append(albumsWrittenDocs(docs)) }
        if exact  > 0 { parts.append(albumsWrittenExact(exact)) }
        if needsLook > 0 { parts.append(albumsWrittenNeedsLook(needsLook)) }
        if moved > 0 { parts.append(albumsMovedBetweenBuckets(moved)) }
        // English joins with a comma; CJK uses the ideographic comma 「、」.
        let sep: String
        switch language {
        case .en:         sep = ", "
        case .ja, .zhTW:  sep = "、"
        }
        let summary = parts.isEmpty ? albumsNothingNew() : parts.joined(separator: sep)
        switch language {
        case .en:   return "Sorted into albums · \(summary)"
        case .ja:   return "アルバムに仕分け完了 · \(summary)"
        case .zhTW: return "整理進相簿完成 · \(summary)"
        }
    }
    /// Frames taken OUT of one snapsift album because this scan put them in the
    /// other one. Said out loud rather than done quietly: the user is looking at
    /// these albums in Photos.app, and a photo that silently leaves "Exact
    /// Duplicates" is a change to what they were about to act on.
    private func albumsMovedBetweenBuckets(_ n: Int) -> String {
        switch language {
        case .en:   return "\(n) moved to the album that now fits"
        case .ja:   return "\(n)枚を今の分類に合うアルバムへ移動"
        case .zhTW: return "有 \(n) 張移到現在該去的相簿"
        }
    }
    private func albumsWrittenBursts(_ n: Int) -> String {
        switch language {
        case .en:   return "\(n) burst\(n == 1 ? "" : "s")"
        case .ja:   return "バースト \(n)枚"
        case .zhTW: return "近重複 \(n) 張"
        }
    }
    private func albumsWrittenBlurry(_ n: Int) -> String {
        switch language {
        case .en:   return "\(n) blurry"
        case .ja:   return "ブレ \(n)枚"
        case .zhTW: return "模糊 \(n) 張"
        }
    }
    private func albumsWrittenDocs(_ n: Int) -> String {
        switch language {
        case .en:   return "\(n) doc\(n == 1 ? "" : "s")"
        case .ja:   return "書類 \(n)枚"
        case .zhTW: return "文件 \(n) 張"
        }
    }
    private func albumsWrittenNeedsLook(_ n: Int) -> String {
        switch language {
        case .en:   return "\(n) to confirm"
        case .ja:   return "要確認 \(n)枚"
        case .zhTW: return "請你確認 \(n) 張"
        }
    }
    private func albumsWrittenExact(_ n: Int) -> String {
        switch language {
        case .en:   return "\(n) identical"
        case .ja:   return "完全重複 \(n)枚"
        case .zhTW: return "完全相同 \(n) 張"
        }
    }
    func albumsNothingNew() -> String {
        switch language {
        case .en:   return "nothing new to add"
        case .ja:   return "新しく追加するものなし"
        case .zhTW: return "沒有新增項目"
        }
    }

    // ── Exact-duplicate badge (Part B) ───────────────────────────────────────

    /// Badge shown on the non-keeper in a confirmed exact-duplicate group.
    /// Distinct from the generic DELETE badge: this one carries an explicit
    /// "safe to remove" message, since these frames are genuinely interchangeable.
    func exactDupeBadge() -> String {
        switch language {
        case .en:   return "Identical"
        case .ja:   return "完全に同じ"
        case .zhTW: return "完全相同"
        }
    }
    /// Tooltip for the exact-dup badge.
    ///
    /// Names the LIMIT of "safe to remove" in the same breath as the claim.
    /// The two frames are byte-identical as pixels; what can still differ is
    /// what the LIBRARY knows about each copy, and snapsift compares only part
    /// of that — albums and captions, because those it can read and prove.
    /// Keywords, people and places are not compared (no public API, and a
    /// guard written from an unverified database schema would fail by making
    /// every exact-dup suggestion quietly vanish). Saying so here is the
    /// difference between a limit and a surprise.
    func tipExactDupe() -> String {
        switch language {
        case .en:   return "Exact duplicate — same image saved twice. Safe to remove (goes to Recently Deleted). Albums and captions are compared; keywords, people and places are not."
        case .ja:   return "完全な重複 — 同じ画像が2回保存されています。削除して問題ありません（「最近削除した項目」に移動）。比較するのはアルバムと説明のみで、キーワード・人物・場所は比較しません。"
        case .zhTW: return "完全相同 —— 同一張圖存了兩份，可安心清（移到「最近刪除」，30 天內可復原）。比對的是相簿與說明；關鍵字、人物、地點不會比對。"
        }
    }
    /// Tooltip for a protected frame that is in an exact-dup group — even here,
    /// protection wins.
    func tipExactDupeProtected() -> String {
        switch language {
        case .en:   return "Exact duplicate, but protected (favorite / edited / document) — not deleted unless you force it (⇧X)"
        case .ja:   return "完全な重複ですが保護対象（お気に入り・編集済み・書類）— ⇧X で強制しない限り削除しません"
        case .zhTW: return "完全相同，但受保護（最愛／已編輯／文件）—— 不會被刪，除非你用 ⇧X 強制"
        }
    }

    // MARK: - Pre-commit review sheet (Feature 1)

    /// Sheet title — "Move N photos to Recently Deleted?"
    func preCommitTitle(_ n: Int) -> String {
        switch language {
        case .en:   return "Move \(n) photo\(n == 1 ? "" : "s") to Recently Deleted?"
        case .ja:   return "\(n)枚を「最近削除した項目」へ移動しますか？"
        case .zhTW: return "將 \(n) 張照片移到「最近刪除」？"
        }
    }

    /// Sheet subtitle — "≈X MB freed · recoverable for 30 days"
    func preCommitSubtitle(bytes: Int) -> String {
        // The "freed" wording must be per-language — "213 KB freed · 30 天內可復原"
        // is exactly the mixed-language seam this exhaustive switch exists to prevent.
        let size = bytes > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            : ""
        switch language {
        case .en:   return size.isEmpty ? "recoverable for 30 days" : "\(size) freed · recoverable for 30 days"
        case .ja:   return size.isEmpty ? "30日間は復元可能" : "\(size) 解放 · 30日間は復元可能"
        case .zhTW: return size.isEmpty ? "30 天內可復原" : "可釋放 \(size) · 30 天內可復原"
        }
    }

    /// Label for the keeper section inside each group row.
    func preCommitKept() -> String {
        switch language {
        case .en:   return "Kept"
        case .ja:   return "残す"
        case .zhTW: return "保留"
        }
    }

    /// Label for the removing section inside each group row.
    func preCommitRemoving() -> String {
        switch language {
        case .en:   return "Removing"
        case .ja:   return "削除"
        case .zhTW: return "移除"
        }
    }

    /// Confirm button label.
    func preCommitConfirm() -> String {
        switch language {
        case .en:   return "Move to Recently Deleted"
        case .ja:   return "「最近削除した項目」へ移動"
        case .zhTW: return "移到「最近刪除」"
        }
    }

    /// Cancel button label.
    func preCommitCancel() -> String {
        switch language {
        case .en:   return "Cancel"
        case .ja:   return "キャンセル"
        case .zhTW: return "取消"
        }
    }

    /// Protected-frames warning shown in the review sheet in red.
    func preCommitProtectedWarning(_ m: Int) -> String {
        switch language {
        case .en:   return "Includes \(m) protected photo\(m == 1 ? "" : "s") — favorites / edited / documents"
        case .ja:   return "保護対象 \(m)枚を含む — お気に入り・編集済み・書類"
        case .zhTW: return "包含 \(m) 張受保護照片 —— 最愛／已編輯／文件"
        }
    }

    // MARK: - Keeper "why" labels (Feature 2)

    func keeperWhyFavorite() -> String {
        switch language {
        case .en:   return "kept: favorite ★"
        case .ja:   return "保持：お気に入り ★"
        case .zhTW: return "保留：最愛 ★"
        }
    }
    func keeperWhyQuality() -> String {
        switch language {
        case .en:   return "kept: best quality"
        case .ja:   return "保持：品質最高"
        case .zhTW: return "保留：品質最佳"
        }
    }
    func keeperWhyOriginalCamera() -> String {
        switch language {
        case .en:   return "kept: original capture"
        case .ja:   return "保持：元のカメラ撮影"
        case .zhTW: return "保留：原始拍攝"
        }
    }
    func keeperWhySharpness() -> String {
        switch language {
        case .en:   return "kept: sharpest"
        case .ja:   return "保持：最もシャープ"
        case .zhTW: return "保留：最清晰"
        }
    }
    func keeperWhyFormat() -> String {
        switch language {
        case .en:   return "kept: best format"
        case .ja:   return "保持：フォーマット優先"
        case .zhTW: return "保留：格式最佳"
        }
    }
    func keeperWhySize() -> String {
        switch language {
        case .en:   return "kept: largest file"
        case .ja:   return "保持：ファイル最大"
        case .zhTW: return "保留：檔案最大"
        }
    }
    func keeperWhyEarliest() -> String {
        switch language {
        case .en:   return "kept: earliest"
        case .ja:   return "保持：最も古い"
        case .zhTW: return "保留：最早拍攝"
        }
    }

    // MARK: - No-survivor guard (Feature 3)

    /// Warning shown in the pre-commit sheet when N groups will have no photo left.
    func preCommitNoSurvivorWarning(_ n: Int) -> String {
        switch language {
        case .en:   return "⚠️ \(n) group\(n == 1 ? "" : "s") will have no photo left — the whole set goes to Recently Deleted"
        case .ja:   return "⚠️ \(n)つのグループに写真が残りません — グループ全体が「最近削除した項目」へ"
        case .zhTW: return "⚠️ \(n) 個群組將不留任何照片 —— 整個群組都會移到「最近刪除」"
        }
    }

    /// Checkbox label the user must tick before the confirm button enables.
    func preCommitNoSurvivorAcknowledge() -> String {
        switch language {
        case .en:   return "I understand the entire cluster will be removed"
        case .ja:   return "グループ全体が削除されることを理解しました"
        case .zhTW: return "我了解整個群組都將被移除"
        }
    }

    // MARK: - History view (Feature 4)

    func historyTitle() -> String {
        switch language {
        case .en:   return "Removed"
        case .ja:   return "削除済み"
        case .zhTW: return "已移除"
        }
    }
    func historyEmpty() -> String {
        switch language {
        case .en:   return "No deletion history yet.\nDelete photos to see a record here."
        case .ja:   return "削除履歴はまだありません。\n写真を削除すると記録が表示されます。"
        case .zhTW: return "還沒有刪除記錄。\n刪除照片後就會在這裡顯示。"
        }
    }
    func historySessionHeader(date: String, count: Int) -> String {
        switch language {
        case .en:   return "\(date) · \(count) photo\(count == 1 ? "" : "s") removed"
        case .ja:   return "\(date) · \(count)枚を削除"
        case .zhTW: return "\(date) · 移除 \(count) 張"
        }
    }
    func historyRecoverable(until: String) -> String {
        switch language {
        case .en:   return "In Recently Deleted — recoverable until \(until)"
        case .ja:   return "「最近削除した項目」に保存中 — \(until) まで復元可能"
        case .zhTW: return "在「最近刪除」中 —— 可在 \(until) 前復原"
        }
    }
    /// The panel's version of the recovery window: how many days are LEFT.
    ///
    /// "recoverable until 16 Oct 2026" makes her do the subtraction, and the
    /// answer to the only question she has ("can I still get them back?") is
    /// the number of days, not a date (ruling: the history panel is demoted to
    /// when / how many / how long left).
    func historyDaysLeft(_ days: Int) -> String {
        switch language {
        case .en:   return days == 1
            ? "Still in Recently Deleted — today is the last day to get them back"
            : "Still in Recently Deleted — \(days) days left to get them back"
        case .ja:   return days == 1
            ? "「最近削除した項目」にあります — 戻せるのは今日までです"
            : "「最近削除した項目」にあります — あと \(days) 日戻せます"
        case .zhTW: return days == 1
            ? "還在「最近刪除」裡 —— 今天是最後一天可以救回來"
            : "還在「最近刪除」裡 —— 還有 \(days) 天可以救回來"
        }
    }

    /// Label of the history panel's secondary menu (the ⋯ button).
    func historyMoreMenu() -> String {
        switch language {
        case .en:   return "More"
        case .ja:   return "その他"
        case .zhTW: return "更多"
        }
    }

    /// Menu item that reveals the per-photo reasons — off by default, because
    /// the panel's job is "when, how many, how long left", not an audit trail.
    func historyShowReasons() -> String {
        switch language {
        case .en:   return "Show why each one went"
        case .ja:   return "1枚ごとの理由を表示"
        case .zhTW: return "顯示每一張的原因"
        }
    }

    func historyExpired() -> String {
        switch language {
        case .en:   return "Recovery window expired"
        case .ja:   return "復元期限切れ"
        case .zhTW: return "復原期限已過"
        }
    }
    func historyExportLog() -> String {
        switch language {
        case .en:   return "Export Log…"
        case .ja:   return "ログをエクスポート…"
        case .zhTW: return "匯出記錄…"
        }
    }
    func historyExportFilename() -> String {
        switch language {
        case .en:   return "snapsift-deletion-history"
        case .ja:   return "snapsift-削除履歴"
        case .zhTW: return "snapsift-刪除記錄"
        }
    }
    /// Alert title when writing the exported audit log fails (full disk, denied volume).
    func historyExportFailedTitle() -> String {
        switch language {
        case .en:   return "Couldn't save the log"
        case .ja:   return "ログを保存できませんでした"
        case .zhTW: return "無法儲存記錄"
        }
    }
    /// Confirmation shown next to the Export button after a successful write.
    func historyExportSaved() -> String {
        switch language {
        case .en:   return "Log saved"
        case .ja:   return "ログを保存しました"
        case .zhTW: return "記錄已儲存"
        }
    }
    /// Button that opens the Photos app so the user can reach Recently Deleted.
    func historyOpenPhotos() -> String {
        switch language {
        case .en:   return "Open Photos"
        case .ja:   return "写真を開く"
        case .zhTW: return "打開「照片」"
        }
    }
    func historyClose() -> String {
        switch language {
        case .en:   return "Close"
        case .ja:   return "閉じる"
        case .zhTW: return "關閉"
        }
    }
    func historyKeeperLabel() -> String {
        switch language {
        case .en:   return "kept:"
        case .ja:   return "残した："
        case .zhTW: return "保留："
        }
    }
    func historyReasonLabel() -> String {
        switch language {
        case .en:   return "reason:"
        case .ja:   return "理由："
        case .zhTW: return "原因："
        }
    }
    /// Human-readable, localized reason a photo was in a deletion batch. This is
    /// the surface where the app's honest attribution shows — app-seeded exact
    /// marks must read differently from the user's own force-removals.
    /// The log's own wording for a deletion. The three reasons the review
    /// surfaces also use FORWARD to `deleteWhy` rather than keeping a second
    /// copy: the history panel is the fourth surface describing one deletion,
    /// and it used to phrase all three differently.
    /// (`.burstNonKeeper` is decode-compat only — never written; see
    /// `DeletionAuditLog.DeletionReason`.)
    func historyReasonName(_ reason: DeletionReason) -> String {
        switch language {
        case .en:
            switch reason {
            case .exactDuplicate:                 return deleteWhy(.exactDuplicate)
            case .userRejected:                   return deleteWhy(.userRejected)
            case .forceIncludedProtectedFavorite: return "you force-removed (favorite)"
            case .forceIncludedProtectedEdited:   return "you force-removed (edited)"
            case .forceIncludedProtectedDocument: return "you force-removed (document)"
            case .forceIncludedProtectedMultiple: return "you force-removed (protected)"
            case .burstNonKeeper:                 return deleteWhy(.notPicked)
            case .blurry:                         return "blurry"
            }
        case .ja:
            switch reason {
            case .exactDuplicate:                 return deleteWhy(.exactDuplicate)
            case .userRejected:                   return deleteWhy(.userRejected)
            case .forceIncludedProtectedFavorite: return "強制削除（お気に入り）"
            case .forceIncludedProtectedEdited:   return "強制削除（編集済み）"
            case .forceIncludedProtectedDocument: return "強制削除（書類）"
            case .forceIncludedProtectedMultiple: return "強制削除（保護対象）"
            case .burstNonKeeper:                 return deleteWhy(.notPicked)
            case .blurry:                         return "ブレ"
            }
        case .zhTW:
            switch reason {
            case .exactDuplicate:                 return deleteWhy(.exactDuplicate)
            case .userRejected:                   return deleteWhy(.userRejected)
            case .forceIncludedProtectedFavorite: return "你強制移除（最愛）"
            case .forceIncludedProtectedEdited:   return "你強制移除（已編輯）"
            case .forceIncludedProtectedDocument: return "你強制移除（文件）"
            case .forceIncludedProtectedMultiple: return "你強制移除（受保護）"
            case .burstNonKeeper:                 return deleteWhy(.notPicked)
            case .blurry:                         return "模糊"
            }
        }
    }
    /// Title line of the exported plain-text deletion log.
    func historyExportTitle() -> String {
        switch language {
        case .en:   return "snapsift Deletion History"
        case .ja:   return "snapsift 削除履歴"
        case .zhTW: return "snapsift 刪除記錄"
        }
    }
    /// Body of the export when there is no history.
    func historyExportEmpty() -> String {
        switch language {
        case .en:   return "No deletion history."
        case .ja:   return "削除履歴はありません。"
        case .zhTW: return "沒有刪除記錄。"
        }
    }
    /// Placeholder for an unresolvable recovery deadline in the export.
    func historyUnknown() -> String {
        switch language {
        case .en:   return "unknown"
        case .ja:   return "不明"
        case .zhTW: return "未知"
        }
    }
    /// Keeper value for a no-survivor group — every frame (keeper included) was
    /// force-rejected, so there is honestly no survivor to name.
    func historyNoSurvivor() -> String {
        switch language {
        case .en:   return "(no survivor)"
        case .ja:   return "（残りなし）"
        case .zhTW: return "（無保留）"
        }
    }

    // MARK: - Pass 2b — save rotation to Photos

    /// Button label for the "Save Rotation" affordance (grid + loupe).
    func saveRotationButton() -> String {
        switch language {
        case .en:   return "Save Rotation"
        case .ja:   return "回転を保存"
        case .zhTW: return "儲存旋轉"
        }
    }

    /// Alert title for the save-rotation confirmation.
    func saveRotationConfirmTitle() -> String {
        switch language {
        case .en:   return "Save Rotation to Photos?"
        case .ja:   return "写真に回転を保存しますか？"
        case .zhTW: return "將旋轉儲存至「照片」？"
        }
    }

    /// Alert body for the save-rotation confirmation — explains reversibility
    /// and warns that saving marks the photo as edited (= becomes protected).
    func saveRotationConfirmBody() -> String {
        switch language {
        case .en:
            return "Saves the rotated view permanently to your Photos library. The original is preserved — you can Revert to Original in Photos anytime.\n\nNote: saving marks this photo as edited, so snapsift will treat it as a protected frame."
        case .ja:
            return "回転した表示を写真ライブラリに永久に保存します。オリジナルは保持されます — 写真アプリでいつでも「オリジナルに戻す」ことができます。\n\n注意：保存するとこの写真は「編集済み」扱いになり、snapsift は保護フレームとして扱います。"
        case .zhTW:
            return "將旋轉後的樣子永久儲存到你的「照片」圖庫。原始檔會被保留 — 你隨時可以在「照片」中選擇「回復到原始項目」。\n\n注意：儲存後這張照片會被標記為已編輯，snapsift 將把它視為受保護的格。"
        }
    }

    /// Confirm button label in the save-rotation alert.
    func saveRotationConfirmButton() -> String {
        switch language {
        case .en:   return "Save"
        case .ja:   return "保存"
        case .zhTW: return "儲存"
        }
    }

    /// Cancel button label in the save-rotation alert (reuses global cancel).
    func saveRotationCancelButton() -> String {
        switch language {
        case .en:   return "Cancel"
        case .ja:   return "キャンセル"
        case .zhTW: return "取消"
        }
    }

    /// Success banner shown after a rotation is saved to Photos.
    func saveRotationSuccessBanner() -> String {
        switch language {
        case .en:   return "Rotation saved to Photos · revert anytime in Photos"
        case .ja:   return "写真に回転を保存しました · いつでも元に戻せます"
        case .zhTW: return "旋轉已儲存至「照片」· 可隨時在「照片」中還原"
        }
    }

    /// Alert title when save-rotation fails.
    func saveRotationErrorTitle() -> String {
        switch language {
        case .en:   return "Couldn't save rotation"
        case .ja:   return "回転を保存できませんでした"
        case .zhTW: return "無法儲存旋轉"
        }
    }

    /// Localized body for the save-rotation error alert. Keeps the mixed-language
    /// seam closed: RotationSaveError's own errorDescription is English-only, so
    /// map the case here instead of surfacing err.localizedDescription raw.
    func saveRotationErrorBody(_ error: Error) -> String {
        // guard-let, not `switch optional`: a plain enum switch is exhaustive on
        // every toolchain (the `true`/`false`/`nil` form over an Optional is not,
        // and cost the CI build a compile error), and the compiler still forces a
        // translation for any case added later — the point of this file.
        guard let rotationError = error as? RotationSaveError else {
            return error.localizedDescription
        }
        switch rotationError {
        case .noEditingInput:
            switch language {
            case .en:   return "Couldn't get editing access to this photo. Try again, or check that snapsift has Full Photos access."
            case .ja:   return "この写真の編集アクセスを取得できませんでした。もう一度試すか、snapsift に「フルアクセス」があるか確認してください。"
            case .zhTW: return "無法取得這張照片的編輯權限。請再試一次，或確認 snapsift 已取得「完整取用權限」。"
            }
        case .noSourceImage:
            switch language {
            case .en:   return "Couldn't load the full-size original. The photo may still be downloading from iCloud."
            case .ja:   return "フルサイズのオリジナルを読み込めませんでした。iCloud からまだダウンロード中の可能性があります。"
            case .zhTW: return "無法載入完整原始檔，這張照片可能還在從 iCloud 下載。"
            }
        case .renderFailed:
            switch language {
            case .en:   return "Couldn't render the rotated image."
            case .ja:   return "回転した画像を生成できませんでした。"
            case .zhTW: return "無法產生旋轉後的影像。"
            }
        case .photoKitWriteFailed(let underlying):
            switch language {
            case .en:   return "Photos couldn't save the rotation: \(underlying.localizedDescription)"
            case .ja:   return "写真が回転を保存できませんでした：\(underlying.localizedDescription)"
            case .zhTW: return "「照片」無法儲存旋轉：\(underlying.localizedDescription)"
            }
        case .frameAlreadyEdited:
            switch language {
            case .en:   return "This photo already has your own edits. Saving a rotation would flatten them into a new version and \"Revert to Original\" would lose your crop, so snapsift won't do it. Rotate it in Photos instead — the display rotation here stays."
            case .ja:   return "この写真にはすでにご自身の編集があります。回転を保存すると編集が統合され、「オリジナルに戻す」でトリミングまで失われるため、snapsift は保存しません。写真アプリで回転してください — ここでの表示回転はそのまま残ります。"
            case .zhTW: return "這張照片已經有你自己的編輯。儲存旋轉會把那些編輯壓平成新版本，「回復到原始項目」連裁切也會一起失去，所以 snapsift 不會這麼做。請改在「照片」裡旋轉 —— 這裡的顯示旋轉會保留。"
            }
        case .frameEditStateUnknown:
            // Says what is actually true — "we could not read it" — rather than
            // asserting the photo IS edited. This is the only path in the app
            // that rewrites a photo, so an honest refusal beats a confident one.
            switch language {
            case .en:   return "snapsift can't read whether this photo has your own edits right now (no Full Disk Access, or the Photos library in use couldn't be confirmed). Saving a rotation would flatten any edits it does have, so snapsift won't do it while it can't check. Rotate it in Photos instead — the display rotation here stays."
            case .ja:   return "この写真にご自身の編集があるかどうか、いま snapsift には読み取れません（フルディスクアクセスがない、または使用中の写真ライブラリを確認できませんでした）。編集があった場合は回転の保存で統合されてしまうため、確認できないあいだは保存しません。写真アプリで回転してください — ここでの表示回転はそのまま残ります。"
            case .zhTW: return "snapsift 現在讀不到這張照片有沒有你自己的編輯（沒有「完整磁碟取用權限」，或無法確認正在使用哪一座「照片」圖庫）。萬一有編輯，儲存旋轉會把它壓平，所以在確認得了之前不會儲存。請改在「照片」裡旋轉 —— 這裡的顯示旋轉會保留。"
            }
        }
    }
    /// Dismiss button for the save-rotation error alert.
    func saveRotationErrorDismiss() -> String {
        switch language {
        case .en:   return "Dismiss"
        case .ja:   return "閉じる"
        case .zhTW: return "關閉"
        }
    }

    /// Tooltip for the Save Rotation button.
    func tipSaveRotation() -> String {
        switch language {
        case .en:   return "Save this display rotation permanently to Photos (⇧⌘R) · reversible via Revert to Original"
        case .ja:   return "この表示回転を写真に永久保存（⇧⌘R）· オリジナルに戻すことで取り消せます"
        case .zhTW: return "將此顯示旋轉永久儲存至「照片」（⇧⌘R）· 可透過「回復到原始項目」復原"
        }
    }

    // MARK: scan-completion feedback

    /// Banner after a scan that found something. `n` = review sets found.
    func scanDoneBanner(_ n: Int) -> String {
        switch language {
        case .en: return "Scan complete — \(n) set\(n == 1 ? "" : "s") to review"
        case .ja: return "スキャン完了 — 確認する組は \(n) 件"
        case .zhTW: return "掃描完成：找到 \(n) 組可檢視"
        }
    }
    /// Suffix appended to the scan-complete banner when some videos could not
    /// be verified as Live Photo paired videos (photolibraryd unresponsive)
    /// and were excluded to be safe — the scan must say so rather than
    /// silently narrow its scope.
    func scanPairedVideosSkipped(_ n: Int) -> String {
        switch language {
        case .en: return "\(n) video\(n == 1 ? "" : "s") couldn't be checked for Live Photo pairing, so \(n == 1 ? "it was" : "they were") left out to be safe."
        case .ja: return "Live Photos のペア動画かどうか確認できなかったビデオ \(n) 本は、安全のため対象から外しました。"
        case .zhTW: return "有 \(n) 部影片無法確認是否為原況照片的配對影片，為了安全先排除。"
        }
    }
    /// Banner after a scan that found nothing.
    func scanDoneNothing() -> String {
        switch language {
        case .en: return "Scan complete — nothing found. Your library looks clean."
        case .ja: return "スキャン完了 — 見つかりませんでした。ライブラリはきれいです。"
        case .zhTW: return "掃描完成：沒有找到，你的圖庫很乾淨。"
        }
    }
    /// Empty-state hint AFTER a scan ran and found nothing (distinct from the
    /// pre-scan "pick what to look for" hint — the user must be able to tell
    /// "haven't scanned" from "scanned, nothing found").
    func scannedEmptyHint() -> String {
        switch language {
        case .en: return "The last scan found nothing here.\nTry another scan type or source."
        case .ja: return "直前のスキャンでは何も見つかりませんでした。\n別のスキャン種類やソースを試してください。"
        case .zhTW: return "上次掃描沒有找到任何結果。\n可以換一種掃描或換個來源試試。"
        }
    }

    /// Banner after the user cancels an in-flight scan.
    func scanCancelled() -> String {
        switch language {
        case .en: return "Scan cancelled"
        case .ja: return "スキャンをキャンセルしました"
        case .zhTW: return "已取消掃描"
        }
    }
    /// The cancel button shown while a scan is running.
    func cancelScanButton() -> String {
        switch language {
        case .en: return "Cancel"
        case .ja: return "キャンセル"
        case .zhTW: return "取消"
        }
    }

    /// Title of the confirmation shown when a scan would discard pending marks.
    func rescanDiscardTitle() -> String {
        switch language {
        case .en: return "Discard pending marks?"
        case .ja: return "未確定のマークを破棄しますか？"
        case .zhTW: return "要捨棄還沒執行的標記嗎？"
        }
    }
    /// Body — n = user-made marks (app-seeded suggestions are re-derived by the rescan).
    func rescanDiscardBody(_ n: Int) -> String {
        switch language {
        case .en: return "A new scan discards the \(n) mark\(n == 1 ? "" : "s") you haven't committed yet. This can't be undone."
        case .ja: return "新しいスキャンを開始すると、まだ確定していない \(n) 件のマークが破棄されます。元に戻せません。"
        case .zhTW: return "重新掃描會捨棄你還沒執行刪除的 \(n) 個標記，捨棄後無法復原。"
        }
    }
    /// Destructive confirm button of the rescan dialog.
    func rescanDiscardConfirm() -> String {
        switch language {
        case .en: return "Discard and Scan"
        case .ja: return "破棄してスキャン"
        case .zhTW: return "捨棄並掃描"
        }
    }
    /// Cancel button of the rescan dialog.
    func rescanDiscardCancel() -> String {
        switch language {
        case .en: return "Cancel"
        case .ja: return "キャンセル"
        case .zhTW: return "取消"
        }
    }

    // MARK: snapshot restore

    /// Banner when the last scan was restored from disk on launch.
    func snapshotRestored(_ n: Int) -> String {
        switch language {
        case .en: return "Restored your last scan — \(n) set\(n == 1 ? "" : "s"), decisions included"
        case .ja: return "前回のスキャンを復元しました — \(n) 組（判定も含む）"
        case .zhTW: return "已還原上次掃描：\(n) 組（含你的標記）"
        }
    }
    /// Same, but the library changed since the snapshot was taken — the app's own
    /// suggestions were cleared, so say so rather than a vague "consider rescanning".
    func snapshotRestoredStale() -> String {
        switch language {
        case .en: return "Restored your last scan — the library changed since, so app suggestions were cleared. Rescan to re-verify."
        case .ja: return "前回のスキャンを復元しました — その後ライブラリが変わったため、アプリの提案は解除しました。再スキャンで確認し直せます。"
        case .zhTW: return "已還原上次掃描：圖庫在那之後有變動，因此已清除 App 的建議。重新掃描即可重新驗證。"
        }
    }

    /// Persistent inline bar shown when a stale-token restore dropped N app-seeded
    /// suggestions — a launch banner fades before the user (who may have relaunched
    /// in the background) looks, so this stands until they rescan or dismiss it.
    func staleRestoreBar(_ n: Int) -> String {
        switch language {
        case .en: return "Library changed since your last scan — \(n) duplicate suggestions cleared. Rescan to re-verify."
        case .ja: return "前回のスキャン後にライブラリが変わりました — 重複の提案 \(n) 件を解除しました。再スキャンで確認し直せます。"
        case .zhTW: return "上次掃描後圖庫有變動：已清除 \(n) 項重複建議。重新掃描即可重新驗證。"
        }
    }
    /// Rescan button in the stale-restore bar.
    func staleRestoreRescan() -> String {
        switch language {
        case .en: return "Rescan"
        case .ja: return "再スキャン"
        case .zhTW: return "重新掃描"
        }
    }
    /// Accessibility label for the stale-restore bar's dismiss (×) button.
    func staleRestoreDismiss() -> String {
        switch language {
        case .en: return "Dismiss"
        case .ja: return "閉じる"
        case .zhTW: return "關閉"
        }
    }

    /// Banner when a snapshot write failed (disk full is the target user's normal
    /// state) — review decisions live only in that file, so warn before they quit.
    func snapshotSaveFailed() -> String {
        switch language {
        case .en: return "Couldn't save your review progress (disk full?) — free up space before quitting or your decisions won't survive relaunch."
        case .ja: return "レビューの進行状況を保存できませんでした（ディスクの空き容量不足？）— 終了する前に空き容量を確保しないと、判定が次回起動時に失われます。"
        case .zhTW: return "無法儲存你的檢視進度（磁碟空間不足？）— 結束前請先釋放空間，否則你的判斷不會保留到下次開啟。"
        }
    }
    /// Banner when a saved session file existed but couldn't be read (corrupt
    /// file or an old schema) — must never pass silently as a fresh start.
    func snapshotUnreadable() -> String {
        switch language {
        case .en: return "Couldn't read your last session's file — starting fresh. The unreadable file was kept next to it as last-scan.unreadable.json."
        case .ja: return "前回のセッションのファイルを読み込めなかったため、新規に開始します。読み込めなかったファイルは last-scan.unreadable.json として同じ場所に残してあります。"
        case .zhTW: return "無法讀取你上次的工作階段檔案，已重新開始。無法讀取的檔案保留在原位，名為 last-scan.unreadable.json。"
        }
    }
    /// Appended to the delete-completion banner when the audit line couldn't be
    /// written — the delete stands but its accountability record is missing.
    func commitAuditFailed() -> String {
        switch language {
        case .en: return "audit record couldn't be written (disk full?)"
        case .ja: return "監査記録を書き込めませんでした（ディスクの空き容量不足？）"
        case .zhTW: return "但無法寫入稽核記錄（磁碟空間不足？）"
        }
    }

    // MARK: album-write failure (persistent, like delete failure)

    func albumsWriteFailedTitle() -> String {
        switch language {
        case .en: return "Couldn't sort into albums"
        case .ja: return "アルバムへの整理に失敗しました"
        case .zhTW: return "無法整理進相簿"
        }
    }

    // MARK: Full Disk Access visibility

    /// Shown in the status bar when the quality/size sidecar wasn't readable, so
    /// the missing "X MB freed" estimate is explained instead of silently absent.
    func fdaHint() -> String {
        switch language {
        case .en: return "Want to know how much space this frees? Turn on Full Disk Access"
        case .ja: return "どれだけ空くか知りたいときは「フルディスクアクセス」を許可"
        case .zhTW: return "想知道能省下多少空間？可以開啟「完整磁碟取用權限」"
        }
    }
    func fdaHintHelp() -> String {
        switch language {
        case .en: return "Turn it on and snapsift can tell you how much space you would free, and use your photo library's own quality scores to pick the best shot. It reads two things only — how big each photo file is, and those scores — and touches no other file. Scans work without it; only the space figure is missing. Click to open System Settings."
        case .ja: return "許可すると、どれだけ空くかを表示でき、写真ライブラリ自身の品質スコアでベストの1枚を選べます。読み取るのは写真ファイルのサイズとそのスコアだけで、ほかのファイルには触れません。許可しなくてもスキャンはできます。表示されないのは空き容量だけです。クリックでシステム設定を開きます。"
        case .zhTW: return "開啟之後，snapsift 才能告訴你能省下多少空間，也才能用圖庫自己的品質分數挑出最好的一張。它只讀兩樣東西：每張照片檔案多大，以及那些分數，不會碰其他檔案。沒開也能掃描，少的只是那個空間數字。按一下開啟「系統設定」。"
        }
    }

    // MARK: loupe HUD status words

    func loupeKeeper() -> String {
        switch language {
        case .en: return "★ keeping"
        case .ja: return "★ 残す"
        case .zhTW: return "★ 保留"
        }
    }
    func loupeReject() -> String {
        switch language {
        case .en: return "✕ reject"
        case .ja: return "✕ 削除予定"
        case .zhTW: return "✕ 待刪"
        }
    }
    func loupeFav() -> String {
        switch language {
        case .en: return "★ fav"
        case .ja: return "★ お気に入り"
        case .zhTW: return "★ 最愛"
        }
    }
    func loupeEdited() -> String {
        switch language {
        case .en: return "✎ edited"
        case .ja: return "✎ 編集済み"
        case .zhTW: return "✎ 已編輯"
        }
    }
    func loupeDoc() -> String {
        switch language {
        case .en: return "doc"
        case .ja: return "書類"
        case .zhTW: return "文件"
        }
    }
    func loupeNoDecision() -> String {
        switch language {
        case .en: return "no decision"
        case .ja: return "未判定"
        case .zhTW: return "尚未決定"
        }
    }

    // MARK: history sheet

    /// "… and N more" truncation line in the deletion-history sheet.
    func historyMore(_ n: Int) -> String {
        switch language {
        case .en: return "… and \(n) more (export to see all)"
        case .ja: return "… ほか \(n) 件（すべて見るには書き出し）"
        case .zhTW: return "…還有 \(n) 筆（匯出可看全部）"
        }
    }

    // MARK: deleting lock

    /// Full-window overlay while the PhotoKit delete (and its system
    /// confirmation) is in flight — input is locked so a stray keypress can't
    /// mutate the review state mid-delete.
    func deletingOverlay() -> String {
        switch language {
        case .en: return "Moving your photos to Recently Deleted — you can get them back for 30 days. If Photos asks you to confirm, allow it and this carries on."
        case .ja: return "写真を「最近削除した項目」に移動しています。30日以内なら元に戻せます。「写真」の確認画面が出たら、許可すると続きます。"
        case .zhTW: return "正在把照片移到「最近刪除」，30 天內都可以復原。如果「照片」跳出確認框，按一下允許就會繼續。"
        }
    }

    /// Count-aware variant: a large commit can hold the window for minutes, so the
    /// overlay names how many photos and sets the expectation up front.
    func deletingOverlay(_ count: Int) -> String {
        switch language {
        case .en: return "Moving \(count) photo\(count == 1 ? "" : "s") to Recently Deleted — you can get them back for 30 days. With this many it takes a moment. If Photos asks you to confirm, allow it and this carries on."
        case .ja: return "\(count) 枚を「最近削除した項目」に移動しています。30日以内なら元に戻せます。枚数が多いので少し時間がかかります。「写真」の確認画面が出たら、許可すると続きます。"
        case .zhTW: return "正在把 \(count) 張照片移到「最近刪除」，30 天內都可以復原。張數多時會需要一點時間。如果「照片」跳出確認框，按一下允許就會繼續。"
        }
    }

    /// Per-group row header in the pre-commit sheet when the whole group is
    /// being removed and no keeper survives.
    func preCommitNoSurvivorRow() -> String {
        switch language {
        case .en: return "Entire group removed — no photo kept"
        case .ja: return "グループ全体を削除 — 残る写真はありません"
        case .zhTW: return "整組刪除：沒有任何一張會留下"
        }
    }

    // MARK: - Protection-degradation surfaces (never silent)

    /// Persistent bar after a commit withdrew whole groups because the photo
    /// they promised to keep no longer exists.
    func commitKeeperMissing(_ n: Int) -> String {
        switch language {
        case .en: return "held \(n) group\(n == 1 ? "" : "s") — the photo they would keep is gone from your library; scan again to choose another one to keep"
        case .ja: return "\(n)グループを保留 — 残すはずの写真がライブラリにありません。もう一度スキャンすると、残す1枚を選び直します"
        case .zhTW: return "有 \(n) 組暫緩 —— 原本要留下的那張已不在圖庫中，請重新掃描以重選要保留的照片"
        }
    }

    /// Groups withheld because EVERY frame they would have left behind is gone
    /// from the library — committing would have left zero copies of the image.
    func commitNoSurvivorLeft(_ n: Int) -> String {
        switch language {
        case .en: return "held \(n) group\(n == 1 ? "" : "s") — the photo\(n == 1 ? "" : "s") they would have left behind\(n == 1 ? " is" : " are") gone from your library, so deleting the rest would have left no copy at all"
        case .ja: return "\(n)グループを保留 — 残るはずだった写真がライブラリにないため、他を削除すると1枚も残らなくなります"
        case .zhTW: return "有 \(n) 組暫緩 —— 原本會留下的那張已不在圖庫中，再刪其餘的就一張都不剩了"
        }
    }

    /// The commit was blocked by another library write in flight.
    func commitBusy() -> String {
        switch language {
        case .en: return "Nothing was deleted — another library write is still running. Wait for it to finish and try again."
        case .ja: return "削除は行われていません — 別のライブラリ書き込みが実行中です。完了してからもう一度お試しください。"
        case .zhTW: return "沒有刪除任何東西 —— 另一項圖庫寫入還在進行。請等它結束後再試一次。"
        }
    }

    /// Standing notice: some frames' edit state could not be read, so they are
    /// protected rather than assumed unedited.
    func protectionDegraded(_ n: Int) -> String {
        switch language {
        case .en: return "\(n) frame\(n == 1 ? "'s" : "s'") edit state couldn't be read — protected until it can be verified"
        case .ja: return "\(n)枚の編集状態を読み取れませんでした — 確認できるまで保護されます"
        case .zhTW: return "有 \(n) 張的編輯狀態讀不到 —— 在能確認之前一律受保護"
        }
    }

    /// Standing notice: the sidecar we can read is not provably the library
    /// Photos is serving, so edit protection falls back / degrades.
    /// Why the library the sidecar reads could not be confirmed. Four different
    /// findings, four different sentences: "we could not check" and "the file we
    /// read is frozen" are not the same news, and a banner that states the
    /// second when only the first is true invents a fact about someone's
    /// library. All four end the same way, because the consequence is the same.
    func libraryUnverified(_ reason: UnverifiedReason) -> String {
        let tail: String
        switch language {
        case .en: tail = " snapsift protects anything it can't check and won't pre-mark."
        case .ja: tail = " snapsift は確認できないものをすべて保護し、事前マークも行いません。"
        case .zhTW: tail = " snapsift 會保護所有無法檢查的照片，也不會預先標記。"
        }
        switch reason {
        case .pathUnknown:
            switch language {
            case .en: return "Can't confirm which Photos library this Mac is using, so edits can't be verified from it —" + tail
            case .ja: return "この Mac が使用している写真ライブラリを特定できないため、編集状態をそこから確認できません —" + tail
            case .zhTW: return "無法確認這台 Mac 正在使用哪一座「照片」圖庫，因此無法從中確認編輯狀態 ——" + tail
            }
        case .pathMismatch:
            switch language {
            case .en: return "The Photos library in use isn't available right now (an external disk, or it moved), so snapsift is reading an older copy for ranking only — edits can't be verified from it." + tail
            case .ja: return "使用中の写真ライブラリに今アクセスできないため（外部ディスク、または移動された可能性）、snapsift は並べ替え用に古いコピーだけを読んでいます — 編集状態はそこからは確認できません。" + tail
            case .zhTW: return "現在讀不到正在使用的那座「照片」圖庫（可能在外接磁碟，或已被移動），snapsift 只拿一份較舊的副本來排序 —— 編輯狀態無法從中確認。" + tail
            }
        case .staleContents:
            switch language {
            case .en: return "The Photos library file snapsift can read is missing photos Photos itself can see, so it's an old copy, not the live library — edits can't be verified from it." + tail
            case .ja: return "snapsift が読める写真ライブラリのファイルには、写真アプリ側にある写真が入っていません。つまり古いコピーであり、現在のライブラリではありません — 編集状態はそこからは確認できません。" + tail
            case .zhTW: return "snapsift 讀得到的那個「照片」圖庫檔案裡，少了「照片」App 看得到的照片，所以那是一份舊副本、不是正在用的圖庫 —— 編輯狀態無法從中確認。" + tail
            }
        case .probeUnavailable:
            switch language {
            case .en: return "Can't check the Photos library right now (it's busy, or unreadable), so snapsift can't confirm the edit states it reads are current." + tail
            case .ja: return "いま写真ライブラリを確認できません（使用中か、読み取れません）。読み取った編集状態が最新かどうか確認できません。" + tail
            case .zhTW: return "現在無法檢查「照片」圖庫（正在忙，或讀不到），因此無法確認讀到的編輯狀態是不是最新的。" + tail
            }
        }
    }

    /// Exact duplicates NOT pre-marked because the copy carries album
    /// membership / a caption the keeper doesn't (or that couldn't be read).
    func uniqueMetadataWithheld(_ n: Int) -> String {
        switch language {
        case .en: return "\(n) identical copy\(n == 1 ? "" : "s") left unmarked — that copy is in an album, or carries a caption, that the one we'd keep doesn't"
        case .ja: return "\(n)枚の完全に同じ写真はマークしていません — そのコピーは、残す1枚にはないアルバムや説明を持っています"
        case .zhTW: return "有 \(n) 張完全重複沒有預先標記 —— 那一份帶有保留照片所沒有的相簿或說明"
        }
    }

    /// Standing notice: N frames/videos this review set could not classify at
    /// all (edit state unreadable, document eval ran blind, or a video's Live
    /// Photo pairing undetermined). Never delete candidates. Takes the ACTUAL
    /// localized album title as a parameter so the notice can never drift out
    /// of sync with `AlbumWriter`'s naming.
    func unverifiableInAlbum(_ n: Int, album: String) -> String {
        switch language {
        case .en: return "\(n) photo\(n == 1 ? "" : "s") couldn't be classified. Sort into albums to collect \(n == 1 ? "it" : "them") in “\(album)” — you decide there."
        case .ja: return "\(n)枚を分類できませんでした。「アルバムに仕分け」で「\(album)」に集めます — そこで判断してください。"
        case .zhTW: return "有 \(n) 張無法判定。用「整理進相簿」收進「\(album)」，交給你決定。"
        }
    }

    /// Per-frame badge in the pre-commit sheet.
    func preCommitUniqueMetadata() -> String {
        switch language {
        case .en: return "carries albums or a caption the kept photo doesn't"
        case .ja: return "残す写真にないアルバム／説明を持っています"
        case .zhTW: return "帶有保留照片所沒有的相簿或說明"
        }
    }

    /// Deletion history repaired from an interrupted commit's journal.
    func journalRecovered(_ n: Int) -> String {
        switch language {
        case .en: return "Added \(n) deletion\(n == 1 ? "" : "s") from an interrupted session to your history — they are in Recently Deleted."
        case .ja: return "中断されたセッションの削除\(n)件を履歴に追加しました — 「最近削除した項目」にあります。"
        case .zhTW: return "已把上次中斷的工作階段中的 \(n) 筆刪除補進歷史紀錄 —— 它們在「最近刪除」裡。"
        }
    }

    /// Marks lost on restore because the photo no longer exists.
    func vanishedMarks(_ n: Int) -> String {
        switch language {
        case .en: return "\(n) marked photo\(n == 1 ? "" : "s") no longer exist\(n == 1 ? "s" : "") — removed outside snapsift since the scan"
        case .ja: return "マークしていた\(n)枚がもう存在しません — スキャン後に snapsift 以外で削除されています"
        case .zhTW: return "有 \(n) 張標記過的照片已不存在 —— 掃描後被 snapsift 以外的方式刪掉了"
        }
    }

    /// A bulk "delete every frame" left some frames out because they could not
    /// be classified — the button promised protected photos stay safe.
    func bulkRejectWithheld(_ n: Int) -> String {
        switch language {
        case .en: return "\(n) frame\(n == 1 ? "" : "s") couldn't be classified and stayed unmarked"
        case .ja: return "\(n)枚は分類できなかったため、マークしていません"
        case .zhTW: return "有 \(n) 張無法判定，沒有列入標記"
        }
    }

    /// Header warning in the pre-commit sheet: N groups are shown but withheld.
    func preCommitWithdrawnWarning(_ n: Int) -> String {
        switch language {
        case .en: return "\(n) group\(n == 1 ? " is" : "s are") not being deleted: the photo\(n == 1 ? "" : "s") they would leave behind no longer exist\(n == 1 ? "s" : "") in your library."
        case .ja: return "\(n)グループは削除しません：残すはずの写真がライブラリにもう存在しません。"
        case .zhTW: return "有 \(n) 組不會刪除：原本會留下的那張照片已不在你的圖庫中。"
        }
    }

    /// Per-row label for a withdrawn group. The two reasons are different news:
    /// "the one we named is gone" vs "nothing at all would be left".
    func preCommitWithdrawnRow(_ reason: GroupWithdrawal) -> String {
        switch reason {
        case .keeperMissing:
            switch language {
            case .en: return "Skipped — the one to keep isn't there any more, so nothing here is removed"
            case .ja: return "スキップ — 残すはずの1枚がもうありません。このグループは削除しません"
            case .zhTW: return "略過 —— 要留下的那張已經不在了，這組不會刪"
            }
        case .noSurvivorLeft:
            switch language {
            case .en: return "Skipped — this group would have nothing left at all"
            case .ja: return "スキップ — このグループに1枚も残らなくなります"
            case .zhTW: return "略過 —— 這組會一張都不剩"
            }
        }
    }

    // MARK: similar-set naming

    /// Fallback name when no Vision tag resolves for a similar-set bucket.
    func setFallbackName() -> String {
        switch language {
        case .en: return "Set"
        case .ja: return "セット"
        case .zhTW: return "組合"
        }
    }
}
