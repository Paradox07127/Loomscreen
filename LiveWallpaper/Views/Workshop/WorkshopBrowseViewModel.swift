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
}

/// Maturity threshold — Wallpaper Engine tags items with one of three age
/// ratings. This is a ceiling, expressed via `excludedTags` so it works whether
/// or not "Everyone" is a literal tag: each tier hides the ratings above it.
enum WorkshopAgeRatingFilter: String, CaseIterable, Identifiable {
    case everyone
    case questionable
    case mature

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .everyone: return String(localized: "Everyone", comment: "Workshop maturity filter: hide questionable + mature content.")
        case .questionable: return String(localized: "Questionable", comment: "Workshop maturity filter: allow questionable, hide mature.")
        case .mature: return String(localized: "Mature", comment: "Workshop maturity filter: include all content.")
        }
    }

    /// Hide every rating stricter than the chosen ceiling.
    var excludedTags: [String] {
        switch self {
        case .everyone: return ["Questionable", "Mature"]
        case .questionable: return ["Mature"]
        case .mature: return []
        }
    }
}

/// Official Wallpaper Engine Workshop genre tags (exact display strings — Steam
/// matches `requiredtags` by exact case). Selecting more than one ANDs them,
/// mirroring Steam's own Workshop browse (an item must carry every chosen tag).
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

    @ObservationIgnored private let services: WorkshopServices

    /// Current search input as the user types it. The view-model debounces
    /// `searchText` changes into `currentRequest` updates.
    var searchInput: String = ""
    var preferredSort: WorkshopSortMode = .topRated
    var typeFilter: WorkshopContentTypeFilter = .all
    var ageRating: WorkshopAgeRatingFilter = .everyone
    /// Multi-select genre tags (AND semantics, Steam-native).
    private(set) var selectedGenres: Set<String> = []
    var resolution: WorkshopResolutionFilter = .any
    /// Trending window in days (week / month / year …); only used when the sort
    /// is `.trending`.
    private(set) var trendingDays: Int = 7
    private(set) var currentRequest: WorkshopQueryRequest
    private(set) var items: [WorkshopQueryItem] = []
    private(set) var nextCursor: String?
    private(set) var totalAvailable: Int?
    private(set) var isLoading: Bool = false
    /// True while stepping to an adjacent page (prev/next) — current results
    /// stay on screen until the new page replaces them, so memory stays bounded.
    private(set) var isPaging: Bool = false
    private(set) var lastError: WorkshopQueryError?
    /// Set when Steam returns HTTP 429; controls stay disabled until it lapses.
    private(set) var rateLimitUntil: Date?

    /// 1-based page number for the prev/next pager. Steam's QueryFiles cursor
    /// pagination only walks forward, so we keep the cursor that opened each
    /// visited page and step the stack instead of jumping to an arbitrary page.
    private(set) var pageIndex: Int = 1
    @ObservationIgnored private var cursorStack: [String] = ["*"]

    var isRateLimited: Bool {
        (rateLimitUntil ?? .distantPast) > Date()
    }

    var canGoNextPage: Bool {
        guard !isRateLimited, !isLoading, !isPaging, let cursor = nextCursor else { return false }
        return !cursor.isEmpty && cursor != "*"
    }

    var canGoPrevPage: Bool {
        !isRateLimited && !isLoading && !isPaging && cursorStack.count > 1
    }

    @ObservationIgnored private var filterDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var inflightFetch: Task<Bool, Never>?
    @ObservationIgnored private var currentRequestToken: UInt64 = 0

    init(services: WorkshopServices) {
        self.services = services
        self.currentRequest = WorkshopQueryRequest(sort: .topRated)
    }

    func onAppear() {
        if items.isEmpty, lastError == nil {
            Task { await reload() }
        }
    }

    func reload() async {
        guard !isRateLimited else { return }
        inflightFetch?.cancel()
        filterDebounceTask?.cancel()
        cursorStack = ["*"]
        pageIndex = 1
        let request = makeRequest(cursor: "*")
        currentRequest = request
        items = []
        nextCursor = nil
        totalAvailable = nil
        isLoading = true
        isPaging = false
        lastError = nil
        _ = await runFetch(request, replacingItems: true, paging: false)
    }

    /// Step forward one page (cursor walk). Current results stay visible until
    /// the new page arrives; the stack only advances on success so a failed
    /// step leaves the pager consistent.
    func goToNextPage() async {
        guard canGoNextPage, let cursor = nextCursor else { return }
        isPaging = true
        let request = makeRequest(cursor: cursor)
        let ok = await runFetch(request, replacingItems: true, paging: true)
        if ok {
            cursorStack.append(cursor)
            pageIndex += 1
        }
    }

    /// Step back to the previously visited page using its remembered cursor.
    func goToPrevPage() async {
        guard canGoPrevPage, cursorStack.count > 1 else { return }
        let target = cursorStack[cursorStack.count - 2]
        isPaging = true
        let request = makeRequest(cursor: target)
        let ok = await runFetch(request, replacingItems: true, paging: true)
        if ok {
            cursorStack.removeLast()
            pageIndex -= 1
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

    /// Combined sort + trending-window update (the period is folded into the
    /// sort menu, so there's a single control). Days are ignored for non-trending
    /// sorts.
    func updateSortOption(_ sort: WorkshopSortMode, days: Int) {
        guard !isRateLimited else { return }
        let changed = sort != preferredSort || (sort == .trending && days != trendingDays)
        guard changed else { return }
        preferredSort = sort
        if sort == .trending { trendingDays = days }
        scheduleFilterReload()
    }

    func updateType(_ type: WorkshopContentTypeFilter) {
        guard !isRateLimited, type != typeFilter else { return }
        typeFilter = type
        scheduleFilterReload()
    }

    func updateAgeRating(_ rating: WorkshopAgeRatingFilter) {
        guard !isRateLimited, rating != ageRating else { return }
        ageRating = rating
        scheduleFilterReload()
    }

    func updateResolution(_ resolution: WorkshopResolutionFilter) {
        guard !isRateLimited, resolution != self.resolution else { return }
        self.resolution = resolution
        scheduleFilterReload()
    }

    func toggleGenre(_ tag: String) {
        guard !isRateLimited else { return }
        if selectedGenres.contains(tag) {
            selectedGenres.remove(tag)
        } else {
            selectedGenres.insert(tag)
        }
        scheduleFilterReload()
    }

    func clearGenres() {
        guard !isRateLimited, !selectedGenres.isEmpty else { return }
        selectedGenres.removeAll()
        scheduleFilterReload()
    }

    /// Coalesce rapid multi-select toggles (and back-to-back single-select
    /// changes) into ONE request — the key API-economy lever: checking three
    /// genres fires a single reload, not three. The 5-minute query cache then
    /// de-dupes any repeated combination.
    private func scheduleFilterReload() {
        filterDebounceTask?.cancel()
        filterDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.reload()
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
                    self.items = page.items
                }
                self.nextCursor = page.nextCursor
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

    private func makeRequest(cursor: String) -> WorkshopQueryRequest {
        let trimmed = searchInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var required = typeFilter.requiredTags + selectedGenres.sorted()
        if let resolutionTag = resolution.tag {
            required.append(resolutionTag)
        }
        return WorkshopQueryRequest(
            sort: preferredSort,
            searchText: trimmed,
            cursor: cursor,
            numPerPage: 50,
            days: preferredSort == .trending ? trendingDays : nil,
            requiredTags: required,
            excludedTags: ageRating.excludedTags
        )
    }
}
#endif
