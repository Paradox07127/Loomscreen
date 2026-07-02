import Foundation
import Testing
@testable import LiveWallpaperProWPE

/// Regression coverage for the CFBoolean pitfall in `WPEValueParser.double`/`.int`:
/// a JSON boolean bridges to a CFBoolean-backed `NSNumber`, so without the explicit
/// `strictBool` short-circuit it would parse as 0/1 even when the caller passed the
/// default `boolAsNumber: false` (which expects a bool to parse as nil). The same
/// pitfall was guarded locally in `WPEMetalSceneRenderer.overbright(fromConstants:)`.
@Suite("WPEValueParser boolean handling")
struct WPEValueParserBoolTests {

    /// Booleans exactly as JSONSerialization produces them (`__NSCFBoolean`), which is
    /// the path real scene data takes — the most faithful reproduction of the bug.
    private func jsonBool(_ value: Bool) -> Any {
        let json = "{\"v\": \(value)}".data(using: .utf8) ?? Data()
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let val = object["v"] else {
            fatalError("Failed to parse mock JSON bool")
        }
        return val
    }

    // MARK: - double

    @Test("double: JSON booleans parse as nil with the default flag")
    func doubleRejectsJSONBoolByDefault() {
        #expect(WPEValueParser.double(jsonBool(false)) == nil)
        #expect(WPEValueParser.double(jsonBool(true)) == nil)
    }

    @Test("double: Swift Bool literals parse as nil with the default flag")
    func doubleRejectsSwiftBoolByDefault() {
        #expect(WPEValueParser.double(false) == nil)
        #expect(WPEValueParser.double(true) == nil)
    }

    @Test("double: booleans parse as 1/0 when boolAsNumber is true")
    func doubleKeepsBoolAsNumber() {
        #expect(WPEValueParser.double(jsonBool(true), boolAsNumber: true) == 1)
        #expect(WPEValueParser.double(jsonBool(false), boolAsNumber: true) == 0)
        #expect(WPEValueParser.double(true, boolAsNumber: true) == 1)
        #expect(WPEValueParser.double(false, boolAsNumber: true) == 0)
    }

    @Test("double: genuine numbers and numeric strings still parse under both flags")
    func doublePreservesNumbers() {
        #expect(WPEValueParser.double(2.5) == 2.5)
        #expect(WPEValueParser.double(0) == 0)
        #expect(WPEValueParser.double(1) == 1)
        #expect(WPEValueParser.double(0, boolAsNumber: true) == 0)
        #expect(WPEValueParser.double(1, boolAsNumber: true) == 1)
        #expect(WPEValueParser.double("3.5") == 3.5)
        // Numbers decoded from JSON (NSNumber-backed) are unaffected by the bool guard.
        #expect(WPEValueParser.double(jsonNumber("0")) == 0)
        #expect(WPEValueParser.double(jsonNumber("42")) == 42)
    }

    // MARK: - int

    @Test("int: JSON booleans parse as nil with the default flag")
    func intRejectsJSONBoolByDefault() {
        #expect(WPEValueParser.int(jsonBool(false)) == nil)
        #expect(WPEValueParser.int(jsonBool(true)) == nil)
    }

    @Test("int: booleans parse as 1/0 when boolAsNumber is true; numbers preserved")
    func intKeepsBoolAsNumberAndNumbers() {
        #expect(WPEValueParser.int(true, boolAsNumber: true) == 1)
        #expect(WPEValueParser.int(false, boolAsNumber: true) == 0)
        #expect(WPEValueParser.int(0) == 0)
        #expect(WPEValueParser.int(7) == 7)
        #expect(WPEValueParser.int(jsonNumber("0")) == 0)
    }

    private func jsonNumber(_ literal: String) -> Any {
        let json = "{\"v\": \(literal)}".data(using: .utf8) ?? Data()
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let val = object["v"] else {
            fatalError("Failed to parse mock JSON number")
        }
        return val
    }
}
