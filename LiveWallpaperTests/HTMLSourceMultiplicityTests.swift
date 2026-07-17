import Testing
import Foundation
import LiveWallpaperCore
@testable import LiveWallpaper

@Suite("HTMLSource diagnostic signature")
struct HTMLSourceDiagnosticSignatureTests {

    @Test("Same URL produces identical signature")
    func sameURLEqualSignatures() {
        let a = HTMLSource.url(URL(string: "https://shadertoy.com/view/abc")!)
        let b = HTMLSource.url(URL(string: "https://shadertoy.com/view/abc")!)
        #expect(a.diagnosticSignature == b.diagnosticSignature)
    }

    @Test("Different URLs produce different signatures")
    func differentURLsDistinct() {
        let a = HTMLSource.url(URL(string: "https://a.com")!)
        let b = HTMLSource.url(URL(string: "https://b.com")!)
        #expect(a.diagnosticSignature != b.diagnosticSignature)
    }

    @Test("Folder source signature includes index file name")
    func folderSignatureIncludesIndex() {
        let bookmark = Data([0x01, 0x02])
        let withIndex = HTMLSource.folder(bookmarkData: bookmark, indexFileName: "index.html")
        let withOther = HTMLSource.folder(bookmarkData: bookmark, indexFileName: "main.html")
        #expect(withIndex.diagnosticSignature != withOther.diagnosticSignature)
    }

    @Test("File and folder with same bookmark are different")
    func fileVsFolderDistinct() {
        let bookmark = Data([0xFF])
        let f = HTMLSource.file(bookmarkData: bookmark)
        let d = HTMLSource.folder(bookmarkData: bookmark, indexFileName: "index.html")
        #expect(f.diagnosticSignature != d.diagnosticSignature)
    }

    @Test("Inline content signature is stable across instances of same string")
    func inlineSignatureStable() {
        let a = HTMLSource.inline("<h1>Hello</h1>")
        let b = HTMLSource.inline("<h1>Hello</h1>")
        #expect(a.diagnosticSignature == b.diagnosticSignature)
    }
}
