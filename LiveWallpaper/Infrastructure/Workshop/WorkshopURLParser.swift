#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation

/// Parses the URL/ID forms accepted by the Workshop paste sheet. Accepted
/// inputs are documented in
/// `docs/2026-05-28-steam-workshop-integration-plan.md` ("Workshop URL
/// formats accepted by parser"):
///
/// * `https://steamcommunity.com/sharedfiles/filedetails/?id=<id>`
/// * `https://steamcommunity.com/sharedfiles/filedetails?id=<id>`
/// * `https://steamcommunity.com/workshop/filedetails/?id=<id>`
/// * `https://steamcommunity.com/workshop/filedetails?id=<id>`
/// * `steam://url/CommunityFilePage/<id>`
/// * Bare `publishedfileid` integers (1–20 digits).
///
/// IDs are validated as `UInt64`, reject leading zeros longer than one digit
/// (Steam ids are always canonical decimal).
enum WorkshopURLParser {

    /// Result of parsing a single token.
    enum ParsedItem: Equatable, Sendable {
        case ok(publishedFileID: UInt64, original: String)
        case invalid(reason: InvalidReason, original: String)
    }

    enum InvalidReason: String, Equatable, Sendable {
        /// The input was empty after trimming.
        case empty
        /// The input is not a recognized Workshop URL form.
        case unsupportedURL
        /// The query string had no `id` parameter.
        case missingID
        /// The `id` value was not a positive `UInt64`.
        case malformedID
        /// The `id` value overflowed `UInt64`.
        case overflowID
        /// The host did not match a known Steam endpoint.
        case unknownHost
    }

    /// Splits a pasted blob into individual tokens. Accepts whitespace,
    /// newlines, commas, and semicolons as separators. Order-preserving and
    /// duplicate-tolerant; callers handle dedupe.
    static func tokenize(_ blob: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;\n\r\t ")
        return blob
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Parses a single token. Public so the import sheet can preview the
    /// outcome before staging the row.
    static func parse(_ raw: String) -> ParsedItem {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return .invalid(reason: .empty, original: raw)
        }

        // Bare numeric id (most common shortcut).
        if token.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return parseNumericID(token, original: raw)
        }

        // steam:// URL.
        if token.lowercased().hasPrefix("steam://") {
            return parseSteamURL(token, original: raw)
        }

        // http(s) URL.
        if let scheme = URL(string: token)?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return parseHTTPSURL(token, original: raw)
        }

        return .invalid(reason: .unsupportedURL, original: raw)
    }

    /// Bulk-parse + dedupe. Returns parsed items in input order; duplicates
    /// (same `publishedFileID`) collapse to the first occurrence with a
    /// second-result count for UI display.
    static func parseAll(_ blob: String) -> [ParsedItem] {
        var seen: Set<UInt64> = []
        var results: [ParsedItem] = []
        for token in tokenize(blob) {
            let parsed = parse(token)
            switch parsed {
            case .ok(let id, _):
                if seen.insert(id).inserted {
                    results.append(parsed)
                }
            case .invalid:
                results.append(parsed)
            }
        }
        return results
    }

    // MARK: - Private

    private static func parseNumericID(_ token: String, original: String) -> ParsedItem {
        // Reject "00...", "0", and overflow.
        guard token.count <= 20,
              !(token.count > 1 && token.first == "0"),
              token != "0" else {
            return .invalid(reason: .malformedID, original: original)
        }
        guard let id = UInt64(token) else {
            return .invalid(reason: .overflowID, original: original)
        }
        return .ok(publishedFileID: id, original: original)
    }

    private static func parseSteamURL(_ token: String, original: String) -> ParsedItem {
        // `steam://url/CommunityFilePage/<id>` — entire tail must be digits.
        let prefix = "steam://url/CommunityFilePage/"
        guard token.lowercased().hasPrefix(prefix.lowercased()) else {
            return .invalid(reason: .unsupportedURL, original: original)
        }
        let tail = String(token.dropFirst(prefix.count))
        // Reject trailing junk like `…/123abc` — historically users have
        // pasted partial copies and we want a clean error rather than a
        // silent prefix-match.
        guard tail.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return .invalid(reason: .malformedID, original: original)
        }
        return parseNumericID(tail, original: original)
    }

    private static func parseHTTPSURL(_ token: String, original: String) -> ParsedItem {
        guard let components = URLComponents(string: token) else {
            return .invalid(reason: .unsupportedURL, original: original)
        }
        // Reject embedded credentials and non-standard ports — the canonical
        // Steam community URL never carries either, so anything that does is
        // almost certainly an attempt to disguise a redirect.
        guard components.user == nil, components.password == nil else {
            return .invalid(reason: .unsupportedURL, original: original)
        }
        if let port = components.port, port != 443 {
            return .invalid(reason: .unsupportedURL, original: original)
        }
        guard let host = components.host?.lowercased(), host == "steamcommunity.com" else {
            return .invalid(reason: .unknownHost, original: original)
        }

        // Path forms (with or without trailing slash):
        //   /sharedfiles/filedetails        /sharedfiles/filedetails/
        //   /workshop/filedetails           /workshop/filedetails/
        let normalizedPath = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let acceptedPaths: Set<String> = [
            "sharedfiles/filedetails",
            "workshop/filedetails"
        ]
        guard acceptedPaths.contains(normalizedPath) else {
            return .invalid(reason: .unsupportedURL, original: original)
        }

        guard let idValue = components.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value,
              !idValue.isEmpty else {
            return .invalid(reason: .missingID, original: original)
        }
        return parseNumericID(idValue, original: original)
    }
}
#endif
