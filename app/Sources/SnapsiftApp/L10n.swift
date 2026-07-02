import Foundation

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
    func progClassifying(_ i: Int, _ total: Int) -> String {
        switch language {
        case .en: return "Classifying \(i)/\(total)…"
        case .ja: return "分類中 \(i)/\(total)…"
        case .zhTW: return "分類中 \(i)/\(total)…"
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
        case .zhTW: return "鍵盤快捷"
        }
    }
    func helpClose() -> String {
        switch language {
        case .en: return "Close"
        case .ja: return "閉じる"
        case .zhTW: return "關閉"
        }
    }
    /// (keys, what it does) rows for the keyboard cheat sheet.
    func helpRows() -> [(String, String)] {
        switch language {
        case .en: return [
            // List zone
            ("↑ ↓ / j k",     "Move between groups"),
            ("→ / l / ⏎",     "Enter frames"),
            ("a",              "Keep whole group"),
            ("d",              "Reject whole group"),
            // Grid zone
            ("← → ↑ ↓ / hjkl","Move between frames"),
            ("Space",          "Open loupe"),
            ("X / ⌫",          "Reject frame · toggle"),
            ("⏎",              "Keep frame + set keeper ★"),
            ("⇧X",             "Force-reject protected frame"),
            ("R / ⇧R",         "Rotate frame · display only"),
            ("Esc",            "Back to list"),
            // Loupe zone
            ("← → / h l",     "Loupe: prev / next frame"),
            ("R / ⇧R",         "Loupe: rotate · display only"),
            ("Space / Esc",    "Close loupe"),
            // Global
            ("⌘⌫",             "Commit — delete all rejected"),
            ("⌘⏎",             "Review sheet: confirm delete"),
            ("?",              "This cheat sheet"),
        ]
        case .ja: return [
            ("↑ ↓ / j k",     "グループを移動"),
            ("→ / l / ⏎",     "写真へ入る"),
            ("a",              "グループ全部を残す"),
            ("d",              "グループ全部を却下"),
            ("← → ↑ ↓ / hjkl","写真を移動"),
            ("スペース",        "ルーペを開く"),
            ("X / ⌫",          "フレームを却下・切替"),
            ("⏎",              "このフレームを残す ★"),
            ("⇧X",             "保護フレームを強制削除"),
            ("R / ⇧R",         "フレームを回転・表示のみ"),
            ("Esc",            "リストへ戻る"),
            ("← → / h l",     "ルーペ：前／次"),
            ("R / ⇧R",         "ルーペ：回転・表示のみ"),
            ("スペース / Esc", "ルーペを閉じる"),
            ("⌘⌫",             "削除を実行"),
            ("⌘⏎",             "確認シート：削除を確定"),
            ("?",              "このキー一覧"),
        ]
        case .zhTW: return [
            ("↑ ↓ / j k",     "上一群／下一群"),
            ("→ / l / ⏎",     "進入格子"),
            ("a",              "整群保留"),
            ("d",              "整群標刪"),
            ("← → ↑ ↓ / hjkl","格子間移動"),
            ("空白",            "開啟放大鏡"),
            ("X / ⌫",          "標刪這張・切換"),
            ("⏎",              "保留這張並設為主保留 ★"),
            ("⇧X",             "強制標刪受保護的張"),
            ("R / ⇧R",         "旋轉這張・僅顯示用"),
            ("Esc",            "回到清單"),
            ("← → / h l",     "放大鏡：前一張／後一張"),
            ("R / ⇧R",         "放大鏡：旋轉・僅顯示用"),
            ("空白 / Esc",     "關閉放大鏡"),
            ("⌘⌫",             "執行刪除所有標刪"),
            ("⌘⏎",             "審核視窗：確認刪除"),
            ("?",              "這張快捷小抄"),
        ]
        }
    }
    func searchPrompt(_ smart: Bool) -> String {
        switch language {
        case .en: return smart ? "Search · ↩ for smart match" : "Filter categories"
        case .ja: return smart ? "検索 · ↩ でスマート検索" : "カテゴリを絞り込む"
        case .zhTW: return smart ? "搜尋 · ↩ 智慧比對" : "篩選類別"
        }
    }

    // MARK: permission gate
    //
    // The request screen reuses privacyPitch() for its body — it's the same
    // promise as the first-run onboarding, so there's only one set of strings to
    // keep honest. The "Grant access" button supplies the call to action.

    func gateRequestButton() -> String {
        switch language {
        case .en: return "Grant access"
        case .ja: return "アクセスを許可"
        case .zhTW: return "授予存取權"
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
        case .en: return "snapsift needs Full Photos access to find and remove duplicates across your whole library.\n\nYou've currently granted \"Selected Photos\" — snapsift can't see or delete photos outside that selection. Open System Settings ▸ Privacy & Security ▸ Photos and set snapsift to Full Access."
        case .ja: return "snapsift は重複写真をライブラリ全体で検索・削除するために、「すべての写真」へのアクセスが必要です。\n\n現在「選択した写真」のみが許可されています。システム設定 ▸ プライバシーとセキュリティ ▸ 写真 を開き、snapsift を「フルアクセス」に変更してください。"
        case .zhTW: return "snapsift 需要「完整照片」存取權限，才能掃描整個圖庫並刪除重複照片。\n\n你目前授予的是「已選取的照片」—— snapsift 無法看到或刪除選取範圍以外的照片。請到 系統設定 ▸ 隱私權與安全性 ▸ 照片，把 snapsift 改成「完整存取」。"
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
        case .zhTW: return "snapsift 無法刪除照片。通常是因為照片存取權限設為「已選取的照片」而非「完整存取」。\n\n請到 系統設定 ▸ 隱私權與安全性 ▸ 照片，把 snapsift 改成「完整存取」，再試一次。"
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
        case .en: return "Every frame in this group is protected (favorite / edited / document) — nothing will be deleted. Tap to disarm."
        case .ja: return "このグループのすべてのフレームは保護されています（お気に入り・編集済み・書類）。何も削除されません。タップで解除。"
        case .zhTW: return "這群的每張都受保護（最愛／已編輯／文件）—— 不會刪任何東西。點一下可解除。"
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
        case .zhTW: return "受保護 — snapsift 不會刪最愛（★）、已編輯（✎）或文件（doc）照片，除非你主動選擇。"
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
        case .zhTW: return "無法完整檢查這張照片 — 原始檔不在這台 Mac 上。為了安全起見，保持未標記狀態。"
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
        case .en: return "Delete protected photos?"
        case .ja: return "保護された写真を削除しますか？"
        case .zhTW: return "確定刪除受保護的照片？"
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
        case .zhTW: return "受保護 — ⇧X 強制標刪"
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
        case .en: return "\(n) frames"
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
    func clusterHeader(count: Int, span: Double, delete: Int) -> String {
        let s = String(format: "%.1f", span)
        switch language {
        case .en: return "\(count) frames · spans \(s)s · keep 1, delete \(delete)"
        case .ja: return "\(count)枚 · 約\(s)秒 · 1枚を残し\(delete)枚を削除"
        case .zhTW: return "\(count) 張 · 跨距 \(s) 秒 · 留 1 刪 \(delete)"
        }
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
    /// Honest, privacy-forward one-liner — verbs split so each Apple technology is
    /// credited for what it actually does (scores pick; Apple Intelligence names).
    func privacyPitch() -> String {
        switch language {
        case .en: return "Native, fully offline, nothing ever sent. Picking uses Apple's photo quality scores; naming & search use Apple Intelligence — all on your Mac."
        case .ja: return "ネイティブ・完全オフライン・データ送信なし。選定は Apple の写真品質スコア、命名と検索は Apple Intelligence — すべて Mac の中で。"
        case .zhTW: return "純本機原生 App · 全程離線 · 不收發任何資料。挑選靠 Apple 照片品質分數，命名與搜尋靠 Apple Intelligence —— 全部在你的 Mac 上跑。"
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
        case .zhTW: return "這張會被刪 — 點一下改成留它"
        }
    }
    func tipFavorite() -> String {
        switch language {
        case .en: return "Favorite — never deleted"
        case .ja: return "お気に入り — 絶対に削除しません"
        case .zhTW: return "最愛 — 絕對不刪"
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
        case .en: return "Re-picks the keeper to the frame where faces look best — eyes open. Only re-orders; never changes what can be deleted."
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
        case .en: return "Skipped \(n) oversized noise clusters"
        case .ja: return "過大なノイズ群 \(n) 件をスキップ"
        case .zhTW: return "略過 \(n) 個過大的噪音群"
        }
    }
    func progFaces(_ i: Int, _ total: Int) -> String {
        switch language {
        case .en: return "Analysing faces \(i)/\(total)…"
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
    func contentCheck() -> String {
        switch language {
        case .en: return "Content check"
        case .ja: return "内容チェック"
        case .zhTW: return "內容驗證"
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
        case .zhTW: return "這群全部保留 — 不刪任何一張"
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
        case .en: return "Delete every frame in this group (favourites stay safe)"
        case .ja: return "このグループを全て削除（お気に入りは保護）"
        case .zhTW: return "這群全部刪除（★ 最愛仍受保護）"
        }
    }

    // MARK: reclaim summary + post-delete banner

    func reclaimSummary(count: Int, bytes: Int) -> String {
        guard count > 0 else { return "" }
        let size = bytes > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " · "
            : ""
        switch language {
        case .en: return "\(size)\(count) photos to delete"
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
    func nothingToDelete() -> String {
        switch language {
        case .en: return "Nothing marked for deletion"
        case .ja: return "削除対象がありません"
        case .zhTW: return "沒有標記要刪除的項目"
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
        case .zhTW: return "把候選照片整理進具名的 Snapsift 相簿 — 不破壞原檔，不刪任何東西"
        }
    }
    func progWritingAlbums() -> String {
        switch language {
        case .en:   return "Writing albums…"
        case .ja:   return "アルバムに書き込み中…"
        case .zhTW: return "寫入相簿中…"
        }
    }
    func albumsWritten(bursts: Int, blurry: Int, docs: Int, exact: Int) -> String {
        // Compact summary: "Sorted into albums · 12 bursts, 3 blurry, 1 exact dup"
        var parts: [String] = []
        if bursts > 0 { parts.append(albumsWrittenBursts(bursts)) }
        if blurry > 0 { parts.append(albumsWrittenBlurry(blurry)) }
        if docs   > 0 { parts.append(albumsWrittenDocs(docs)) }
        if exact  > 0 { parts.append(albumsWrittenExact(exact)) }
        let summary = parts.isEmpty ? albumsNothingNew() : parts.joined(separator: ", ")
        switch language {
        case .en:   return "Sorted into albums · \(summary)"
        case .ja:   return "アルバムに仕分け完了 · \(summary)"
        case .zhTW: return "整理進相簿完成 · \(summary)"
        }
    }
    private func albumsWrittenBursts(_ n: Int) -> String {
        switch language {
        case .en:   return "\(n) burst\(n == 1 ? "" : "s")"
        case .ja:   return "バースト \(n)枚"
        case .zhTW: return "\(n) 近重複"
        }
    }
    private func albumsWrittenBlurry(_ n: Int) -> String {
        switch language {
        case .en:   return "\(n) blurry"
        case .ja:   return "ブレ \(n)枚"
        case .zhTW: return "\(n) 模糊"
        }
    }
    private func albumsWrittenDocs(_ n: Int) -> String {
        switch language {
        case .en:   return "\(n) doc\(n == 1 ? "" : "s")"
        case .ja:   return "書類 \(n)枚"
        case .zhTW: return "\(n) 文件"
        }
    }
    private func albumsWrittenExact(_ n: Int) -> String {
        switch language {
        case .en:   return "\(n) exact dup\(n == 1 ? "" : "s")"
        case .ja:   return "完全重複 \(n)枚"
        case .zhTW: return "\(n) 完全相同"
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
        case .en:   return "EXACT DUP"
        case .ja:   return "完全重複"
        case .zhTW: return "完全相同"
        }
    }
    /// Tooltip for the exact-dup badge.
    func tipExactDupe() -> String {
        switch language {
        case .en:   return "Exact duplicate — same image saved twice. Safe to remove (goes to Recently Deleted)"
        case .ja:   return "完全な重複 — 同じ画像が2回保存されています。削除して問題ありません（「最近削除した項目」に移動）"
        case .zhTW: return "完全相同 — 同一張圖存了兩份，可安心清（移到「最近刪除」，30 天內可復原）"
        }
    }
    /// Tooltip for a protected frame that is in an exact-dup group — even here,
    /// protection wins.
    func tipExactDupeProtected() -> String {
        switch language {
        case .en:   return "Exact duplicate, but protected (favorite / edited / document) — never deleted"
        case .ja:   return "完全な重複ですが保護対象（お気に入り・編集済み・書類）— 削除しません"
        case .zhTW: return "完全相同，但受保護（最愛／已編輯／文件）—— 絕對不刪"
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
        case .zhTW: return "包含 \(m) 張受保護照片 — 最愛／已編輯／文件"
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
        case .zhTW: return "⚠️ \(n) 個群組將不留任何照片 — 整個群組都會移到「最近刪除」"
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
        case .zhTW: return "在「最近刪除」中 — 可在 \(until) 前復原"
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
    func historyClose() -> String {
        switch language {
        case .en:   return "Close"
        case .ja:   return "閉じる"
        case .zhTW: return "關閉"
        }
    }
    func historyKeeperLabel() -> String {
        switch language {
        case .en:   return "keeper:"
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
        case .en: return "Scan complete — \(n) sets to review"
        case .ja: return "スキャン完了 — 確認する組は \(n) 件"
        case .zhTW: return "掃描完成：找到 \(n) 組可檢視"
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

    // MARK: snapshot restore

    /// Banner when the last scan was restored from disk on launch.
    func snapshotRestored(_ n: Int) -> String {
        switch language {
        case .en: return "Restored your last scan — \(n) sets, decisions included"
        case .ja: return "前回のスキャンを復元しました — \(n) 組（判定も含む）"
        case .zhTW: return "已還原上次掃描：\(n) 組（含你的標記）"
        }
    }
    /// Same, but the library changed since the snapshot was taken.
    func snapshotRestoredStale() -> String {
        switch language {
        case .en: return "Restored your last scan — the library has changed since; consider rescanning"
        case .ja: return "前回のスキャンを復元しました — その後ライブラリが変わっています。再スキャンをおすすめします"
        case .zhTW: return "已還原上次掃描：圖庫在那之後有變動，建議重新掃描"
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
        case .en: return "Size estimates off — grant Full Disk Access"
        case .ja: return "容量の見積もりは無効 — フルディスクアクセスを許可してください"
        case .zhTW: return "沒有容量估算：請開啟「完整磁碟取用權限」"
        }
    }
    func fdaHintHelp() -> String {
        switch language {
        case .en: return "snapsift reads your library's own quality scores and file sizes from Photos.sqlite (read-only). Without Full Disk Access those are unavailable, so scans still work but no reclaimable-space estimate is shown. Click to open System Settings."
        case .ja: return "snapsift は Photos.sqlite（読み取り専用）からライブラリ自身の品質スコアとファイルサイズを読み取ります。フルディスクアクセスがないと利用できず、スキャンは動作しますが解放できる容量は表示されません。クリックでシステム設定を開きます。"
        case .zhTW: return "snapsift 會從 Photos.sqlite（唯讀）讀取圖庫自己的品質分數與檔案大小。沒有完整磁碟取用權限時掃描仍可用，但不會顯示可釋放的空間。點一下開啟「系統設定」。"
        }
    }

    // MARK: loupe HUD status words

    func loupeKeeper() -> String {
        switch language {
        case .en: return "★ keeper"
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
        case .en: return "Deleting… confirm in the system dialog if asked"
        case .ja: return "削除中… システムの確認が出たら応答してください"
        case .zhTW: return "刪除中…如出現系統確認框請回應"
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
