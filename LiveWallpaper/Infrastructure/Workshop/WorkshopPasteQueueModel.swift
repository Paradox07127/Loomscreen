#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import Combine
import Foundation
import Observation

/// Drives [WorkshopPasteSheet]. Owns the parsed-row state machine described
/// in `docs/2026-05-28-steam-workshop-integration-plan.md` ("State machine
/// per `WorkshopPasteRowCard`"). The state machine in v1 is bounded:
///
/// `parsing → fetchingMetadata → ready` and several terminal `failed(...)`
/// states. Download / import states are reserved for Phase 3.
@MainActor
@Observable
final class WorkshopPasteQueueModel {

    struct Row: Identifiable, Sendable {
        let id: UUID
        let publishedFileID: UInt64?
        let originalInput: String
        var state: RowState
        var metadata: SteamWorkshopMetadata?
        var error: SteamWorkshopMetadataError?

        /// URL to open in Steam, regardless of fetch outcome. Always
        /// constructed from the validated id when we have one; falls back to
        /// a search URL using the raw input otherwise.
        var steamURL: URL? {
            if let id = publishedFileID {
                return URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")
            }
            return nil
        }
    }

    enum RowState: Equatable, Sendable {
        case invalidInput
        case fetchingMetadata
        case ready
        case failed
    }

    private(set) var rawInput: String = ""
    private(set) var rows: [Row] = []
    /// Counter for showing a "12 added, 3 duplicates, 1 invalid" summary
    /// after the user clicks "Add to queue".
    private(set) var lastIngestionSummary: IngestionSummary?

    struct IngestionSummary: Equatable, Sendable {
        let added: Int
        let duplicates: Int
        let invalid: Int
    }

    private let metadataService: SteamWorkshopMetadataService
    private var inflightFetches: [UUID: Task<Void, Never>] = [:]

    init(metadataService: SteamWorkshopMetadataService = SteamWorkshopMetadataService()) {
        self.metadataService = metadataService
    }

    // Note: no `deinit` cancellation here. The fetch tasks capture
    // `[weak self]` and become no-ops once `self` is released; Swift's
    // strict-concurrency rules don't let a nonisolated `deinit` touch
    // main-actor state. `removeAll()` is the caller-driven escape hatch
    // when a sheet wants to shed in-flight work before disappearing.

    // MARK: - Public API

    func updateRawInput(_ value: String) {
        rawInput = value
    }

    /// Parses the textbox blob, dedupes against the existing queue, and kicks
    /// off metadata fetches for the new rows. Existing rows are not
    /// disturbed.
    func ingestFromRawInput() {
        let parsed = WorkshopURLParser.parseAll(rawInput)
        var added = 0
        var duplicates = 0
        var invalid = 0

        let existingIDs = Set(rows.compactMap(\.publishedFileID))

        for item in parsed {
            switch item {
            case .ok(let id, let original):
                if existingIDs.contains(id) {
                    duplicates += 1
                    continue
                }
                let row = Row(
                    id: UUID(),
                    publishedFileID: id,
                    originalInput: original,
                    state: .fetchingMetadata,
                    metadata: nil,
                    error: nil
                )
                rows.append(row)
                added += 1
                scheduleMetadataFetch(rowID: row.id, publishedFileID: id)
            case .invalid(let reason, let original):
                let row = Row(
                    id: UUID(),
                    publishedFileID: nil,
                    originalInput: original,
                    state: .invalidInput,
                    metadata: nil,
                    error: .invalidInput(reason)
                )
                rows.append(row)
                invalid += 1
            }
        }
        rawInput = ""
        lastIngestionSummary = IngestionSummary(added: added, duplicates: duplicates, invalid: invalid)
    }

    /// Re-runs the metadata fetch for one row. Idempotent: cancels any
    /// existing in-flight task for the same row first.
    func retry(rowID: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }),
              let id = rows[index].publishedFileID else { return }
        rows[index].state = .fetchingMetadata
        rows[index].error = nil
        scheduleMetadataFetch(rowID: rowID, publishedFileID: id)
    }

    func remove(rowID: UUID) {
        inflightFetches.removeValue(forKey: rowID)?.cancel()
        rows.removeAll { $0.id == rowID }
    }

    func removeAll() {
        for task in inflightFetches.values { task.cancel() }
        inflightFetches.removeAll()
        rows.removeAll()
    }

    /// Opens every row that has a known Steam URL via `NSWorkspace`. This is
    /// the v1 batch action that lets the user kick off downloads in the real
    /// Steam client until Phase 3 lands.
    func openAllInSteam() {
        for row in rows {
            guard let url = row.steamURL else { continue }
            NSWorkspace.shared.open(url)
        }
    }

    func diagnosticPayload(for rowID: UUID) -> WorkshopDiagnosticPayload? {
        guard let row = rows.first(where: { $0.id == rowID }) else { return nil }
        let regexMatch: String?
        let tail: String
        switch row.error {
        case .invalidInput(let reason):
            regexMatch = "parser:\(reason.rawValue)"
            tail = "Input: \(row.originalInput)"
        case .unauthorized:
            regexMatch = "http:401_403"
            tail = "GetPublishedFileDetails returned 401/403 (unauthorized) for id \(row.publishedFileID.map(String.init) ?? "?")"
        case .http(let status):
            regexMatch = "http:\(status)"
            tail = "GetPublishedFileDetails HTTP \(status) for id \(row.publishedFileID.map(String.init) ?? "?")"
        case .rateLimited(let retry):
            regexMatch = "http:429"
            tail = "GetPublishedFileDetails rate limited; retry-after=\(retry.map(String.init(describing:)) ?? "nil")"
        case .timeout:
            regexMatch = "network:timeout"
            tail = "GetPublishedFileDetails timed out"
        case .networkUnreachable:
            regexMatch = "network:unreachable"
            tail = "Network unreachable"
        case .responseParseFailure, .schemaMismatch:
            regexMatch = "decode:failure"
            tail = "GetPublishedFileDetails response did not match the expected schema"
        case .itemPrivate:
            regexMatch = "visibility:private"
            tail = "Workshop item is private or friends-only"
        case .itemBanned:
            regexMatch = "visibility:banned"
            tail = "Workshop item is flagged as banned by Steam"
        case .itemNotFound:
            regexMatch = "result:not_found"
            tail = "Workshop item not found (Steam result code 9 or empty payload)"
        case .cancelled:
            regexMatch = "user:cancelled"
            tail = "Fetch cancelled by user"
        case .unknown(let detail):
            regexMatch = nil
            tail = detail
        case .none:
            regexMatch = nil
            tail = "Row state: \(row.state)"
        }
        return WorkshopDiagnosticPayload(phase: .metadata, regexMatch: regexMatch, tail: tail)
    }

    // MARK: - Private

    private func scheduleMetadataFetch(rowID: UUID, publishedFileID id: UInt64) {
        inflightFetches.removeValue(forKey: rowID)?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.metadataService.fetch(publishedFileID: id)
            self.applyFetchResult(rowID: rowID, result: result)
            self.inflightFetches.removeValue(forKey: rowID)
        }
        inflightFetches[rowID] = task
    }

    private func applyFetchResult(
        rowID: UUID,
        result: Result<SteamWorkshopMetadata, SteamWorkshopMetadataError>
    ) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        switch result {
        case .success(let metadata):
            rows[index].metadata = metadata
            rows[index].state = .ready
            rows[index].error = nil
        case .failure(let error):
            rows[index].metadata = nil
            rows[index].state = .failed
            rows[index].error = error
        }
    }
}
#endif
