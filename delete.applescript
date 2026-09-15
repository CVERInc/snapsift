-- snapsift / delete.applescript
-- ================================
-- Tell Photos.app to move a list of media items (by UUID) into "Recently
-- Deleted". Items live there for 30 days, so this is recoverable.
--
-- Usage:
--   osascript delete.applescript /full/path/to/delete-uuids.txt
--
-- Photos.app must be running. The script reads UUIDs (one per line), looks
-- each one up via `media item id "UUID"`, and submits them in batches so a
-- single bad UUID doesn't kill the whole run. Failures are logged but
-- skipped.
--
-- LIVE PROTECTION RE-CHECK (and its limit — read this before trusting it):
-- `delete-uuids.txt` is a snapshot of what was true when pick.py ran, which may
-- have been days ago. Favoriting a photo afterwards is exactly the action a
-- person takes when they decide they want to keep it, so every item's
-- `favorite` property is re-read from the LIVE library here and favorites are
-- skipped. That is the CLI equivalent of the app's commit-time sweep.
--
-- What this CANNOT re-check: `edited`. Photos' AppleScript dictionary exposes
-- no adjustment/edited property on a media item, so the protection for edited
-- photos on this path is only as fresh as the groups.json that produced this
-- list. Edit a photo after scanning and this script will still delete it (into
-- Recently Deleted, recoverable 30 days). The macOS app re-checks `edited`
-- against the live library and does not have this gap; the README's Safety
-- section says so too.

on run argv
    if (count of argv) is 0 then
        error "Usage: osascript delete.applescript <uuid-file>"
    end if

    set uuidFile to item 1 of argv
    set fileText to (read POSIX file uuidFile as «class utf8»)

    -- Split on newlines, drop blank lines
    set AppleScript's text item delimiters to linefeed
    set rawLines to text items of fileText
    set AppleScript's text item delimiters to ""

    set uuids to {}
    repeat with l in rawLines
        set s to l as text
        if length of s > 4 then set end of uuids to s
    end repeat

    set totalCount to count of uuids
    log "Loaded " & totalCount & " UUIDs from " & uuidFile

    -- Photos AppleScript can be slow on big deletions. Batch in chunks.
    set batchSize to 100
    set deleted to 0
    set missed to 0
    set skippedFavorites to 0
    set i to 1

    tell application "Photos"
        activate
        repeat while i ≤ totalCount
            set endIdx to i + batchSize - 1
            if endIdx > totalCount then set endIdx to totalCount

            set batch to {}
            repeat with j from i to endIdx
                set uuid to item j of uuids
                try
                    set mediaItem to (media item id uuid)
                    -- Live re-check: a photo favorited since pick.py ran is
                    -- protected NOW. Never deleted, counted, and reported.
                    if favorite of mediaItem then
                        set skippedFavorites to skippedFavorites + 1
                    else
                        set end of batch to mediaItem
                    end if
                on error
                    set missed to missed + 1
                end try
            end repeat

            if (count of batch) > 0 then
                try
                    delete batch
                    set deleted to deleted + (count of batch)
                on error errMsg
                    log "Batch starting " & i & " failed: " & errMsg
                end try
            end if

            log "Progress: " & deleted & " deleted, " & skippedFavorites & " favorites skipped, " & missed & " missed (cursor " & endIdx & "/" & totalCount & ")"
            set i to endIdx + 1
        end repeat
    end tell

    log "Done. Deleted: " & deleted & ". Favorites skipped: " & skippedFavorites & ". Missed: " & missed
    if skippedFavorites > 0 then
        log "NOTE: " & skippedFavorites & " item(s) were favorited after the scan and were NOT deleted."
    end if
    return "Deleted " & deleted & " / Favorites skipped " & skippedFavorites & " / Missed " & missed
end run
