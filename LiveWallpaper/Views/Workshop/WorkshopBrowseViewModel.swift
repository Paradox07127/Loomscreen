#if !LITE_BUILD
import Foundation
import Observation

enum WorkshopContentTypeFilter: String, CaseIterable, Identifiable {
    case scene
    case video
    case web

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .scene: return String(localized: "Scene", comment: "Workshop content-type filter: scene wallpapers.")
        case .video: return String(localized: "Video", comment: "Workshop content-type filter: video wallpapers.")
        case .web: return String(localized: "Web", comment: "Workshop content-type filter: web wallpapers.")
        }
    }

    var requiredTags: [String] {
        switch self {
        case .scene: return ["Scene"]
        case .video: return ["Video"]
        case .web: return ["Web"]
        }
    }

    static var selectableCases: [WorkshopContentTypeFilter] { allCases }

    var tag: String? { requiredTags.first }
}

/// WPE's three maturity ratings, independent multi-select toggles. Inclusion is
/// expressed by EXCLUDING the unchecked ratings (`excludedtags`), so checking
/// only Everyone hides Questionable + Mature.
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

/// Official WPE Workshop genre tags — exact display strings, since Steam matches
/// tags by exact case. Deselect-to-narrow: deselected genres become `excludedtags`.
enum WorkshopGenre {
    static let allTags: [String] = [
        "Abstract", "Animal", "Anime", "Cartoon", "CGI", "Cyberpunk", "Fantasy",
        "Game", "Girls", "Guys", "Landscape", "Medieval", "Memes", "MMD", "Music",
        "Nature", "Pixel art", "Relaxing", "Retro", "Sci-Fi", "Sports",
        "Technology", "Television", "Vehicle", "Unspecified"
    ]
}

/// Single-select (an item targets one resolution, so multi-select would AND to
/// nothing) mapping to one exact Workshop resolution tag. `.any` applies no tag.
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

    /// Verbatim Wallpaper Engine Workshop labels — no renaming. `.any` is the only localized label.
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

/// Drives `WorkshopBrowsePane`: request shape, paginated browse, debounced
/// search, inline error surfacing. Read-only — owns no download workflow.
@MainActor
@Observable
final class WorkshopBrowseViewModel {

    struct CreatorFilter: Equatable {
        let steamID: String
        let name: String?
    }

    @ObservationIgnored private let services: WorkshopServices

    /// Excluded from EVERY query: Application wallpapers can't run in this
    /// runtime, so never surface them (server-side exclusion, not post-filter).
    nonisolated static let alwaysExcludedTags = ["Application"]

    /// Typing schedules a debounced auto-search (fires after `searchDebounce` of
    /// quiet); Return / Search submit immediately. The debounce only queries when
    /// the input actually changes the applied request, so submits/clear/deep-links
    /// never double-fire.
    var searchInput: String = "" {
        didSet {
            guard searchInput != oldValue else { return }
            scheduleAutoApply()
        }
    }
    var preferredSort: WorkshopSortMode = .topRated
    // All four filters share one model: a multi-select Set defaulting to every
    // option, with empty == "all". Narrowing DESELECTS → deselected options
    // become `excludedtags`. Persisted across launches.
    private(set) var selectedTypes: Set<WorkshopContentTypeFilter> = Set(WorkshopContentTypeFilter.selectableCases)
    private(set) var selectedAgeRatings: Set<WorkshopAgeRatingFilter> = WorkshopAgeRatingFilter.defaultSelection
    private(set) var selectedResolutions: Set<WorkshopResolutionFilter> = Set(WorkshopResolutionFilter.selectableCases)
    private(set) var selectedGenres: Set<String> = Set(WorkshopGenre.allTags)
    private(set) var preferredTimeFrame: WorkshopTimeFrame = .allTime
    /// When set, the grid shows only this creator's published files (via
    /// GetUserFiles). Mutually exclusive with `pinnedTag`.
    private(set) var creatorFilter: CreatorFilter?
    /// When set, the grid is scoped to items carrying this exact Workshop tag
    /// (detail-inspector tag-click path). Mutually exclusive with `creatorFilter`.
    private(set) var pinnedTag: String?
    /// Pushed in by the pane; observed so the grid re-derives `displayedItems`
    /// when the library changes underneath it.
    var installedWorkshopIDs: Set<String> = []
    /// The preference lives in Settings → Steam Workshop (`@AppStorage`); the
    /// pane pushes the current value in here.
    var hidesDownloadedInBrowse: Bool = false
    private(set) var currentRequest: WorkshopQueryRequest
    private(set) var items: [WorkshopQueryItem] = []
    private(set) var totalAvailable: Int?
    private(set) var isLoading: Bool = false
    /// True while paging — current results stay on screen until the new page
    /// replaces them, so memory stays bounded.
    private(set) var isPaging: Bool = false
    private(set) var lastError: WorkshopQueryError?
    /// Set when Steam returns HTTP 429; controls stay disabled until it lapses.
    private(set) var rateLimitUntil: Date?

    private static let perPage = 50

    /// 1-based. Steam's QueryFiles `page` param lets us jump to any page directly.
    private(set) var pageIndex: Int = 1

    var isRateLimited: Bool {
        (rateLimitUntil ?? .distantPast) > Date()
    }

    /// Grid renders these; `items` stays the raw page so pagination/counts stay intact.
    var displayedItems: [WorkshopQueryItem] {
        guard hidesDownloadedInBrowse else { return items }
        return items.filter { !installedWorkshopIDs.contains(String($0.id)) }
    }

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
    @ObservationIgnored private var autoSearchTask: Task<Void, Never>?

    /// Quiet window after the last keystroke before auto-search fires: long
    /// enough that mid-word states don't burn API quota, short enough to feel live.
    private static let searchDebounce: Duration = .milliseconds(500)

    /// True when pending filter/search state differs from what's displayed —
    /// drives the Search button's enabled/prominent state.
    var hasPendingChanges: Bool {
        makeRequest(page: 1) != currentRequest
    }

    init(services: WorkshopServices) {
        self.services = services
        self.currentRequest = WorkshopQueryRequest(sort: .topRated, timeFrame: .allTime)
        // Seed `currentRequest` to match the restored filters so
        // `hasPendingChanges` is false on launch.
        loadPersistedFilters()
        self.currentRequest = makeRequest(page: 1)
    }

    func onAppear() {
        if items.isEmpty, lastError == nil {
            Task { await reload() }
        }
    }

    /// Restarts the auto-apply countdown; fires `reload()` after `searchDebounce`
    /// of quiet, but only if it would actually change the applied request (typing
    /// inside a creator/tag scope, or retyping the submitted query, no-ops). Rapid
    /// toggling keeps restarting the window, so a burst of edits costs one request.
    private func scheduleAutoApply() {
        autoSearchTask?.cancel()
        autoSearchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled, let self else { return }
            guard self.hasPendingChanges, !self.isRateLimited else { return }
            await self.reload()
        }
    }

    func reload() async {
        guard !isRateLimited else { return }
        // An explicit reload supersedes any pending auto-search.
        autoSearchTask?.cancel()
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

    /// Clamped to `totalPages` when known. Page index commits only on a
    /// successful fetch, so a failed jump leaves the pager consistent.
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

    /// Immediate submit (Return / search button) — skips the typing debounce.
    func submitSearch() async {
        guard !isRateLimited else { return }
        await reload()
    }

    func clearSearch() async {
        guard !isRateLimited, !searchInput.isEmpty else { return }
        searchInput = ""
        await reload()
    }

    /// Scope to one creator's published files. Leaves the normal filter
    /// selection untouched so exiting restores it.
    func browseCreator(steamID: String, name: String?) async {
        guard !isRateLimited else { return }
        let trimmed = steamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pinnedTag = nil
        creatorFilter = CreatorFilter(steamID: trimmed, name: name)
        await reload()
    }

    func clearCreatorFilter() async {
        guard creatorFilter != nil else { return }
        creatorFilter = nil
        await reload()
    }

    /// Scope to items carrying one Workshop tag. Leaves the normal filter selection untouched.
    func browseTag(_ tag: String) async {
        guard !isRateLimited else { return }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        creatorFilter = nil
        pinnedTag = trimmed
        await reload()
    }

    func clearPinnedTag() async {
        guard pinnedTag != nil else { return }
        pinnedTag = nil
        await reload()
    }

    // Filter mutations below edit state and schedule the shared debounced
    // auto-apply — none query directly, so a burst of chip toggles costs one request.

    func updateSort(_ sort: WorkshopSortMode) {
        preferredSort = sort
        scheduleAutoApply()
    }

    func updateTimeFrame(_ timeFrame: WorkshopTimeFrame) {
        preferredTimeFrame = timeFrame
        scheduleAutoApply()
    }

    // NOTE: each toggle mutates its property directly (no `inout` helper).
    // Passing `&selectedTypes` as inout held exclusive access to the @Observable
    // property across the whole call, and `persistFilters()` reads it again →
    // "simultaneous accesses … requires exclusive access" crash. Mutating in
    // place first, then persisting, keeps the accesses non-overlapping.
    func toggleType(_ type: WorkshopContentTypeFilter) {
        if selectedTypes.contains(type) { selectedTypes.remove(type) } else { selectedTypes.insert(type) }
        persistFilters()
        scheduleAutoApply()
    }

    func toggleAgeRating(_ rating: WorkshopAgeRatingFilter) {
        if selectedAgeRatings.contains(rating) { selectedAgeRatings.remove(rating) } else { selectedAgeRatings.insert(rating) }
        persistFilters()
        scheduleAutoApply()
    }

    func toggleResolution(_ resolution: WorkshopResolutionFilter) {
        if selectedResolutions.contains(resolution) { selectedResolutions.remove(resolution) } else { selectedResolutions.insert(resolution) }
        persistFilters()
        scheduleAutoApply()
    }

    func toggleGenre(_ tag: String) {
        if selectedGenres.contains(tag) { selectedGenres.remove(tag) } else { selectedGenres.insert(tag) }
        persistFilters()
        scheduleAutoApply()
    }

    // Option-click "isolate" — collapse a category to just one option, or, if
    // it's already the lone selection, restore the full set.
    func isolateType(_ type: WorkshopContentTypeFilter) {
        selectedTypes = isolated(type, in: selectedTypes, all: WorkshopContentTypeFilter.selectableCases)
        persistFilters()
        scheduleAutoApply()
    }

    func isolateAgeRating(_ rating: WorkshopAgeRatingFilter) {
        selectedAgeRatings = isolated(rating, in: selectedAgeRatings, all: WorkshopAgeRatingFilter.allCases)
        persistFilters()
        scheduleAutoApply()
    }

    func isolateResolution(_ resolution: WorkshopResolutionFilter) {
        selectedResolutions = isolated(resolution, in: selectedResolutions, all: WorkshopResolutionFilter.selectableCases)
        persistFilters()
        scheduleAutoApply()
    }

    func isolateGenre(_ tag: String) {
        selectedGenres = isolated(tag, in: selectedGenres, all: WorkshopGenre.allTags)
        persistFilters()
        scheduleAutoApply()
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
        scheduleAutoApply()
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
        // honor the saved selection (empty set == "all" at query time anyway).
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
    }

    /// Returns `true` on a successful page load. `replacingItems` swaps the
    /// visible set (reload + pagination both replace — no unbounded append);
    /// `paging` selects which loading flag to clear.
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

    /// Normal browse already excludes `Application` server-side (no-op here); the
    /// creator-scoped GetUserFiles path can't, so this enforces it client-side.
    private static func displayable(_ items: [WorkshopQueryItem]) -> [WorkshopQueryItem] {
        items.filter { item in
            !item.tags.contains { tag in
                alwaysExcludedTags.contains { tag.caseInsensitiveCompare($0) == .orderedSame }
            }
        }
    }

    private func makeRequest(page: Int) -> WorkshopQueryRequest {
        // Creator-scoped browse ignores sort / search / tag filters — lists one
        // creator's published files via GetUserFiles.
        if let creatorFilter {
            return WorkshopQueryRequest(
                sort: .newest,
                page: page,
                numPerPage: Self.perPage,
                creatorSteamID: creatorFilter.steamID
            )
        }

        // Tag-scoped browse: items REQUIRED to carry the clicked tag (sort still
        // applies); deselect filters / search ignored while scoped.
        if let pinnedTag {
            return WorkshopQueryRequest(
                sort: preferredSort,
                searchText: "",
                page: page,
                numPerPage: Self.perPage,
                timeFrame: preferredTimeFrame,
                requiredTags: [pinnedTag],
                excludedTags: Self.alwaysExcludedTags
            )
        }

        let trimmed = searchInput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Pure-exclusion model: DESELECTED options become `excludedtags`. A
        // category fully selected OR empty contributes nothing ("empty == all").
        // No `requiredtags` are sent.
        var excluded: [String] = []
        excluded += deselectedTags(in: selectedTypes, all: WorkshopContentTypeFilter.selectableCases) { $0.tag }
        excluded += deselectedTags(in: selectedAgeRatings, all: WorkshopAgeRatingFilter.allCases) { $0.tag }
        excluded += deselectedTags(in: selectedResolutions, all: WorkshopResolutionFilter.selectableCases) { $0.tag }
        excluded += deselectedGenreTags()
        excluded += Self.alwaysExcludedTags

        return WorkshopQueryRequest(
            sort: preferredSort,
            searchText: trimmed,
            page: page,
            numPerPage: Self.perPage,
            timeFrame: preferredTimeFrame,
            requiredTags: [],
            excludedTags: excluded
        )
    }

    /// Empty when the category is fully selected or fully empty (both = "no filter").
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
