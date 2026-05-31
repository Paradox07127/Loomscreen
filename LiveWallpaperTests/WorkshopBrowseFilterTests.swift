#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Workshop browse filters → query tags")
struct WorkshopBrowseFilterTests {

    @Test("Content-type filter maps to the right tag")
    func contentTypeTags() {
        #expect(WorkshopContentTypeFilter.all.requiredTags.isEmpty)
        #expect(WorkshopContentTypeFilter.scene.requiredTags == ["Scene"])
        #expect(WorkshopContentTypeFilter.video.requiredTags == ["Video"])
        #expect(WorkshopContentTypeFilter.web.requiredTags == ["Web"])
        #expect(WorkshopContentTypeFilter.scene.tag == "Scene")
        #expect(WorkshopContentTypeFilter.all.tag == nil)
    }

    @Test("Selectable cases exclude the no-restriction sentinels")
    func selectableCases() {
        // The deselect-to-narrow model never offers the old `.all` / `.any`
        // sentinels as concrete chips.
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
