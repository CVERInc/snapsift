import Foundation

// Strings for the card's pointer controls, context menu and VoiceOver actions
// (checks-b). One set of verb names for all three, because they are one set of
// verbs — the same ones K, X, ⇧K and Space are.
extension L10n {
    // MARK: card verbs (buttons, context menu, VoiceOver actions)

    func cardKeepThis() -> String {
        switch language {
        case .en:   return "Keep this one"
        case .ja:   return "この1枚を残す"
        case .zhTW: return "留這張"
        }
    }
    func cardCrossOut() -> String {
        switch language {
        case .en:   return "Cross this one out"
        case .ja:   return "この1枚を外す"
        case .zhTW: return "劃掉這張"
        }
    }
    func cardUndoCrossOut() -> String {
        switch language {
        case .en:   return "Undo cross-out"
        case .ja:   return "外すのを取り消す"
        case .zhTW: return "取消劃掉"
        }
    }
    /// A known protection: this opens the same confirmation ⇧X opens.
    func cardCrossOutProtected() -> String {
        switch language {
        case .en:   return "Cross out anyway…"
        case .ja:   return "保護されていても外す…"
        case .zhTW: return "仍要劃掉…"
        }
    }
    func cardKeepOnly() -> String {
        switch language {
        case .en:   return "Keep only this one"
        case .ja:   return "この1枚だけを残す"
        case .zhTW: return "只留這張"
        }
    }
    func cardOpenPreview() -> String {
        switch language {
        case .en:   return "Open preview"
        case .ja:   return "プレビューを開く"
        case .zhTW: return "開啟預覽"
        }
    }

    // MARK: what a card says (VoiceOver label)

    func a11ySeparator() -> String {
        switch language {
        case .en:        return ", "
        case .ja, .zhTW: return "，"
        }
    }
    func a11yPosition(_ i: Int, of n: Int) -> String {
        switch language {
        case .en:   return "Photo \(i) of \(n)"
        case .ja:   return "\(n)枚中\(i)枚目"
        case .zhTW: return "第 \(i) 張，共 \(n) 張"
        }
    }
    func a11yWillKeep(_ why: String) -> String {
        switch language {
        case .en:   return "Will be kept: \(why)"
        case .ja:   return "残します：\(why)"
        case .zhTW: return "會留下：\(why)"
        }
    }
    func a11yWillDelete(_ why: String) -> String {
        switch language {
        case .en:   return "Will be moved to Recently Deleted, recoverable for 30 days: \(why)"
        case .ja:   return "「最近削除した項目」に移動します（30日間は復元できます）：\(why)"
        case .zhTW: return "會移到「最近刪除」，30 天內可復原：\(why)"
        }
    }
    /// Folder Mode: a mark puts the file on the Trash review; it moves nothing.
    func a11yFolderMarked(_ why: String) -> String {
        switch language {
        case .en:   return "Marked for Trash review: \(why)"
        case .ja:   return "ゴミ箱への移動候補：\(why)"
        case .zhTW: return "已標記供移至垃圾桶前檢視：\(why)"
        }
    }
    func a11yProtected(_ reasons: String) -> String {
        switch language {
        case .en:   return "Protected, will not be deleted: \(reasons)"
        case .ja:   return "保護対象のため削除されません：\(reasons)"
        case .zhTW: return "受保護，不會被刪：\(reasons)"
        }
    }
    /// Unclassifiable ⇒ protected ⇒ a person looks. Never "no decision".
    func a11yPleaseConfirm(_ reasons: String) -> String {
        switch language {
        case .en:   return "Could not be checked, so it is protected and will not be deleted. Please confirm it yourself: \(reasons)"
        case .ja:   return "判断できないため保護され、削除されません。ご自身で確認してください：\(reasons)"
        case .zhTW: return "無法判定，所以受保護、不會被刪，請你自己確認：\(reasons)"
        }
    }
    func a11yUndecided() -> String {
        switch language {
        case .en:   return "No decision yet"
        case .ja:   return "まだ決まっていません"
        case .zhTW: return "還沒決定"
        }
    }
    /// An exact copy the user un-crossed: drawn teal and dimmed, but it stays.
    func a11yIdenticalNotCrossedOut() -> String {
        switch language {
        case .en:   return "Identical copy, not crossed out, so it stays"
        case .ja:   return "完全に同じコピーですが、外していないので残ります"
        case .zhTW: return "完全相同的副本，沒有劃掉，所以會留下"
        }
    }
    func a11yFavorite() -> String {
        switch language {
        case .en:   return "favorite"
        case .ja:   return "お気に入り"
        case .zhTW: return "最愛"
        }
    }
    func a11yEdited() -> String {
        switch language {
        case .en:   return "edited"
        case .ja:   return "編集済み"
        case .zhTW: return "已編輯"
        }
    }
    func a11yDocument() -> String {
        switch language {
        case .en:   return "document"
        case .ja:   return "書類"
        case .zhTW: return "文件"
        }
    }
    func a11yEditUnknown() -> String {
        switch language {
        case .en:   return "its edit state could not be read"
        case .ja:   return "編集されたかどうかを読み取れません"
        case .zhTW: return "讀不到是否編輯過"
        }
    }
    func a11yDocumentUnknown() -> String {
        switch language {
        case .en:   return "it could not be checked for being a document"
        case .ja:   return "書類かどうかを確認できません"
        case .zhTW: return "無法確認是不是文件"
        }
    }

    // MARK: sidebar row glyphs, in words

    func a11yHasFavorite() -> String {
        switch language {
        case .en:   return "contains a favorite"
        case .ja:   return "お気に入りを含む"
        case .zhTW: return "含最愛"
        }
    }
    func a11yHasVideo() -> String {
        switch language {
        case .en:   return "contains a video"
        case .ja:   return "ビデオを含む"
        case .zhTW: return "含影片"
        }
    }
    func a11yNothingCrossedOut() -> String {
        switch language {
        case .en:   return "nothing crossed out"
        case .ja:   return "外した写真なし"
        case .zhTW: return "沒有劃掉任何一張"
        }
    }

    // MARK: announcements (what just changed, with counts)

    /// `folder`: Folder Mode marks put files on a Trash review — nothing goes
    /// to Recently Deleted, and the mark itself moves nothing.
    private func annCount(_ del: Int, of total: Int, folder: Bool = false) -> String {
        if folder {
            switch language {
            case .en:   return "\(del) of \(total) in this group marked for Trash review"
            case .ja:   return "このグループ\(total)項目のうち\(del)項目がゴミ箱への移動候補です"
            case .zhTW: return "這組 \(total) 個裡有 \(del) 個已標記供移至垃圾桶前檢視"
            }
        }
        switch language {
        // Glossary: the act is "move to Recently Deleted", never "remove"; and a
        // sentence that mentions deletion carries where it goes and for how long.
        case .en:   return "\(del) of \(total) in this group will be moved to Recently Deleted, recoverable for 30 days"
        case .ja:   return "このグループ\(total)枚のうち\(del)枚が「最近削除した項目」に移動されます（30日間は復元できます）"
        case .zhTW: return "這組 \(total) 張裡有 \(del) 張會移到「最近刪除」，30 天內可復原"
        }
    }
    func annCrossedOut(_ del: Int, of total: Int, folder: Bool = false) -> String {
        switch language {
        case .en:   return "Crossed out. \(annCount(del, of: total, folder: folder))"
        case .ja:   return "外しました。\(annCount(del, of: total, folder: folder))"
        case .zhTW: return "已劃掉。\(annCount(del, of: total, folder: folder))"
        }
    }
    func annCrossOutUndone(_ del: Int, of total: Int, folder: Bool = false) -> String {
        switch language {
        case .en:   return "Cross-out undone. \(annCount(del, of: total, folder: folder))"
        case .ja:   return "外すのを取り消しました。\(annCount(del, of: total, folder: folder))"
        case .zhTW: return "已取消劃掉。\(annCount(del, of: total, folder: folder))"
        }
    }
    func annKeeping(_ i: Int, _ del: Int, of total: Int, folder: Bool = false) -> String {
        switch language {
        case .en:   return "Keeping photo \(i). \(annCount(del, of: total, folder: folder))"
        case .ja:   return "\(i)枚目を残します。\(annCount(del, of: total, folder: folder))"
        case .zhTW: return "留下第 \(i) 張。\(annCount(del, of: total, folder: folder))"
        }
    }
    func annKeepOnly(_ i: Int, _ del: Int, of total: Int, folder: Bool = false) -> String {
        switch language {
        case .en:   return "Keeping only photo \(i). \(annCount(del, of: total, folder: folder))"
        case .ja:   return "\(i)枚目だけを残します。\(annCount(del, of: total, folder: folder))"
        case .zhTW: return "只留第 \(i) 張。\(annCount(del, of: total, folder: folder))"
        }
    }
    /// After a whole-set verb (A / D and their buttons).
    func annSetChanged(_ del: Int, of total: Int, folder: Bool = false) -> String {
        annCount(del, of: total, folder: folder)
    }

    // MARK: pre-commit sheet

    /// Spoken label of the one destructive button. It STARTS with the visible
    /// title, word for word, so Voice Control ("click Move to Recently
    /// Deleted") and a sighted helper name the same button; the count and the
    /// 30 days follow.
    func preCommitConfirmSpoken(_ n: Int) -> String {
        switch language {
        case .en:   return "\(preCommitConfirm()), \(n) photo\(n == 1 ? "" : "s"), recoverable for 30 days"
        case .ja:   return "\(preCommitConfirm())、\(n)枚、30日間は復元できます"
        case .zhTW: return "\(preCommitConfirm())，\(n) 張，30 天內可復原"
        }
    }

    /// Folder Mode's destructive button: the visible title first, then the
    /// count. The files go to the Trash, where Put Back works until it is emptied.
    func folderPreCommitConfirmSpoken(_ n: Int) -> String {
        switch language {
        case .en:   return "\(folderMoveToTrash()), \(n) item\(n == 1 ? "" : "s")"
        case .ja:   return "\(folderMoveToTrash())、\(n)項目"
        case .zhTW: return "\(folderMoveToTrash())，\(n) 個項目"
        }
    }
}
