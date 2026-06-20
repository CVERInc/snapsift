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
            ("↑ ↓ / j k", "Move between groups"),
            ("1 – 9", "Keep the Nth frame"),
            ("→ / l / ⏎", "Enter the frames"),
            ("← → / h l", "Move between frames"),
            ("⏎", "Keep the focused frame"),
            ("Space", "Full-res preview · zoom"),
            ("A", "Keep the whole group"),
            ("D", "Delete the whole group"),
            ("Esc", "Back to the list"),
            ("⌘1 ⌘2 ⌘3", "Scan / Look-alikes / Similar sets"),
            ("⌘⌫", "Delete the marked photos"),
            ("?", "This cheat sheet"),
        ]
        case .ja: return [
            ("↑ ↓ / j k", "グループを移動"),
            ("1 – 9", "N枚目を残す"),
            ("→ / l / ⏎", "写真へ入る"),
            ("← → / h l", "写真を移動"),
            ("⏎", "選択中の1枚を残す"),
            ("スペース", "原本プレビュー・拡大"),
            ("A", "グループ全部を残す"),
            ("D", "グループ全部を削除"),
            ("Esc", "リストへ戻る"),
            ("⌘1 ⌘2 ⌘3", "スキャン / そっくり / テーマ別"),
            ("⌘⌫", "選択した写真を削除"),
            ("?", "このキー一覧"),
        ]
        case .zhTW: return [
            ("↑ ↓ / j k", "上一群／下一群"),
            ("1 – 9", "留第 N 張"),
            ("→ / l / ⏎", "進入格子"),
            ("← → / h l", "格子間移動"),
            ("⏎", "把焦點這張設成保留"),
            ("空白", "原檔預覽・可放大"),
            ("A", "整群保留"),
            ("D", "整群刪除"),
            ("Esc", "回到清單"),
            ("⌘1 ⌘2 ⌘3", "掃描／找相似／同主題"),
            ("⌘⌫", "刪掉標記的照片"),
            ("?", "這張快捷小抄"),
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
        case .en: return "Re-picks the keeper to the frame where faces look best — eyes open"
        case .ja: return "顔がいちばん良く写った1枚（目が開いている）を残すよう選び直す"
        case .zhTW: return "改挑大家臉拍得最好、眼睛有張開的那張當保留"
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
        switch language {
        case .en: return "Moved \(n) to Recently Deleted · recoverable for 30 days"
        case .ja: return "\(n)枚を「最近削除した項目」へ · 30日間は復元可能"
        case .zhTW: return "已將 \(n) 張移到「最近刪除」· 30 天內可復原"
        }
    }
    func nothingToDelete() -> String {
        switch language {
        case .en: return "Nothing marked for deletion"
        case .ja: return "削除対象がありません"
        case .zhTW: return "沒有標記要刪除的項目"
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
}
