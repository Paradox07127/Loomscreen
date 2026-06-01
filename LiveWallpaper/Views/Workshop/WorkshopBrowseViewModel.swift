#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation
import Observation

/// Content-type filter mapped to canonical Wallpaper Engine Workshop tags.
enum WorkshopContentTypeFilter: String, CaseIterable, Identifiable {
    case all
    case scene
    case video
    case web

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return String(localized: "All", comment: "Workshop content-type filter: no type restriction.")
        case .scene: return String(localized: "Scene", comment: "Workshop content-type filter: scene wallpapers.")
        case .video: return String(localized: "Video", comment: "Workshop content-type filter: video wallpapers.")
        case .web: return String(localized: "Web", comment: "Workshop content-type filter: web/HTML wallpapers.")
        }
    }

    var requiredTags: [String] {
        switch self {
        case .all: return []
        case .scene: return ["Scene"]
        case .video: return ["Video"]
        case .web: return ["Web"]
        }
    }

    /// Concrete selectable types (excludes `.all`, which was only the old
    /// single-select "no restriction" sentinel).
    static var selectableCases: [WorkshopContentTypeFilter] { [.scene, .video, .web] }

    /// The single Workshop tag for this type (nil for `.all`).
    var tag: String? { requiredTags.first }
}

/// One of Wallpaper Engine's three maturity ratings, each an independent
/// multi-select toggle (verbatim WPE text). Inclusion is expressed by EXCLUDING
/// the unchecked ratings (`excludedtags`), so e.g. checking only Everyone hides
/// Questionable + Mature.
enum WorkshopAgeRatingFilter: String, CaseIterable, Identifiable {
    case everyone
    case questionable
    case mature

    var id: String { rawValue }

    /// Verbatim Wallpaper Engine maturity label / tag.
    var displayName: String {
        switch self {
        case .everyone: return "Everyone"
        case .questionable: return "Questionable"
        case .mature: return "Mature"
        }
    }

    var tag: String { displayName }

    /// Default = all selected (show everything); the user narrows by deselecting.
    static let defaultSelection: Set<WorkshopAgeRatingFilter> = Set(allCases)
}

extension WorkshopQueryItem {
    /// True when the item carries Wallpaper Engine's `Mature` maturity tag.
    /// Drives the click-to-reveal blur over adult thumbnails (Questionable is
    /// intentionally not blurred — see the maturity-filter design).
    var isMatureRated: Bool {
        tags.contains { $0.caseInsensitiveCompare("Mature") == .orderedSame }
    }
}

/// Official Wallpaper Engine Workshop genre tags (exact display strings — Steam
/// matches tags by exact case). Used in the deselect-to-narrow model: all are
/// selected by default; deselected genres become `excludedtags`.
enum WorkshopGenre {
    static let allTags: [String] = [
        "Abstract", "Animal", "Anime", "Cartoon", "CGI", "Cyberpunk", "Fantasy",
        "Game", "Girls", "Guys", "Landscape", "Medieval", "Memes", "MMD", "Music",
        "Nature", "Pixel art", "Relaxing", "Retro", "Sci-Fi", "Sports",
        "Technology", "Television", "Vehicle", "Unspecified"
    ]
}

/// Resolution filter. An item targets a single resolution, so this is a
/// single-select threshold mapping to one exact Workshop resolution tag (the
/// core buckets — multi-select would AND to nothing). `.any` applies no tag.
enum WorkshopResolutionFilter: String, CaseIterable, Identifiable {
    case any
    case standardDefinition
    case fullHD1080
    case quadHD1440
    case ultraHD4K
    case ultrawide
    case portrait
    case dual

    var id: String { rawValue }

    /// Verbatim Wallpaper Engine Workshop labels — no renaming (issue: use the
    /// original WPE tag text). `.any` is the only localized label.
    var displayName: String {
        switch self {
        case .any: return String(localized: "All", comment: "Workshop resolution filter: no restriction.")
        case .standardDefinition: return "Standard Definition"
        case .fullHD1080: return "1920 x 1080"
        case .quadHD1440: return "2560 x 1440"
        case .ultraHD4K: return "3840 x 2160"
        case .ultrawide: return "3440 x 1440"
        case .portrait: return "1080 x 1920"
        case .dual: return "Dual 3840 x 1080"
        }
    }

    /// True for the localized `.any` label (rendered as a normal `Text`); the
    /// rest are verbatim resolution strings.
    var isLocalizedLabel: Bool { self == .any }

    /// Concrete selectable resolutions (excludes `.any`).
    static var selectableCases: [WorkshopResolutionFilter] { allCases.filter { $0 != .any } }

    /// Exact Steam Workshop resolution tag, or `nil` for `.any`.
    var tag: String? {
        switch self {
        case .any: return nil
        case .standardDefinition: return "Standard Definition"
        case .fullHD1080: return "1920 x 1080"
        case .quadHD1440: return "2560 x 1440"
        case .ultraHD4K: return "3840 x 2160"
        case .ultrawide: return "3440 x 1440"
        case .portrait: return "1080 x 1920"
        case .dual: return "Dual 3840 x 1080"
        }
    }
}

/// Drives `WorkshopBrowseView`. Holds the request shape, accumulates pages
/// across the cursor pagination, debounces search input, and surfaces
/// network / API errors for inline rendering. The view-model owns no
/// download workflow — it's read-only browsing.
@MainActor
@Observable
final class WorkshopBrowseViewModel {

    /// A creator the grid is currently scoped to (their SteamID64 + resolved
    /// persona name for the banner).
    struct CreatorFilter: Equatable {
        let steamID: String
        let name: String?
    }

    @ObservationIgnored private let services: WorkshopServices

    /// Tags excluded from EVERY query regardless of user filters. Application
    /// wallpapers cannot run in this runtime, so we never surface them in the
    /// browse results (server-side exclusion, not a client-side post-filter).
    nonisolated static let alwaysExcludedTags = ["Application"]

    /// Pending search text. Edits here do NOT query — the user applies the whole
    /// filter set with the Search control (or Return). See `hasPendingChanges`.
    var searchInput: String = ""
    var preferredSort: WorkshopSortMode = .topRated
    // All four filters share one model: a multi-select Set, default = every
    // option (no filter), and an empty set is treated the same as "all".
    // Narrowing works by DESELECTING — the deselected options become
    // `excludedtags`. The selections persist across launches.
    private(set) var selectedTypes: Set<WorkshopContentTypeFilter> = Set(WorkshopContentTypeFilter.selectableCases)
    private(set) var selectedAgeRatings: Set<WorkshopAgeRatingFilter> = WorkshopAgeRatingFilter.defaultSelection
    private(set) var selectedResolutions: Set<WorkshopResolutionFilter> = Set(WorkshopResolutionFilter.selectableCases)
    private(set) var selectedGenres: Set<String> = Set(WorkshopGenre.allTags)
    /// Trending window in days (week / month / year …); only used when the sort
    /// is `.trending`.
    private(set) var trendingDays: Int = 7
    /// When set, the grid shows only this creator's published files (via
    /// GetUserFiles) and the normal filter ribbon is replaced by a "Works by …"
    /// banner. Cleared to return to the normal filtered browse.
    private(set) var creatorFilter: CreatorFilter?
    /// Workshop ids already in the local library, pushed in by the pane so the
    /// grid can scope by install state. Observed → the grid re-derives
    /// `displayedItems` when the library changes underneath it.
    var installedWorkshopIDs: Set<String> = []
    /// When true, Browse hides items already in the local library (the Installed
    /// tab is where you revisit those). Persisted; surfaced as a toggle in the
    /// Workshop options menu rather than as a ribbon control.
    private(set) var hidesDownloadedInBrowse: Bool = false
    private static let hidesDownloadedKey = "loomscreen.workshop.hidesDownloaded.v1"
    private(set) var currentRequest: WorkshopQueryRequest
    private(set) var items: [WorkshopQueryItem] = []
    private(set) var totalAvailable: Int?
    private(set) var isLoading: Bool = false
    /// True while jumping to another page — current results stay on screen until
    /// the new page replaces them, so memory stays bounded.
    private(set) var isPaging: Bool = false
    private(set) var lastError: WorkshopQueryError?
    /// Set when Steam returns HTTP 429; controls stay disabled until it lapses.
    private(set) var rateLimitUntil: Date?

    private static let perPage = 50

    /// 1-based current page. Steam's QueryFiles `page` parameter lets us jump to
    /// any page directly (so we can show "Page N of M" and jump-to-page).
    private(set) var pageIndex: Int = 1

    var isRateLimited: Bool {
        (rateLimitUntil ?? .distantPast) > Date()
    }

    /// The loaded page's items after optionally hiding already-downloaded ones.
    /// The grid renders these; `items` stays the raw page so pagination/counts
    /// are intact.
    var displayedItems: [WorkshopQueryItem] {
        guard hidesDownloadedInBrowse else { return items }
        return items.filter { !installedWorkshopIDs.contains(String($0.id)) }
    }

    func setHidesDownloaded(_ hides: Bool) {
        hidesDownloadedInBrowse = hides
        UserDefaults.standard.set(hides, forKey: Self.hidesDownloadedKey)
    }

    /// Total pages from Steam's reported result count, when available.
    var totalPages: Int? {
        guard let total = totalAvailable, total > 0 else { return nil }
        return max(1, (total + Self.perPage - 1) / Self.perPage)
    }

    var canGoNextPage: Bool {
        guard !isRateLimited, !isLoading, !isPaging else { return false }
        if let totalPages { return pageIndex < totalPages }
        // Unknown total: allow next while the page came back full.
        return items.count >= Self.perPage
    }

    var canGoPrevPage: Bool {
        !isRateLimited && !isLoading && !isPaging && pageIndex > 1
    }

    @ObservationIgnored private var inflightFetch: Task<Bool, Never>?
    @ObservationIgnored private var currentRequestToken: UInt64 = 0

    /// True when the pending filter/search state differs from what's currently
    /// displayed — drives the "Search" button's enabled/prominent state. Filter
    /// edits accumulate here and only hit the network when the user applies them.
    var hasPendingChanges: Bool {
        makeRequest(page: 1) != currentRequest
    }

    init(services: WorkshopServices) {
        self.services = services
        self.currentRequest = WorkshopQueryRequest(sort: .topRated)   // placeholder
        // Restore the user's last filter selection, then seed `currentRequest`
        // to match it so `hasPendingChanges` is false on launch.
        loadPersistedFilters()
        self.currentRequest = makeRequest(page: 1)
    }

    func onAppear() {
        if items.isEmpty, lastError == nil {
            Task { await reload() }
        }
    }

    func reload() async {
        guard !isRateLimited else { return }
        inflightFetch?.cancel()
        pageIndex = 1
        let request = makeRequest(page: 1)
        currentRequest = request
        items = []
        totalAvailable = nil
        isLoading = true
        isPaging = false
        lastError = nil
        _ = await runFetch(request, replacingItems: true, paging: false)
    }

    func goToNextPage() async { await goToPage(pageIndex + 1) }
    func goToPrevPage() async { await goToPage(pageIndex - 1) }

    /// Jump directly to a 1-based page. Clamped to `totalPages` when known. The
    /// page index only commits on a successful fetch, so a failed jump leaves
    /// the pager consistent.
    func goToPage(_ target: Int) async {
        guard !isRateLimited, !isLoading, !isPaging else { return }
        let upperBound = totalPages ?? Int.max
        let clamped = min(max(target, 1), upperBound)
        guard clamped != pageIndex else { return }
        isPaging = true
        let request = makeRequest(page: clamped)
        let ok = await runFetch(request, replacingItems: true, paging: true)
        if ok {
            pageIndex = clamped
            currentRequest = request
        }
    }

    /// Search is now submit-driven (Return / the search button) rather than
    /// debounced-on-keystroke — typing no longer fires partial queries and
    /// wastes API calls. The text field binds `searchInput` directly; this just
    /// runs the query for whatever's typed.
    func submitSearch() async {
        guard !isRateLimited else { return }
        await reload()
    }

    func clearSearch() async {
        guard !isRateLimited, !searchInput.isEmpty else { return }
        searchInput = ""
        await reload()
    }

    /// Scope the grid to one creator's published files (the author-link path).
    /// Leaves the user's normal filter selection untouched so exiting restores it.
    func browseCreator(steamID: String, name: String?) async {
        guard !isRateLimited else { return }
        let trimmed = steamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        creatorFilter = CreatorFilter(steamID: trimmed, name: name)
        await reload()
    }

    /// Return to the normal filtered browse from a creator-scoped view.
    func clearCreatorFilter() async {
        guard creatorFilter != nil else { return }
        creatorFilter = nil
        await reload()
    }

    // Filter mutations below are PURE STATE EDITS — none of them query. The user
    // batches selections and applies them all at once via `submitSearch()`
    // (the Search control / Return), so adding five tags costs one request, not
    // five. `hasPendingChanges` reflects unapplied edits.

    /// Combined sort + trending-window update (period folded into the sort menu).
    func updateSortOption(_ sort: WorkshopSortMode, days: Int) {
        preferredSort = sort
        if sort == .trending { trendingDays = days }
    }

    // NOTE: each toggle mutates its property directly (no `inout` helper).
    // Passing `&selectedTypes` as inout held exclusive access to the @Observable
    // property across the whole call, and `persistFilters()` reads it again →
    // "simultaneous accesses … requires exclusive access" crash. Mutating in
    // place first, then persisting, keeps the accesses non-overlapping.
    func toggleType(_ type: WorkshopContentTypeFilter) {
        if selectedTypes.contains(type) { selectedTypes.remove(type) } else { selectedTypes.insert(type) }
        persistFilters()
    }

    func toggleAgeRating(_ rating: WorkshopAgeRatingFilter) {
        if selectedAgeRatings.contains(rating) { selectedAgeRatings.remove(rating) } else { selectedAgeRatings.insert(rating) }
        persistFilters()
    }

    func toggleResolution(_ resolution: WorkshopResolutionFilter) {
        if selectedResolutions.contains(resolution) { selectedResolutions.remove(resolution) } else { selectedResolutions.insert(resolution) }
        persistFilters()
    }

    func toggleGenre(_ tag: String) {
        if selectedGenres.contains(tag) { selectedGenres.remove(tag) } else { selectedGenres.insert(tag) }
        persistFilters()
    }

    // Option-click "isolate" — collapse a category to just one option (show only
    // this), or, if it's already the lone selection, restore the full set.
    func isolateType(_ type: WorkshopContentTypeFilter) {
        selectedTypes = isolated(type, in: selectedTypes, all: WorkshopContentTypeFilter.selectableCases)
        persistFilters()
    }

    func isolateAgeRating(_ rating: WorkshopAgeRatingFilter) {
        selectedAgeRatings = isolated(rating, in: selectedAgeRatings, all: WorkshopAgeRatingFilter.allCases)
        persistFilters()
    }

    func isolateResolution(_ resolution: WorkshopResolutionFilter) {
        selectedResolutions = isolated(resolution, in: selectedResolutions, all: WorkshopResolutionFilter.selectableCases)
        persistFilters()
    }

    func isolateGenre(_ tag: String) {
        selectedGenres = isolated(tag, in: selectedGenres, all: WorkshopGenre.allTags)
        persistFilters()
    }

    private func isolated<T: Hashable>(_ option: T, in current: Set<T>, all: [T]) -> Set<T> {
        if current.count == 1, current.contains(option) { return Set(all) }
        return [option]
    }

    /// Reset every filter (not search/sort) to all-selected (= no filter).
    func resetFilters() {
        selectedTypes = Set(WorkshopContentTypeFilter.selectableCases)
        selectedAgeRatings = WorkshopAgeRatingFilter.defaultSelection
        selectedResolutions = Set(WorkshopResolutionFilter.selectableCases)
        selectedGenres = Set(WorkshopGenre.allTags)
        persistFilters()
    }

    // MARK: - Persistence

    private enum FilterKey {
        static let types = "loomscreen.workshop.filter.types.v1"
        static let ages = "loomscreen.workshop.filter.ages.v1"
        static let resolutions = "loomscreen.workshop.filter.resolutions.v1"
        static let genres = "loomscreen.workshop.filter.genres.v1"
    }

    private func persistFilters() {
        let defaults = UserDefaults.standard
        defaults.set(selectedTypes.map(\.rawValue), forKey: FilterKey.types)
        defaults.set(selectedAgeRatings.map(\.rawValue), forKey: FilterKey.ages)
        defaults.set(selectedResolutions.map(\.rawValue), forKey: FilterKey.resolutions)
        defaults.set(Array(selectedGenres), forKey: FilterKey.genres)
    }

    private func loadPersistedFilters() {
        let defaults = UserDefaults.standard
        // Absent key → keep the default (all selected). Present (even empty) →
        // honor the saved selection (an empty set is treated as "all" at query
        // time anyway).
        if let raw = defaults.array(forKey: FilterKey.types) as? [String] {
            selectedTypes = Set(raw.compactMap(WorkshopContentTypeFilter.init(rawValue:)))
                .intersection(Set(WorkshopContentTypeFilter.selectableCases))
        }
        if let raw = defaults.array(forKey: FilterKey.ages) as? [String] {
            selectedAgeRatings = Set(raw.compactMap(WorkshopAgeRatingFilter.init(rawValue:)))
        }
        if let raw = defaults.array(forKey: FilterKey.resolutions) as? [String] {
            selectedResolutions = Set(raw.compactMap(WorkshopResolutionFilter.init(rawValue:)))
                .intersection(Set(WorkshopResolutionFilter.selectableCases))
        }
        if let raw = defaults.array(forKey: FilterKey.genres) as? [String] {
            selectedGenres = Set(raw).intersection(Set(WorkshopGenre.allTags))
        }
        if defaults.object(forKey: Self.hidesDownloadedKey) != nil {
            hidesDownloadedInBrowse = defaults.bool(forKey: Self.hidesDownloadedKey)
        }
    }

    /// Runs the query; returns `true` on a successful page load. `replacingItems`
    /// swaps the visible set (reload + pagination both replace — there is no
    /// unbounded append), `paging` selects which loading flag to clear.
    @discardableResult
    private func runFetch(_ request: WorkshopQueryRequest, replacingItems: Bool, paging: Bool) async -> Bool {
        currentRequestToken &+= 1
        let token = currentRequestToken
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            var succeeded = false
            do {
                let page = try await self.services.queryService.fetch(request)
                // Drop the result if a newer fetch has started since.
                guard token == self.currentRequestToken else { return false }
                if replacingItems {
                    self.items = Self.displayable(page.items)
                }
                self.totalAvailable = page.totalAvailable
                self.lastError = nil
                self.rateLimitUntil = nil
                succeeded = true
            } catch let error as WorkshopQueryError {
                guard token == self.currentRequestToken else { return false }
                self.lastError = error
                if case .rateLimited(let retryAfter) = error {
                    self.rateLimitUntil = Date().addingTimeInterval(retryAfter ?? 60)
                }
            } catch is CancellationError {
                // ignore — user-triggered reload
            } catch {
                guard token == self.currentRequestToken else { return false }
                self.lastError = .responseParseFailure
            }
            guard token == self.currentRequestToken else { return false }
            if paging {
                self.isPaging = false
            } else {
                self.isLoading = false
            }
            return succeeded
        }
        inflightFetch = task
        return await task.value
    }

    /// Drops items we never surface in the browse grid. Normal browse already
    /// excludes `Application` server-side (so this is a no-op there); the
    /// creator-scoped GetUserFiles path can't, so this enforces it client-side.
    private static func displayable(_ items: [WorkshopQueryItem]) -> [WorkshopQueryItem] {
        items.filter { item in
            !item.tags.contains { tag in
                alwaysExcludedTags.contains { tag.caseInsensitiveCompare($0) == .orderedSame }
            }
        }
    }

    private func makeRequest(page: Int) -> WorkshopQueryRequest {
        // Creator-scoped browse ignores sort / search / tag filters — it lists
        // that one creator's published files via GetUserFiles.
        if let creatorFilter {
            return WorkshopQueryRequest(
                sort: .newest,
                page: page,
                numPerPage: Self.perPage,
                creatorSteamID: creatorFilter.steamID
            )
        }

        let trimmed = searchInput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Pure-exclusion model: the user starts with everything selected and
        // narrows by deselecting; the DESELECTED options become `excludedtags`.
        // A category that's fully selected OR empty contributes nothing
        // ("empty == all"). No `requiredtags` are sent.
        var excluded: [String] = []
        excluded += deselectedTags(in: selectedTypes, all: WorkshopContentTypeFilter.selectableCases) { $0.tag }
        excluded += deselectedTags(in: selectedAgeRatings, all: WorkshopAgeRatingFilter.allCases) { $0.tag }
        excluded += deselectedTags(in: selectedResolutions, all: WorkshopResolutionFilter.selectableCases) { $0.tag }
        excluded += deselectedGenreTags()
        // Application wallpapers can't run here — always hide them.
        excluded += Self.alwaysExcludedTags

        return WorkshopQueryRequest(
            sort: preferredSort,
            searchText: trimmed,
            page: page,
            numPerPage: Self.perPage,
            days: preferredSort == .trending ? trendingDays : nil,
            requiredTags: [],
            excludedTags: excluded
        )
    }

    /// Tags for the deselected options of a category — empty when the category
    /// is fully selected or fully empty (both mean "no filter").
    private func deselectedTags<T: Hashable>(
        in selected: Set<T>,
        all: [T],
        tag: (T) -> String?
    ) -> [String] {
        guard !selected.isEmpty, selected.count < all.count else { return [] }
        return all.filter { !selected.contains($0) }.compactMap(tag)
    }

    private func deselectedGenreTags() -> [String] {
        guard !selectedGenres.isEmpty, selectedGenres.count < WorkshopGenre.allTags.count else { return [] }
        return WorkshopGenre.allTags.filter { !selectedGenres.contains($0) }
    }
}
#endif
