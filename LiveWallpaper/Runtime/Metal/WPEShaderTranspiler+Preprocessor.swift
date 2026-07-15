#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

extension WPEShaderTranspiler {
    // MARK: - Preprocessor conditionals

    private struct ConditionalFrame {
        let parentActive: Bool
        var active: Bool
        var branchTaken: Bool
    }

    /// Exposed for the vertex-uniform merge: a uniform declared only inside an
    /// INACTIVE `#if` branch of the fragment must not count as "already
    /// declared", or the merge skips it and the strip then removes it entirely
    /// (auto_sway declares g_Speed/g_Inertia only under `AA_VERSION == 1`).
    static func sourceWithInactiveBranchesStripped(_ source: String) -> String {
        stripInactivePreprocessorBranches(in: source)
    }

    static func stripInactivePreprocessorBranches(in source: String) -> String {
        var macroValues: [String: Int] = [:]
        var definedMacros: Set<String> = []
        var frames: [ConditionalFrame] = []
        var output: [String] = []

        // Detect directives on a comment-masked copy so a `#if`/`#endif` sitting on
        // its own line inside a `/* … */` block (or after `//`) isn't read as a live
        // directive — that would push/pop conditional frames and silently drop real
        // code. The mask is length-preserving, so masked and raw lines align 1:1;
        // directives are parsed from the masked line but the raw line is emitted.
        let rawLines = source.components(separatedBy: "\n")
        let maskedLines = maskComments(source).components(separatedBy: "\n")

        for (line, maskedLine) in zip(rawLines, maskedLines) {
            guard let directive = preprocessorDirective(in: maskedLine) else {
                if preprocessorIsActive(frames) {
                    output.append(line)
                }
                continue
            }

            switch directive.keyword {
            case "if":
                let parentActive = preprocessorIsActive(frames)
                let value = evaluatePreprocessorExpression(
                    directive.expression,
                    values: macroValues,
                    definedMacros: definedMacros
                )
                let active = parentActive && value != 0
                frames.append(ConditionalFrame(
                    parentActive: parentActive,
                    active: active,
                    branchTaken: active
                ))
            case "ifdef":
                let parentActive = preprocessorIsActive(frames)
                let name = directive.expression.trimmingCharacters(in: .whitespaces)
                let active = parentActive && definedMacros.contains(name)
                frames.append(ConditionalFrame(
                    parentActive: parentActive,
                    active: active,
                    branchTaken: active
                ))
            case "ifndef":
                let parentActive = preprocessorIsActive(frames)
                let name = directive.expression.trimmingCharacters(in: .whitespaces)
                let active = parentActive && !definedMacros.contains(name)
                frames.append(ConditionalFrame(
                    parentActive: parentActive,
                    active: active,
                    branchTaken: active
                ))
            case "elif":
                guard !frames.isEmpty else { continue }
                var frame = frames.removeLast()
                if frame.parentActive && !frame.branchTaken {
                    let value = evaluatePreprocessorExpression(
                        directive.expression,
                        values: macroValues,
                        definedMacros: definedMacros
                    )
                    frame.active = value != 0
                    frame.branchTaken = frame.active
                } else {
                    frame.active = false
                }
                frames.append(frame)
            case "else":
                guard !frames.isEmpty else { continue }
                var frame = frames.removeLast()
                frame.active = frame.parentActive && !frame.branchTaken
                frame.branchTaken = true
                frames.append(frame)
            case "endif":
                if !frames.isEmpty {
                    frames.removeLast()
                }
            case "define":
                guard preprocessorIsActive(frames) else { continue }
                if let definition = parsePreprocessorDefine(directive.expression, values: macroValues, definedMacros: definedMacros) {
                    definedMacros.insert(definition.name)
                    if let value = definition.value {
                        macroValues[definition.name] = value
                    } else {
                        macroValues.removeValue(forKey: definition.name)
                    }
                }
                output.append(line)
            case "undef":
                guard preprocessorIsActive(frames) else { continue }
                let name = directive.expression.trimmingCharacters(in: .whitespaces)
                definedMacros.remove(name)
                macroValues.removeValue(forKey: name)
            default:
                if preprocessorIsActive(frames) {
                    output.append(line)
                }
            }
        }

        return output.joined(separator: "\n")
    }

    private static func preprocessorIsActive(_ frames: [ConditionalFrame]) -> Bool {
        frames.allSatisfy(\.active)
    }

    private static func preprocessorDirective(in line: String) -> (keyword: String, expression: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let body = trimmed.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        let keyword = body.prefix(while: { $0.isLetter })
        guard !keyword.isEmpty else { return nil }
        let expressionStart = body.index(body.startIndex, offsetBy: keyword.count)
        let expression = body[expressionStart...].trimmingCharacters(in: .whitespaces)
        return (String(keyword), expression)
    }

    private static func parsePreprocessorDefine(
        _ expression: String,
        values: [String: Int],
        definedMacros: Set<String>
    ) -> (name: String, value: Int?)? {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, isIdentifierStart(first) else { return nil }
        var nameEnd = trimmed.index(after: trimmed.startIndex)
        while nameEnd < trimmed.endIndex, isIdentifierCharacter(trimmed[nameEnd]) {
            nameEnd = trimmed.index(after: nameEnd)
        }
        let name = String(trimmed[..<nameEnd])
        if nameEnd < trimmed.endIndex, trimmed[nameEnd] == "(" {
            return (name, nil)
        }

        let rawValue = String(trimmed[nameEnd...])
            .components(separatedBy: "//")
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !rawValue.isEmpty else {
            return (name, 1)
        }

        guard let value = parsePreprocessorExpression(rawValue, values: values, definedMacros: definedMacros) else {
            return (name, nil)
        }
        return (name, value)
    }

    private static func evaluatePreprocessorExpression(
        _ expression: String,
        values: [String: Int],
        definedMacros: Set<String>
    ) -> Int {
        let sanitized = sanitizeConditionalExpression(expression)
        return parsePreprocessorExpression(sanitized, values: values, definedMacros: definedMacros) ?? 0
    }

    /// WPE's preprocessor tolerates trailing junk in `#if` / `#elif` conditions — workshop shaders
    /// ship lines like `#elif AUDIOSAMPLES == 32;` (stray `;`) or `#if COND // note`. A `;`, `//`,
    /// or `/*` can never appear inside a valid conditional expression, so truncate at the first one;
    /// otherwise the strict tokenizer rejects the whole condition and the (often default) branch is
    /// silently dropped, leaving its declarations undefined in the emitted MSL.
    private static func sanitizeConditionalExpression(_ expression: String) -> String {
        var cutoff = expression.endIndex
        for marker in ["//", "/*", ";"] {
            if let range = expression.range(of: marker), range.lowerBound < cutoff {
                cutoff = range.lowerBound
            }
        }
        return String(expression[..<cutoff]).trimmingCharacters(in: .whitespaces)
    }

    private static func parsePreprocessorExpression(
        _ expression: String,
        values: [String: Int],
        definedMacros: Set<String>
    ) -> Int? {
        guard let tokens = PreprocessorExpressionParser.tokenize(expression) else {
            return nil
        }
        var parser = PreprocessorExpressionParser(tokens: tokens, values: values, definedMacros: definedMacros)
        return parser.parse()
    }

    private enum PreprocessorToken: Equatable {
        case number(Int)
        case identifier(String)
        case op(String)
        case lParen
        case rParen
        case end
    }

    private struct PreprocessorExpressionParser {
        let tokens: [PreprocessorToken]
        let values: [String: Int]
        let definedMacros: Set<String>
        var index = 0

        init(tokens: [PreprocessorToken], values: [String: Int], definedMacros: Set<String>) {
            self.tokens = tokens
            self.values = values
            self.definedMacros = definedMacros
        }

        mutating func parse() -> Int? {
            guard let value = parseOr(), peek == .end else {
                return nil
            }
            return value
        }

        private var peek: PreprocessorToken {
            tokens.indices.contains(index) ? tokens[index] : .end
        }

        private mutating func advance() -> PreprocessorToken {
            let token = peek
            index += 1
            return token
        }

        private mutating func matchOperator(_ op: String) -> Bool {
            if peek == .op(op) {
                _ = advance()
                return true
            }
            return false
        }

        private mutating func parseOr() -> Int? {
            guard var lhs = parseAnd() else { return nil }
            while matchOperator("||") {
                guard let rhs = parseAnd() else { return nil }
                lhs = lhs != 0 || rhs != 0 ? 1 : 0
            }
            return lhs
        }

        private mutating func parseAnd() -> Int? {
            guard var lhs = parseBitOr() else { return nil }
            while matchOperator("&&") {
                guard let rhs = parseBitOr() else { return nil }
                lhs = lhs != 0 && rhs != 0 ? 1 : 0
            }
            return lhs
        }

        private mutating func parseBitOr() -> Int? {
            guard var lhs = parseBitXor() else { return nil }
            while matchOperator("|") {
                guard let rhs = parseBitXor() else { return nil }
                lhs |= rhs
            }
            return lhs
        }

        private mutating func parseBitXor() -> Int? {
            guard var lhs = parseBitAnd() else { return nil }
            while matchOperator("^") {
                guard let rhs = parseBitAnd() else { return nil }
                lhs ^= rhs
            }
            return lhs
        }

        private mutating func parseBitAnd() -> Int? {
            guard var lhs = parseEquality() else { return nil }
            while matchOperator("&") {
                guard let rhs = parseEquality() else { return nil }
                lhs &= rhs
            }
            return lhs
        }

        private mutating func parseEquality() -> Int? {
            guard var lhs = parseRelational() else { return nil }
            while true {
                if matchOperator("==") {
                    guard let rhs = parseRelational() else { return nil }
                    lhs = lhs == rhs ? 1 : 0
                } else if matchOperator("!=") {
                    guard let rhs = parseRelational() else { return nil }
                    lhs = lhs != rhs ? 1 : 0
                } else {
                    return lhs
                }
            }
        }

        private mutating func parseRelational() -> Int? {
            guard var lhs = parseShift() else { return nil }
            while true {
                if matchOperator(">=") {
                    guard let rhs = parseShift() else { return nil }
                    lhs = lhs >= rhs ? 1 : 0
                } else if matchOperator("<=") {
                    guard let rhs = parseShift() else { return nil }
                    lhs = lhs <= rhs ? 1 : 0
                } else if matchOperator(">") {
                    guard let rhs = parseShift() else { return nil }
                    lhs = lhs > rhs ? 1 : 0
                } else if matchOperator("<") {
                    guard let rhs = parseShift() else { return nil }
                    lhs = lhs < rhs ? 1 : 0
                } else {
                    return lhs
                }
            }
        }

        private mutating func parseShift() -> Int? {
            // `<<`/`>>` on Int are masking shifts (never trap), so no overflow guard
            // needed; a nonsensical shift count just yields 0 or the sign fill.
            guard var lhs = parseAdditive() else { return nil }
            while true {
                if matchOperator("<<") {
                    guard let rhs = parseAdditive() else { return nil }
                    lhs <<= rhs
                } else if matchOperator(">>") {
                    guard let rhs = parseAdditive() else { return nil }
                    lhs >>= rhs
                } else {
                    return lhs
                }
            }
        }

        private mutating func parseAdditive() -> Int? {
            guard var lhs = parseMultiplicative() else { return nil }
            while true {
                if matchOperator("+") {
                    guard let rhs = parseMultiplicative() else { return nil }
                    let (result, overflow) = lhs.addingReportingOverflow(rhs)
                    guard !overflow else { return nil }
                    lhs = result
                } else if matchOperator("-") {
                    guard let rhs = parseMultiplicative() else { return nil }
                    let (result, overflow) = lhs.subtractingReportingOverflow(rhs)
                    guard !overflow else { return nil }
                    lhs = result
                } else {
                    return lhs
                }
            }
        }

        // Overflow/divide-by-zero fall back to nil so the whole `#if` is treated as
        // unparseable (→ false), the same safe default as any other malformed
        // condition — never a runtime trap on pathological shader input.
        private mutating func parseMultiplicative() -> Int? {
            guard var lhs = parseUnary() else { return nil }
            while true {
                if matchOperator("*") {
                    guard let rhs = parseUnary() else { return nil }
                    let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
                    guard !overflow else { return nil }
                    lhs = result
                } else if matchOperator("/") {
                    guard let rhs = parseUnary(), rhs != 0 else { return nil }
                    let (result, overflow) = lhs.dividedReportingOverflow(by: rhs)
                    guard !overflow else { return nil }
                    lhs = result
                } else if matchOperator("%") {
                    guard let rhs = parseUnary(), rhs != 0 else { return nil }
                    let (result, overflow) = lhs.remainderReportingOverflow(dividingBy: rhs)
                    guard !overflow else { return nil }
                    lhs = result
                } else {
                    return lhs
                }
            }
        }

        private mutating func parseUnary() -> Int? {
            if matchOperator("!") {
                guard let value = parseUnary() else { return nil }
                return value == 0 ? 1 : 0
            }
            if matchOperator("~") {
                guard let value = parseUnary() else { return nil }
                return ~value
            }
            if matchOperator("-") {
                guard let value = parseUnary() else { return nil }
                let (result, overflow) = Int(0).subtractingReportingOverflow(value)
                guard !overflow else { return nil }
                return result
            }
            if matchOperator("+") {
                return parseUnary()
            }
            return parsePrimary()
        }

        private mutating func parsePrimary() -> Int? {
            switch advance() {
            case .number(let value):
                return value
            case .identifier("defined"):
                return parseDefinedOperator()
            case .identifier(let name):
                return values[name] ?? 0
            case .lParen:
                guard let value = parseOr(), peek == .rParen else { return nil }
                _ = advance()
                return value
            default:
                return nil
            }
        }

        private mutating func parseDefinedOperator() -> Int? {
            if peek == .lParen {
                _ = advance()
                guard case .identifier(let name) = advance(), peek == .rParen else {
                    return nil
                }
                _ = advance()
                return definedMacros.contains(name) ? 1 : 0
            }
            guard case .identifier(let name) = advance() else {
                return nil
            }
            return definedMacros.contains(name) ? 1 : 0
        }

        static func tokenize(_ expression: String) -> [PreprocessorToken]? {
            var tokens: [PreprocessorToken] = []
            var index = expression.startIndex

            while index < expression.endIndex {
                let ch = expression[index]
                if ch.isWhitespace {
                    index = expression.index(after: index)
                    continue
                }
                if ch == "/" {
                    let next = expression.index(after: index)
                    if next < expression.endIndex, expression[next] == "/" {
                        break
                    }
                    tokens.append(.op("/"))
                    index = next
                    continue
                }
                if ch.isNumber {
                    var end = expression.index(after: index)
                    if ch == "0", end < expression.endIndex, expression[end] == "x" || expression[end] == "X" {
                        end = expression.index(after: end)
                        let digitsStart = end
                        while end < expression.endIndex, expression[end].isHexDigit {
                            end = expression.index(after: end)
                        }
                        guard digitsStart < end,
                              let value = Int(expression[digitsStart..<end], radix: 16) else {
                            return nil
                        }
                        tokens.append(.number(value))
                        index = end
                        continue
                    }
                    while end < expression.endIndex, expression[end].isNumber {
                        end = expression.index(after: end)
                    }
                    guard let value = Int(expression[index..<end]) else {
                        return nil
                    }
                    tokens.append(.number(value))
                    index = end
                    continue
                }
                if isIdentifierStart(ch) {
                    var end = expression.index(after: index)
                    while end < expression.endIndex, isIdentifierCharacter(expression[end]) {
                        end = expression.index(after: end)
                    }
                    tokens.append(.identifier(String(expression[index..<end])))
                    index = end
                    continue
                }
                let next = expression.index(after: index)
                if next < expression.endIndex {
                    let two = String(expression[index...next])
                    if ["&&", "||", "==", "!=", ">=", "<=", "<<", ">>"].contains(two) {
                        tokens.append(.op(two))
                        index = expression.index(after: next)
                        continue
                    }
                }
                switch ch {
                case "(":
                    tokens.append(.lParen)
                case ")":
                    tokens.append(.rParen)
                case "!", ">", "<", "+", "-", "*", "%", "&", "|", "^", "~":
                    tokens.append(.op(String(ch)))
                default:
                    return nil
                }
                index = expression.index(after: index)
            }

            tokens.append(.end)
            return tokens
        }
    }

}
#endif
