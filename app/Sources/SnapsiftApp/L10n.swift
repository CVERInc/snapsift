import Foundation

/// All user-facing strings, resolved for one ``Language``. Every message is an
/// exhaustive `switch`, so the compiler refuses to build until a newly added
/// language is fully translated.
struct L10n: Sendable {
    let language: Language
    init(_ language: Language) { self.language = language }

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
            ("Space", "Big preview"),
            ("A", "Keep the whole group"),
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
            ("スペース", "大きくプレビュー"),
            ("A", "グループ全部を残す"),
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
            ("空白", "大圖預覽"),
            ("A", "整群保留"),
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
}
