#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Workshop browse filters → query tags")
struct WorkshopBrowseFilterTests {

    @Test("Content-type filter maps to the right required tags")
    func contentTypeTags() {
        #expect(WorkshopContentTypeFilter.all.requiredTags.isEmpty)
        #expect(WorkshopContentTypeFilter.scene.requiredTags == ["Scene"])
        #expect(WorkshopContentTypeFilter.video.requiredTags == ["Video"])
        #expect(WorkshopContentTypeFilter.web.requiredTags == ["Web"])
    }

    @Test("Age filter excludes the unchecked maturity ratings (complement)")
    func ageRatingTags() {
        // Multi-select inclusion is expressed as the complement: only the
        // CHECKED ratings are shown, so every unchecked rating is excluded.
        #expect(WorkshopAgeRatingFilter.excludedTags(for: [.everyone]) == ["Questionable", "Mature"])
        #expect(WorkshopAgeRatingFilter.excludedTags(for: [.mature]) == ["Everyone", "Questionable"])
        // Everything checked → nothing excluded.
        #expect(WorkshopAgeRatingFilter.excludedTags(for: [.everyone, .questionable, .mature]).isEmpty)
    }

    @Test("Application is always excluded, alongside the unchecked maturity ratings")
    func applicationAlwaysExcluded() {
        // Application wallpapers can't run in this runtime, so EVERY query
        // excludes them regardless of the maturity selection.
        #expect(WorkshopBrowseViewModel.alwaysExcludedTags == ["Application"])
        #expect(Set(WorkshopBrowseViewModel.requestExcludedTags(for: [.everyone])) == ["Application", "Mature", "Questionable"])
        // Even with every maturity rating shown, Application stays excluded.
        #expect(WorkshopBrowseViewModel.requestExcludedTags(for: [.everyone, .questionable, .mature]) == ["Application"])
    }

    @Test("Mature maturity tag drives the spoiler-blur flag (case-insensitive)")
    func matureRatingDetection() {
        func item(tags: [String]) -> WorkshopQueryItem {
            WorkshopQueryItem(
                id: 1, title: "t", shortDescription: "", creatorPersonaName: nil,
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

    @Test("De-selected genres become excludedtags (WPE-style hide), never requiredtags")
    func deselectedGenresExcluded() {
        // WPE shows every genre by default; the user de-selects ones they don't
        // want, which become `excludedtags` (an item with any of them is hidden).
        // Genres must NOT land in requiredtags (that would AND-intersect them).
        let request = WorkshopQueryRequest(
            sort: .topRated,
            requiredTags: WorkshopContentTypeFilter.scene.requiredTags,
            excludedTags: WorkshopBrowseViewModel.requestExcludedTags(for: [.everyone]) + ["Anime", "Memes"]
        )
        #expect(request.requiredTags == ["Scene"])
        // Merged with maturity complement + Application, canonical (sorted, exact-case).
        #expect(request.excludedTags == ["Anime", "Application", "Mature", "Memes", "Questionable"])
    }

    @Test("Filters flow into a canonicalized (de-duplicated, sorted, exact-case) request")
    func filtersCanonicalizeIntoRequest() {
        let request = WorkshopQueryRequest(
            sort: .topRated,
            requiredTags: WorkshopContentTypeFilter.scene.requiredTags,
            // Everyone checked → Questionable + Mature excluded.
            excludedTags: WorkshopAgeRatingFilter.excludedTags(for: [.everyone])
        )
        // Steam matches tags by their EXACT display name, so canonicalization
        // preserves case (it does NOT lowercase) and only trims, de-duplicates,
        // and sorts — hence Mature precedes Questionable.
        #expect(request.requiredTags == ["Scene"])
        #expect(request.excludedTags == ["Mature", "Questionable"])
    }

    @Test("No filters produce an unconstrained request")
    func allFiltersProduceNoTags() {
        let request = WorkshopQueryRequest(
            sort: .topRated,
            requiredTags: WorkshopContentTypeFilter.all.requiredTags,
            // All ratings checked → nothing excluded.
            excludedTags: WorkshopAgeRatingFilter.excludedTags(for: [.everyone, .questionable, .mature])
        )
        #expect(request.requiredTags.isEmpty)
        #expect(request.excludedTags.isEmpty)
    }

    @Test("Every filter case is identifiable + has a display name")
    func filterMetadata() {
        #expect(WorkshopContentTypeFilter.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(WorkshopAgeRatingFilter.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(Set(WorkshopContentTypeFilter.allCases.map(\.id)).count == WorkshopContentTypeFilter.allCases.count)
    }
}
#endif
