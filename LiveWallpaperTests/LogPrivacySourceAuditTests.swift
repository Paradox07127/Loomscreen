import Foundation
import Testing
import os

@Suite("Log privacy source audit")
struct LogPrivacySourceAuditTests {
    private typealias ReviewedPrivacyAlias = OSLogPrivacy

    /// Direct `os.Logger` public interpolation is deny-by-default. The key is
    /// the source file, then the whitespace-normalized expression and reviewed
    /// occurrence count. A new value — even an opaque alias — requires an
    /// explicit privacy review instead of trying to infer sensitivity by name.
    private static let allowedPublicExpressions: [String: [String: Int]] = [
        "LiveWallpaper/Monitor/MonitorRuntime.swift": [
            "built.map(\\.sourceID).joined(separator:\",\")": 1,
        ],
        "LiveWallpaper/Monitor/MonitorSourceAuthorization.swift": [
            "provider.defaultDirectoryName": 6,
        ],
        "LiveWallpaper/Monitor/MonitorFocusRouter.swift": [
            "sessionID": 2,
            "leafPID": 1,
            "ownerPID": 2,
            "bundleID": 1,
        ],
        "LiveWallpaper/Monitor/Sources/MonitorUsageBackfill.swift": [
            "file.size": 1,
        ],
        "Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/App/Logger.swift": [
            "level.prefix": 1,
            "fileName": 1,
            "line": 1,
            "function": 1,
            "body": 1,
        ],
    ]

    @Test("Direct public OSLog values stay on the reviewed allowlist")
    func directPublicOSLogValuesStayAllowlisted() throws {
        let appFiles = RepositoryRoot.swiftFiles(under: "LiveWallpaper")
        let packageSources = RepositoryRoot.swiftFiles(under: "Packages")
            .filter { $0.path.contains("/Sources/") }
        let files = appFiles + packageSources
        #expect(files.count > 450, "Production source sweep collapsed to \(files.count) files")

        var observed: [String: [String: Int]] = [:]
        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let relativePath = file.path.replacingOccurrences(
                of: RepositoryRoot.url.path + "/",
                with: ""
            )
            let expressions = Self.publicInterpolationExpressions(in: source)
            if Self.containsLegacyPublicFormat(in: source) {
                violations.append("\(relativePath): legacy %{public} format")
            }
            for expression in expressions {
                observed[relativePath, default: [:]][expression, default: 0] += 1
                let count = observed[relativePath]?[expression] ?? 0
                let allowedCount = Self.allowedPublicExpressions[relativePath]?[expression] ?? 0
                if count > allowedCount {
                    violations.append("\(relativePath): unreviewed public expression `\(expression)`")
                }
            }
        }

        let staleAllowlist = Self.allowedPublicExpressions.flatMap { file, expressions in
            expressions.compactMap { expression, expectedCount -> String? in
                let actualCount = observed[file]?[expression] ?? 0
                return actualCount == expectedCount
                    ? nil
                    : "\(file): `\(expression)` expected \(expectedCount), found \(actualCount)"
            }
        }
        #expect(
            violations.isEmpty,
            Comment(rawValue: "Unreviewed direct-public OSLog values:\n\(violations.joined(separator: "\n"))")
        )
        #expect(
            staleAllowlist.isEmpty,
            Comment(rawValue: "Public-log allowlist drifted; shrink or re-review it:\n\(staleAllowlist.joined(separator: "\n"))")
        )
    }

    @Test("The deny-by-default audit catches alias, transform, multiline, and legacy shapes")
    func detectorRejectsKnownLeakShapes() {
        let fixtures = [
            #"log.warning("selected=\(chosen, privacy: .public)")"#,
            #"log.info("selected=\(root, privacy: .public)")"#,
            #"log.info("selected=\(url.relativeString, privacy: .public)")"#,
            #"log.info("selected=\(url.path.lowercased(), privacy: .public)")"#,
            #"log.info("selected=\(url, privacy: OSLogPrivacy.public)")"#,
            #"log.info("selected=\(url, privacy: .public.self)")"#,
            #"log.info("selected=\(url, privacy: OSLogPrivacy.public.self)")"#,
            #"log.info("selected=\(url, privacy: ReviewedPrivacyAlias.public)")"#,
            #"log.info("selected=\(url, privacy: /* reviewed? */ .public)")"#,
            #"log.info("selected=\(url, privacy: os.OSLogPrivacy.public)")"#,
            #"log.info("selected=\(url, privacy: (OSLogPrivacy.public))")"#,
            #"log.info("selected=\(url, privacy: OSLogPrivacy.`public`)")"#,
            #"log.info("selected=\(url, /* comment */ privacy: .public)")"#,
            #"log.info("selected=\(url, `privacy`: .public)")"#,
            #"log.info("selected=\(url, privacy: . /* dot trivia */ `public`)")"#,
            #"log.info("selected=\(url, privacy: `OSLogPrivacy` /* lhs */ . /* rhs */ `public`)")"#,
            #"log.info("selected=\(url, privacy: ( /* outer */ (( /* inner */ .public )) /* outer */ ))")"#,
            #"log.info("selected=\(url, `privacy`: ((`os` /* qualifier */ . /* type dot */ `OSLogPrivacy` /* member dot */ . `public`)))")"#,
            #"""
            log.warning("selected=\(
                url.path(percentEncoded: false),
                privacy: .public
            )")
            """#,
        ]
        for fixture in fixtures {
            #expect(!Self.publicInterpolationExpressions(in: fixture).isEmpty)
        }
        #expect(Self.containsLegacyPublicFormat(in: #"os_log("selected=%{public}@", url.path)"#))
        #expect(Self.containsLegacyPublicFormat(in: #"os_log("selected=%{public,string}@", url.path)"#))
        #expect(Self.containsLegacyPublicFormat(in: #"os_log("selected=%{mask.hash, public}@", url.path)"#))
        #expect(!Self.containsLegacyPublicFormat(in: #"os_log("selected=%{publicity,string}@", url.path)"#))
        #expect(Self.publicInterpolationExpressions(
            in: #"log.warning("selected=\(chosen.path, privacy: .private)")"#
        ).isEmpty)
        #expect(Self.publicInterpolationExpressions(
            in: #"// log.warning("selected=\(chosen.path, privacy: .public)")"#
        ).isEmpty)
        #expect(Self.publicInterpolationExpressions(
            in: ##"let example = #"selected=\#(chosen.path, privacy: .private)"#"##
        ).isEmpty)
    }

    @Test("Raw delimiters and regex literals cannot hide later public interpolation")
    func rawDelimitersAndRegexLiteralsDoNotPoisonTheScanner() {
        let fixtures = [
            ##"""
            log.info(#"prefix \#"# suffix \#(url.path, privacy: .public)"#)
            """##,
            ##"""
            log.info(#"""
            prefix \#"""# suffix
            \#(url.path, privacy: .public)
            """#)
            """##,
            ##"""
            let _ = #/foo/*bar/#
            log.info("selected=\(url.path, privacy: .public)")
            """##,
            ##"""
            let _ = #/foo//bar/#
            log.info("selected=\(url.path, privacy: .public)")
            """##,
        ]

        for fixture in fixtures {
            #expect(Self.publicInterpolationExpressions(in: fixture) == ["url.path"])
        }
    }

    @Test("Swift accepts every public shape guarded by the audit")
    func compilerAcceptsGuardedPublicShapes() {
        let value = "reviewed fixture"
        let _: OSLogMessage = "\(value, privacy: ( /* outer */ (( /* inner */ `os` /* qualifier */ . /* type dot */ `OSLogPrivacy` /* member dot */ . `public` )) /* outer */ ))"
        let _: OSLogMessage = "\(value, privacy: .public.self)"
        let _: OSLogMessage = "\(value, privacy: OSLogPrivacy.public.self)"
        let _: OSLogMessage = "\(value, privacy: ReviewedPrivacyAlias.public)"
        let _: OSLogMessage = #"prefix \#"# suffix \#(value, privacy: .public)"#
        let _: OSLogMessage = #"""
        prefix \#"""# suffix
        \#(value, privacy: .public)
        """#
        let _ = #/foo/*bar/#
        os_log("value=%{public,string}@", value as NSString)
    }

    private static func publicInterpolationExpressions(in source: String) -> [String] {
        var scanner = PublicInterpolationScanner(source: source)
        return scanner.scan()
    }

    /// A small Swift-aware scanner keeps this security gate independent of a
    /// SwiftSyntax dependency while still handling lexical trivia correctly.
    /// It only inspects interpolation argument lists inside real string
    /// literals; comments and ordinary string contents cannot create matches.
    private struct PublicInterpolationScanner {
        private struct StringDelimiter {
            let hashCount: Int
            let quoteCount: Int

            var openingLength: Int { hashCount + quoteCount }
            var closingLength: Int { quoteCount + hashCount }
        }

        private struct ExtendedRegexDelimiter {
            let hashCount: Int

            var openingLength: Int { hashCount + 1 }
            var closingLength: Int { 1 + hashCount }
        }

        private enum TokenKind: Equatable {
            case identifier(String)
            case symbol(UInt8)
            case opaque
        }

        private struct Token {
            let kind: TokenKind
            let start: Int
        }

        private let bytes: [UInt8]
        private var expressions: [String] = []

        init(source: String) {
            bytes = Array(source.utf8)
        }

        mutating func scan() -> [String] {
            var index = 0
            while index < bytes.count {
                if let commentEnd = commentEnd(startingAt: index) {
                    index = commentEnd
                } else if let delimiter = stringDelimiter(at: index) {
                    scanString(startingAt: &index, delimiter: delimiter)
                } else if let delimiter = extendedRegexDelimiter(at: index) {
                    skipExtendedRegex(startingAt: &index, delimiter: delimiter, limit: bytes.count)
                } else {
                    index += 1
                }
            }
            return expressions
        }

        private mutating func scanString(
            startingAt index: inout Int,
            delimiter: StringDelimiter
        ) {
            var cursor = index + delimiter.openingLength
            while cursor < bytes.count {
                if matchesClosingDelimiter(delimiter, at: cursor) {
                    index = cursor + delimiter.closingLength
                    return
                }
                if let openParenthesis = interpolationOpenParenthesis(
                    at: cursor,
                    hashCount: delimiter.hashCount
                ) {
                    cursor = scanInterpolation(openParenthesis: openParenthesis)
                    continue
                }
                // An escape uses the string delimiter's exact hash count. Skip
                // its escaped scalar so an escaped quote cannot look like the
                // closing delimiter (including raw and raw-multiline strings).
                if let escapeEnd = escapedElementEnd(
                    at: cursor,
                    hashCount: delimiter.hashCount,
                    limit: bytes.count
                ) {
                    cursor = escapeEnd
                    continue
                }
                cursor += 1
            }
            index = cursor
        }

        private mutating func scanInterpolation(openParenthesis: Int) -> Int {
            let contentStart = openParenthesis + 1
            var cursor = contentStart
            var parenthesisDepth = 1
            while cursor < bytes.count {
                if let commentEnd = commentEnd(startingAt: cursor) {
                    cursor = commentEnd
                    continue
                }
                if let delimiter = stringDelimiter(at: cursor) {
                    scanString(startingAt: &cursor, delimiter: delimiter)
                    continue
                }
                if let delimiter = extendedRegexDelimiter(at: cursor) {
                    skipExtendedRegex(startingAt: &cursor, delimiter: delimiter, limit: bytes.count)
                    continue
                }
                switch bytes[cursor] {
                case Self.leftParenthesis:
                    parenthesisDepth += 1
                case Self.rightParenthesis:
                    parenthesisDepth -= 1
                    if parenthesisDepth == 0 {
                        inspectInterpolation(from: contentStart, to: cursor)
                        return cursor + 1
                    }
                default:
                    break
                }
                cursor += 1
            }
            return cursor
        }

        private mutating func inspectInterpolation(from start: Int, to end: Int) {
            let tokens = tokens(from: start, to: end)
            guard !tokens.isEmpty else { return }

            var segmentRanges: [Range<Int>] = []
            var segmentStart = 0
            var nesting: [UInt8] = []
            var firstSeparatorOffset: Int?
            for (offset, token) in tokens.enumerated() {
                guard case let .symbol(symbol) = token.kind else { continue }
                switch symbol {
                case Self.leftParenthesis, Self.leftBracket, Self.leftBrace:
                    nesting.append(symbol)
                case Self.rightParenthesis, Self.rightBracket, Self.rightBrace:
                    if !nesting.isEmpty { nesting.removeLast() }
                case Self.comma where nesting.isEmpty:
                    firstSeparatorOffset = firstSeparatorOffset ?? token.start
                    segmentRanges.append(segmentStart..<offset)
                    segmentStart = offset + 1
                default:
                    break
                }
            }
            segmentRanges.append(segmentStart..<tokens.count)

            guard let expressionEnd = firstSeparatorOffset,
                  segmentRanges.dropFirst().contains(where: { segment in
                      isPublicPrivacyArgument(Array(tokens[segment]))
                  }) else {
                return
            }
            let expression = String(decoding: bytes[start..<expressionEnd], as: UTF8.self)
                .filter { !$0.isWhitespace }
            expressions.append(expression.isEmpty ? "<unparsed>" : expression)
        }

        private func isPublicPrivacyArgument(_ tokens: [Token]) -> Bool {
            guard tokens.count >= 3,
                  tokens[0].kind == .identifier("privacy"),
                  tokens[1].kind == .symbol(Self.colon) else {
                return false
            }
            return isPublicPrivacyValue(Array(tokens.dropFirst(2)))
        }

        private func isPublicPrivacyValue(_ originalTokens: [Token]) -> Bool {
            var tokens = originalTokens
            while enclosesEntireExpression(tokens) {
                tokens.removeFirst()
                tokens.removeLast()
            }

            // The compiler accepts aliases and static-member suffixes such as
            // `PrivacyAlias.public` and `.public.self`. A source-only lexer
            // cannot resolve aliases, so deny any privacy value containing the
            // public member instead of maintaining a bypassable type-name list.
            return tokens.indices.dropLast().contains { offset in
                tokens[offset].kind == .symbol(Self.dot)
                    && tokens[offset + 1].kind == .identifier("public")
            }
        }

        private func enclosesEntireExpression(_ tokens: [Token]) -> Bool {
            guard tokens.count >= 2,
                  tokens.first?.kind == .symbol(Self.leftParenthesis),
                  tokens.last?.kind == .symbol(Self.rightParenthesis) else {
                return false
            }
            var depth = 0
            for (offset, token) in tokens.enumerated() {
                if token.kind == .symbol(Self.leftParenthesis) {
                    depth += 1
                } else if token.kind == .symbol(Self.rightParenthesis) {
                    depth -= 1
                    if depth == 0, offset != tokens.count - 1 { return false }
                }
            }
            return depth == 0
        }

        private func tokens(from start: Int, to end: Int) -> [Token] {
            var result: [Token] = []
            var cursor = start
            while cursor < end {
                if Self.isWhitespace(bytes[cursor]) {
                    cursor += 1
                    continue
                }
                if let commentEnd = commentEnd(startingAt: cursor) {
                    cursor = min(commentEnd, end)
                    continue
                }
                if bytes[cursor] == Self.backtick {
                    let tokenStart = cursor
                    cursor += 1
                    let identifierStart = cursor
                    while cursor < end, bytes[cursor] != Self.backtick { cursor += 1 }
                    if cursor < end {
                        let name = String(decoding: bytes[identifierStart..<cursor], as: UTF8.self)
                        cursor += 1
                        result.append(Token(kind: .identifier(name), start: tokenStart))
                    } else {
                        result.append(Token(kind: .symbol(Self.backtick), start: tokenStart))
                    }
                    continue
                }
                if Self.isIdentifierStart(bytes[cursor]) {
                    let tokenStart = cursor
                    cursor += 1
                    while cursor < end, Self.isIdentifierContinuation(bytes[cursor]) {
                        cursor += 1
                    }
                    let name = String(decoding: bytes[tokenStart..<cursor], as: UTF8.self)
                    result.append(Token(kind: .identifier(name), start: tokenStart))
                    continue
                }
                if let delimiter = stringDelimiter(at: cursor) {
                    let tokenStart = cursor
                    var tokenEnd = cursor
                    skipString(startingAt: &tokenEnd, delimiter: delimiter, limit: end)
                    cursor = tokenEnd
                    result.append(Token(kind: .opaque, start: tokenStart))
                    continue
                }
                if let delimiter = extendedRegexDelimiter(at: cursor) {
                    let tokenStart = cursor
                    var tokenEnd = cursor
                    skipExtendedRegex(startingAt: &tokenEnd, delimiter: delimiter, limit: end)
                    cursor = tokenEnd
                    result.append(Token(kind: .opaque, start: tokenStart))
                    continue
                }
                result.append(Token(kind: .symbol(bytes[cursor]), start: cursor))
                cursor += 1
            }
            return result
        }

        private func skipString(
            startingAt index: inout Int,
            delimiter: StringDelimiter,
            limit: Int
        ) {
            var cursor = index + delimiter.openingLength
            while cursor < limit {
                if matchesClosingDelimiter(delimiter, at: cursor) {
                    index = min(cursor + delimiter.closingLength, limit)
                    return
                }
                if let escapeEnd = escapedElementEnd(
                    at: cursor,
                    hashCount: delimiter.hashCount,
                    limit: limit
                ) {
                    cursor = escapeEnd
                    continue
                }
                cursor += 1
            }
            index = cursor
        }

        private func extendedRegexDelimiter(at index: Int) -> ExtendedRegexDelimiter? {
            guard index < bytes.count else { return nil }
            var cursor = index
            var hashCount = 0
            while cursor < bytes.count, bytes[cursor] == Self.hash {
                hashCount += 1
                cursor += 1
            }
            guard hashCount > 0,
                  cursor < bytes.count,
                  bytes[cursor] == Self.slash else {
                return nil
            }
            return ExtendedRegexDelimiter(hashCount: hashCount)
        }

        private func skipExtendedRegex(
            startingAt index: inout Int,
            delimiter: ExtendedRegexDelimiter,
            limit: Int
        ) {
            var cursor = index + delimiter.openingLength
            while cursor < limit {
                if matchesClosingDelimiter(delimiter, at: cursor) {
                    index = min(cursor + delimiter.closingLength, limit)
                    return
                }
                if let escapeEnd = escapedElementEnd(
                    at: cursor,
                    hashCount: delimiter.hashCount,
                    limit: limit
                ) {
                    cursor = escapeEnd
                    continue
                }
                cursor += 1
            }
            index = cursor
        }

        private func stringDelimiter(at index: Int) -> StringDelimiter? {
            guard index < bytes.count else { return nil }
            var cursor = index
            var hashCount = 0
            while cursor < bytes.count, bytes[cursor] == Self.hash {
                hashCount += 1
                cursor += 1
            }
            guard cursor < bytes.count, bytes[cursor] == Self.quote else { return nil }
            let quoteCount = matches([Self.quote, Self.quote, Self.quote], at: cursor) ? 3 : 1
            return StringDelimiter(hashCount: hashCount, quoteCount: quoteCount)
        }

        private func matchesClosingDelimiter(_ delimiter: StringDelimiter, at index: Int) -> Bool {
            let closing = Array(repeating: Self.quote, count: delimiter.quoteCount)
                + Array(repeating: Self.hash, count: delimiter.hashCount)
            return matches(closing, at: index)
        }

        private func matchesClosingDelimiter(_ delimiter: ExtendedRegexDelimiter, at index: Int) -> Bool {
            let closing = [Self.slash] + Array(repeating: Self.hash, count: delimiter.hashCount)
            return matches(closing, at: index)
        }

        private func escapedElementEnd(at index: Int, hashCount: Int, limit: Int) -> Int? {
            guard index < limit, bytes[index] == Self.backslash else { return nil }
            var cursor = index + 1
            for _ in 0..<hashCount {
                guard cursor < limit, bytes[cursor] == Self.hash else { return nil }
                cursor += 1
            }
            guard cursor < limit else { return nil }
            return cursor + 1
        }

        private func interpolationOpenParenthesis(at index: Int, hashCount: Int) -> Int? {
            guard index < bytes.count, bytes[index] == Self.backslash else { return nil }
            let openParenthesis = index + 1 + hashCount
            guard openParenthesis < bytes.count,
                  bytes[(index + 1)..<openParenthesis].allSatisfy({ $0 == Self.hash }),
                  bytes[openParenthesis] == Self.leftParenthesis else {
                return nil
            }
            return openParenthesis
        }

        private func commentEnd(startingAt index: Int) -> Int? {
            guard index + 1 < bytes.count, bytes[index] == Self.slash else { return nil }
            if bytes[index + 1] == Self.slash {
                var cursor = index + 2
                while cursor < bytes.count, bytes[cursor] != Self.newline { cursor += 1 }
                return cursor
            }
            guard bytes[index + 1] == Self.asterisk else { return nil }
            var cursor = index + 2
            var depth = 1
            while cursor + 1 < bytes.count {
                if bytes[cursor] == Self.slash, bytes[cursor + 1] == Self.asterisk {
                    depth += 1
                    cursor += 2
                } else if bytes[cursor] == Self.asterisk, bytes[cursor + 1] == Self.slash {
                    depth -= 1
                    cursor += 2
                    if depth == 0 { return cursor }
                } else {
                    cursor += 1
                }
            }
            return bytes.count
        }

        private func matches(_ expected: [UInt8], at index: Int) -> Bool {
            guard index + expected.count <= bytes.count else { return false }
            return bytes[index..<(index + expected.count)].elementsEqual(expected)
        }

        private static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || (0x09...0x0D).contains(byte)
        }

        private static func isIdentifierStart(_ byte: UInt8) -> Bool {
            byte == underscore || (lowercaseA...lowercaseZ).contains(byte) || (uppercaseA...uppercaseZ).contains(byte)
        }

        private static func isIdentifierContinuation(_ byte: UInt8) -> Bool {
            isIdentifierStart(byte) || (zero...nine).contains(byte)
        }

        private static let newline: UInt8 = 0x0A
        private static let quote: UInt8 = 0x22
        private static let hash: UInt8 = 0x23
        private static let leftParenthesis: UInt8 = 0x28
        private static let rightParenthesis: UInt8 = 0x29
        private static let asterisk: UInt8 = 0x2A
        private static let comma: UInt8 = 0x2C
        private static let dot: UInt8 = 0x2E
        private static let slash: UInt8 = 0x2F
        private static let zero: UInt8 = 0x30
        private static let nine: UInt8 = 0x39
        private static let colon: UInt8 = 0x3A
        private static let uppercaseA: UInt8 = 0x41
        private static let uppercaseZ: UInt8 = 0x5A
        private static let backslash: UInt8 = 0x5C
        private static let underscore: UInt8 = 0x5F
        private static let backtick: UInt8 = 0x60
        private static let lowercaseA: UInt8 = 0x61
        private static let lowercaseZ: UInt8 = 0x7A
        private static let leftBracket: UInt8 = 0x5B
        private static let rightBracket: UInt8 = 0x5D
        private static let leftBrace: UInt8 = 0x7B
        private static let rightBrace: UInt8 = 0x7D
    }

    private static func containsLegacyPublicFormat(in source: String) -> Bool {
        var searchStart = source.startIndex
        while let opening = source.range(of: "%{", range: searchStart..<source.endIndex) {
            guard let closing = source[opening.upperBound...].firstIndex(of: "}") else {
                return false
            }
            let qualifiers = source[opening.upperBound..<closing]
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if qualifiers.contains("public") {
                return true
            }
            searchStart = source.index(after: closing)
        }
        return false
    }
}
