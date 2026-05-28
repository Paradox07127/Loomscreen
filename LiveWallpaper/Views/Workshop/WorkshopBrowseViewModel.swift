#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation
import Observation

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
    private(set) var currentRequest: WorkshopQueryRequest
    private(set) var items: [WorkshopQueryItem] = []
    private(set) var nextCursor: String?
    private(set) var totalAvailable: Int?
    private(set) var isLoading: Bool = false
    private(set) var isLoadingMore: Bool = false
    private(set) var lastError: WorkshopQueryError?

    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var inflightFetch: Task<Void, Never>?
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
        inflightFetch?.cancel()
        debounceTask?.cancel()
        let request = makeRequest(cursor: "*")
        currentRequest = request
        items = []
        nextCursor = nil
        totalAvailable = nil
        isLoading = true
        lastError = nil
        await runFetch(request, append: false)
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, let cursor = nextCursor, !cursor.isEmpty, cursor != "*" else { return }
        let request = makeRequest(cursor: cursor)
        isLoadingMore = true
        await runFetch(request, append: true)
    }

    func updateSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchInput = text
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            if trimmed != self.currentRequest.searchText {
                await self.reload()
            }
        }
    }

    func updateSort(_ sort: WorkshopSortMode) {
        guard sort != preferredSort else { return }
        preferredSort = sort
        Task { await reload() }
    }

    private func runFetch(_ request: WorkshopQueryRequest, append: Bool) async {
        currentRequestToken &+= 1
        let token = currentRequestToken
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.services.queryService.fetch(request)
                // Drop the result if a newer fetch has started since.
                guard token == self.currentRequestToken else { return }
                if append {
                    let existingIDs = Set(self.items.map(\.id))
                    self.items.append(contentsOf: page.items.filter { !existingIDs.contains($0.id) })
                } else {
                    self.items = page.items
                }
                self.nextCursor = page.nextCursor
                self.totalAvailable = page.totalAvailable
                self.lastError = nil
            } catch let error as WorkshopQueryError {
                guard token == self.currentRequestToken else { return }
                self.lastError = error
            } catch is CancellationError {
                // ignore — user-triggered reload
            } catch {
                guard token == self.currentRequestToken else { return }
                self.lastError = .responseParseFailure
            }
            guard token == self.currentRequestToken else { return }
            if append {
                self.isLoadingMore = false
            } else {
                self.isLoading = false
            }
        }
        inflightFetch = task
        await task.value
    }

    private func makeRequest(cursor: String) -> WorkshopQueryRequest {
        let trimmed = searchInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkshopQueryRequest(
            sort: preferredSort,
            searchText: trimmed,
            cursor: cursor,
            numPerPage: 50
        )
    }
}
#endif
