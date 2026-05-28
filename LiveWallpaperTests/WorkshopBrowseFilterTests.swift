#if !LITE_BUILD && DIRECT_DISTRIBUTION
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

    @Test("Age filter excludes Mature only for Everyone")
    func ageRatingTags() {
        #expect(WorkshopAgeRatingFilter.everyone.excludedTags == ["Mature"])
        #expect(WorkshopAgeRatingFilter.mature.excludedTags.isEmpty)
    }

    @Test("Filters flow into a canonicalized (lowercased) query request")
    func filtersCanonicalizeIntoRequest() {
        let request = WorkshopQueryRequest(
            sort: .topRated,
            requiredTags: WorkshopContentTypeFilter.scene.requiredTags,
            excludedTags: WorkshopAgeRatingFilter.everyone.excludedTags
        )
        #expect(request.requiredTags == ["scene"])
        #expect(request.excludedTags == ["mature"])
    }

    @Test("No filters produce an unconstrained request")
    func allFiltersProduceNoTags() {
        let request = WorkshopQueryRequest(
            sort: .topRated,
            requiredTags: WorkshopContentTypeFilter.all.requiredTags,
            excludedTags: WorkshopAgeRatingFilter.mature.excludedTags
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
