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
                    set end of batch to (media item id uuid)
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

            log "Progress: " & deleted & " deleted, " & missed & " missed (cursor " & endIdx & "/" & totalCount & ")"
            set i to endIdx + 1
        end repeat
    end tell

    log "Done. Deleted: " & deleted & ". Missed: " & missed
    return "Deleted " & deleted & " / Missed " & missed
end run
