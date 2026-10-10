import Foundation
import SnapsiftCore
import SnapsiftAppSupport

func reviewAlbumNamesTests(_ check: (Bool, String) -> Void) {
    print("Photos review album names")
    let currentTitles = Language.allCases.flatMap { language in
        let t = L10n(language)
        return [t.albumNameBursts(), t.albumNameBlurry(), t.albumNameDocs(),
                t.albumNameExact(), t.albumNameNeedsLook()].map { "Snapsift · " + $0 }
    }
    let legacyTitles = ["Snapsift · Needs a look", "Snapsift · 請你看看"]
    let snapsiftTitles = Set(currentTitles + legacyTitles)

    check(userAlbumNames(titles: [], snapsiftTitles: snapsiftTitles).isEmpty,
          "empty album membership has no user names")
    for title in currentTitles + legacyTitles {
        check(userAlbumNames(titles: [title], snapsiftTitles: snapsiftTitles).isEmpty,
              "organizational album is excluded: \(title)")
    }
    check(userAlbumNames(titles: currentTitles + legacyTitles, snapsiftTitles: snapsiftTitles).isEmpty,
          "all current localized and legacy snapsift albums are excluded together")
    check(userAlbumNames(titles: ["旅行", currentTitles[0], "Family", "旅行", "家族", "Family"],
                         snapsiftTitles: snapsiftTitles) == ["旅行", "Family", "家族"],
          "user album names are deduplicated in first-seen order")
    check(userAlbumNames(titles: ["Snapsift · My album", "snapsift · Burst Candidates"],
                         snapsiftTitles: snapsiftTitles) == ["Snapsift · My album", "snapsift · Burst Candidates"],
          "only exact known organizational titles are excluded")
    check(userAlbumNames(titles: ["B", "A", "C"], snapsiftTitles: []).joined(separator: ", ") == "B, A, C",
          "user names retain fetch order rather than sorting")
    let distinctTitles = ["Family", "旅行", "Favorites"] + currentTitles + legacyTitles
    check(userAlbumNames(titles: distinctTitles, snapsiftTitles: snapsiftTitles).count
          == userAlbumCount(titles: distinctTitles, snapsiftTitles: snapsiftTitles),
          "user album names and counts share the organizational-title exclusion")
    check(userAlbumCount(titles: ["Family", "Family", currentTitles[0]], snapsiftTitles: snapsiftTitles) == 2
          && userAlbumNames(titles: ["Family", "Family", currentTitles[0]], snapsiftTitles: snapsiftTitles) == ["Family"],
          "presentation deduplication leaves counts of same-title albums unchanged")
    check(userAlbumNames(titles: [], snapsiftTitles: snapsiftTitles).count
          == userAlbumCount(titles: [], snapsiftTitles: snapsiftTitles),
          "empty album names and counts agree")

    check(reviewAlbumNamesSummary([]) == nil, "empty album membership has no summary")
    check(reviewAlbumNamesSummary(["A"]) == "A", "one album has no truncation suffix")
    check(reviewAlbumNamesSummary(["A", "B"]) == "A, B", "two albums have no truncation suffix")
    check(reviewAlbumNamesSummary(["A", "B", "C"]) == "A, B, C", "three albums fit without truncation")
    check(reviewAlbumNamesSummary(["A", "B", "C", "D"]) == "A, B, C +1", "four albums show one extra")
    check(reviewAlbumNamesSummary(["旅行", "Family", "家族", "D", "E", "F"]) == "旅行, Family, 家族 +3",
          "summary preserves Unicode names and counts all omitted names")

    for language in Language.allCases {
        let t = L10n(language)
        check(t.reviewAlbums([]) == nil, "no no-albums claim in \(language.rawValue)")
        check(t.reviewAlbums(["旅行", "Family", "家族", "Other"])?.hasSuffix("旅行, Family, 家族 +1") == true,
              "album line preserves names and truncation in \(language.rawValue)")
        check(!(t.reviewAlbums(["A"]) ?? "").isEmpty,
              "album line exists in \(language.rawValue)")
    }
    check(L10n(.en).reviewAlbums(["A"]) == "In albums: A", "English album line uses the review wording")
    check(L10n(.ja).reviewAlbums(["A"]) == "アルバム: A", "Japanese album line is translated")
    check(L10n(.zhTW).reviewAlbums(["A"]) == "所在相簿：A", "Traditional Chinese album line uses Taiwan wording")
    check(Set(Language.allCases.compactMap { L10n($0).reviewAlbums(["A"]) }).count == 3,
          "each language has a distinct translated album prefix")
}
