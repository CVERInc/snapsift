import Foundation

/// All user-facing strings, resolved for one ``Language``. Every message is an
/// exhaustive `switch`, so the compiler refuses to build until a newly added
/// language is fully translated.
struct L10n: Sendable {
    let language: Language
    init(_ language: Language) { self.language = language }

    // MARK: chrome

    func videos() -> String {
        switch language {
        case .en: return "Videos"
        case .ja: return "動画"
        case .zhTW: return "影片"
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
        case .en: return "Group your whole library by what's in each photo (neural, on-device) — across time, nothing deleted"
        case .ja: return "写真の内容でライブラリ全体を分類（オンデバイス・時間をまたぐ・削除しない）"
        case .zhTW: return "用照片內容把整個圖庫分類（裝置端神經、跨時間、不刪任何東西）"
        }
    }
    func progClassifying(_ i: Int, _ total: Int) -> String {
        switch language {
        case .en: return "Classifying \(i)/\(total)…"
        case .ja: return "分類中 \(i)/\(total)…"
        case .zhTW: return "分類中 \(i)/\(total)…"
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
    func searchPrompt(_ smart: Bool) -> String {
        switch language {
        case .en: return smart ? "Search · ↩ for smart match" : "Filter categories"
        case .ja: return smart ? "検索 · ↩ でスマート検索" : "カテゴリを絞り込む"
        case .zhTW: return smart ? "搜尋 · ↩ 智慧比對" : "篩選類別"
        }
    }

    // MARK: permission gate

    func gateRequestBody() -> String {
        switch language {
        case .en: return "snapsift reads your Photos library on-device to find near-duplicate bursts. Nothing leaves your Mac."
        case .ja: return "snapsift はこの Mac 上だけで写真ライブラリを読み取り、よく似た連写を見つけます。データは外部に送信されません。"
        case .zhTW: return "snapsift 只在這台 Mac 上讀取你的照片圖庫，找出近乎重複的連拍。任何資料都不會離開你的裝置。"
        }
    }
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
        case .en: return "Apple-ranked"
        case .ja: return "Apple 品質順"
        case .zhTW: return "Apple 品質排序"
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
        case .en: return "Scan to find near-duplicate bursts"
        case .ja: return "スキャンしてよく似た連写を探します"
        case .zhTW: return "掃描以找出近乎重複的連拍"
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
        case .en: return "Keeper"
        case .ja: return "残す1枚"
        case .zhTW: return "保留這張"
        }
    }
    func tipDelete() -> String {
        switch language {
        case .en: return "Will be deleted · click to keep this one"
        case .ja: return "削除されます · クリックでこれを残す"
        case .zhTW: return "將被刪除 · 點擊改留這張"
        }
    }
    func tipFavorite() -> String {
        switch language {
        case .en: return "Favorite — always kept"
        case .ja: return "お気に入り — 常に残します"
        case .zhTW: return "最愛 — 一律保留"
        }
    }
    func tipScan() -> String {
        switch language {
        case .en: return "Find near-duplicate burst sequences"
        case .ja: return "よく似た連写を探す"
        case .zhTW: return "找出近乎重複的連拍序列"
        }
    }
    func tipLookAlikes() -> String {
        switch language {
        case .en: return "Find the same photo saved across different days (neural, on-device)"
        case .ja: return "別の日に保存された同じ写真を探す（オンデバイスのニューラル解析）"
        case .zhTW: return "找出不同天存下的同一張照片（裝置端神經分析）"
        }
    }
    func tipFaces() -> String {
        switch language {
        case .en: return "Re-pick keepers using on-device face + open-eyes analysis"
        case .ja: return "顔と開いた目の解析で残す1枚を選び直す（オンデバイス）"
        case .zhTW: return "用裝置端人臉與睜眼分析重新挑選保留張"
        }
    }
    func tipAppleRanked() -> String {
        switch language {
        case .en: return "Keeper chosen using Apple's on-device quality scores"
        case .ja: return "Apple のオンデバイス品質スコアで残す1枚を選択"
        case .zhTW: return "用 Apple 裝置端品質分數挑選保留張"
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
        case .en: return "Duplicates · \(n)"
        case .ja: return "重複 · \(n)"
        case .zhTW: return "確定重複 · \(n)"
        }
    }
    func sectionPending(_ n: Int) -> String {
        switch language {
        case .en: return "Similar — you decide · \(n)"
        case .ja: return "似ている — あなたが選ぶ · \(n)"
        case .zhTW: return "相似 · 你決定 · \(n)"
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
