#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Workshop browse filters → query tags")
struct WorkshopBrowseFilterTests {

    @Test("Workshop sort modes map to Steam QueryFiles query_type codes")
    func sortQueryTypeCodes() {
        #expect(WorkshopSortMode.mostPopular.queryTypeCode == 3)
        #expect(WorkshopSortMode.topRated.queryTypeCode == 0)
        #expect(WorkshopSortMode.newest.queryTypeCode == 1)
        #expect(WorkshopSortMode.lastUpdated.queryTypeCode == 21)
        #expect(WorkshopSortMode.mostSubscribed.queryTypeCode == 9)
        #expect(WorkshopSortMode.search.queryTypeCode == 12)
    }

    @Test("Workshop time frames map to Steam QueryFiles days values")
    func timeFrameDays() {
        #expect(WorkshopTimeFrame.today.days == 1)
        #expect(WorkshopTimeFrame.oneWeek.days == 7)
        #expect(WorkshopTimeFrame.thirtyDays.days == 30)
        #expect(WorkshopTimeFrame.threeMonths.days == 90)
        #expect(WorkshopTimeFrame.sixMonths.days == 180)
        #expect(WorkshopTimeFrame.oneYear.days == 365)
        #expect(WorkshopTimeFrame.allTime.days == nil)
    }

    @Test("Most popular request preserves time frame days")
    func mostPopularRequestPreservesTimeFrameDays() {
        let request = WorkshopQueryRequest(sort: .mostPopular, timeFrame: .sixMonths)

        #expect(request.sort == .mostPopular)
        #expect(request.timeFrame == .sixMonths)
        #expect(request.days == 180)
    }

    @Test("Top rated all time ignores incompatible time frame")
    func topRatedAllTimeIgnoresIncompatibleTimeFrame() {
        let request = WorkshopQueryRequest(sort: .topRated, timeFrame: .sixMonths)

        #expect(request.sort == .topRated)
        #expect(request.timeFrame == .allTime)
        #expect(request.days == nil)
    }

    @Test("Query request emits sort and time frame as API query items")
    func queryRequestAPIQueryItemsIncludeSortAndTimeFrame() {
        let request = WorkshopQueryRequest(
            sort: .mostPopular,
            page: 2,
            numPerPage: 25,
            timeFrame: .threeMonths,
            requiredTags: ["Scene"],
            excludedTags: ["Application"]
        )

        let values = Dictionary(
            uniqueKeysWithValues: request.apiQueryItems(apiKey: "FAKEKEY", appID: 431960).map { ($0.name, $0.value ?? "") }
        )

        #expect(values["appid"] == "431960")
        #expect(values["query_type"] == "3")
        #expect(values["days"] == "90")
        #expect(values["page"] == "2")
        #expect(values["numperpage"] == "25")
        #expect(values["requiredtags[0]"] == "Scene")
        #expect(values["excludedtags[0]"] == "Application")
    }

    @Test("All-time time frame omits days from API query items")
    func allTimeOmitsDaysAPIQueryItem() {
        let request = WorkshopQueryRequest(sort: .topRated, timeFrame: .allTime)

        let names = Set(request.apiQueryItems(apiKey: "FAKEKEY", appID: 431960).map(\.name))

        #expect(!names.contains("days"))
    }

    @Test("Last updated omits incompatible days API query item")
    func lastUpdatedOmitsIncompatibleDaysAPIQueryItem() {
        let request = WorkshopQueryRequest(sort: .lastUpdated, timeFrame: .threeMonths)

        let values = Dictionary(
            uniqueKeysWithValues: request.apiQueryItems(apiKey: "FAKEKEY", appID: 431960).map { ($0.name, $0.value ?? "") }
        )

        #expect(values["query_type"] == "21")
        #expect(values["days"] == nil)
    }

    @Test("Content-type filter maps to the right tag")
    func contentTypeTags() {
        #expect(WorkshopContentTypeFilter.scene.requiredTags == ["Scene"])
        #expect(WorkshopContentTypeFilter.video.requiredTags == ["Video"])
        #expect(WorkshopContentTypeFilter.web.requiredTags == ["Web"])
        #expect(WorkshopContentTypeFilter.scene.tag == "Scene")
    }

    @Test("Selectable cases exclude the no-restriction sentinels")
    func selectableCases() {
        // The deselect-to-narrow model never offers a `.any` sentinel as a
        // concrete chip; content type has no sentinel, so all cases are selectable.
        #expect(WorkshopContentTypeFilter.selectableCases == [.scene, .video, .web])
        #expect(!WorkshopResolutionFilter.selectableCases.contains(.any))
    }

    @Test("Maturity defaults to all-selected (show everything; narrow by deselecting)")
    func ageRatingDefault() {
        #expect(WorkshopAgeRatingFilter.defaultSelection == Set(WorkshopAgeRatingFilter.allCases))
        #expect(WorkshopAgeRatingFilter.mature.tag == "Mature")
    }

    @Test("Application is always excluded from every query")
    func applicationAlwaysExcluded() {
        // Application wallpapers can't run in this runtime.
        #expect(WorkshopBrowseViewModel.alwaysExcludedTags == ["Application"])
    }

    @Test("Mature maturity tag drives the spoiler-blur flag (case-insensitive)")
    func matureRatingDetection() {
        func item(tags: [String]) -> WorkshopQueryItem {
            WorkshopQueryItem(
                id: 1, title: "t", shortDescription: "", creatorID: nil, creatorPersonaName: nil,
                previewImageURL: nil, fileSizeBytes: nil, timeUpdated: nil,
                subscriptionCount: nil, voteScore: nil, tags: tags,
                visibility: .public, isBanned: false,
                steamCommunityURL: URL(string: "https://steamcommunity.com/")!
            )
        }
        #expect(item(tags: ["Scene", "Mature"]).isMatureRated)
        #expect(item(tags: ["mature"]).isMatureRated)
        #expect(!item(tags: ["Scene", "Questionable"]).isMatureRated)
        #expect(!item(tags: ["Everyone"]).isMatureRated)
    }

    @Test("excludedtags are canonicalized: trimmed, de-duplicated, sorted, exact-case")
    func excludedTagsCanonicalize() {
        // Steam matches tags by their EXACT display name, so canonicalization
        // preserves case (it does NOT lowercase) and only trims, de-duplicates,
        // and sorts. This is the shape the deselected-options + Application list
        // flows through.
        let request = WorkshopQueryRequest(
            sort: .topRated,
            excludedTags: ["Mature", "Anime", "Application", "Mature", " Memes "]
        )
        #expect(request.requiredTags.isEmpty)
        #expect(request.excludedTags == ["Anime", "Application", "Mature", "Memes"])
    }

    @Test("Every filter case is identifiable + has a display name")
    func filterMetadata() {
        #expect(WorkshopContentTypeFilter.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(WorkshopAgeRatingFilter.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(Set(WorkshopContentTypeFilter.allCases.map(\.id)).count == WorkshopContentTypeFilter.allCases.count)
    }
}
#endif
