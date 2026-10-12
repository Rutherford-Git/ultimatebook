import XCTest
@testable import InkbookCore

final class GoodnotesFormatTests: XCTestCase {
    func testLZ4BlockWithOverlappingMatch() throws {
        // token 0x35: 3 literals "abc", match length 5+4=9 at distance 3 -> "abc" x4; then literals "XYZ".
        let block: [UInt8] = [0x35] + Array("abc".utf8) + [0x03, 0x00] + [0x30] + Array("XYZ".utf8)
        let framed = Data("bv41".utf8) + PB.le32(15) + PB.le32(UInt32(block.count)) + Data(block) + Data("bv4$".utf8)
        XCTAssertEqual(String(decoding: try AppleLZ4.decode(framed), as: UTF8.self), "abcabcabcabcXYZ")
    }

    func testLZ4RejectsCorruptInput() {
        let badOffset: [UInt8] = [0x15, 0x61, 0x09, 0x00]   // distance 9 > 1 byte produced
        let framed = Data("bv41".utf8) + PB.le32(10) + PB.le32(4) + Data(badOffset) + Data("bv4$".utf8)
        XCTAssertThrowsError(try AppleLZ4.decode(framed)) { XCTAssertEqual($0 as? AppleLZ4.Failure, .badOffset) }
        XCTAssertThrowsError(try AppleLZ4.decode(Data("nope".utf8)))
        XCTAssertThrowsError(try AppleLZ4.decode(Data("bv41".utf8) + PB.le32(5)))   // truncated header
    }

    func testTPLDecodesStrokeSignatureAndRejectsTrailingBytes() throws {
        let raw = PB.strokeTPL(width: 1.5, start: (10, 20), segments: [(11, 21, 12, 22)])
        let doc = try TPL.decode(raw)
        XCTAssertEqual(doc.signature, "vuA(v)A(S(uu))A(S(uuuu))vA(f)")
        XCTAssertEqual(doc.values[1].asFloat, 1.5)
        XCTAssertEqual(doc.values[2].items.compactMap(\.asInt), [0, 1])
        XCTAssertEqual(doc.values[4].items.first?.items.compactMap(\.asFloat), [11, 21, 12, 22])
        XCTAssertThrowsError(try TPL.decode(raw + Data([0])))
        XCTAssertThrowsError(try TPL.parseSignature("A(uu)"))
        XCTAssertThrowsError(try TPL.parseSignature("S(u"))
    }

    func testQuadraticPathsSplitSubpathsAndRejectMismatchedArrays() throws {
        let paths = try XCTUnwrap(GoodnotesImporter.quadraticPaths([0, 1, 0, 1], [0, 0, 100, 100], [5, 0, 10, 0, 105, 100, 110, 100]))
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths[0].first, Point(0, 0))
        XCTAssertEqual(paths[0].last, Point(10, 0))
        XCTAssertEqual(paths[1].first, Point(100, 100))
        XCTAssertNil(GoodnotesImporter.quadraticPaths([0, 1], [0, 0], []))        // missing segment
        XCTAssertNil(GoodnotesImporter.quadraticPaths([1], [], [1, 1, 2, 2]))       // quadTo before moveTo
    }

    func testNoteIDIsPageIDPlusOneWithCarry() {
        XCTAssertEqual(GoodnotesImporter.incrementUUID("5C327556-34E3-4BE5-B7A7-7C1115377EA0"),
                       "5C327556-34E3-4BE5-B7A7-7C1115377EA1")
        XCTAssertEqual(GoodnotesImporter.incrementUUID("5DD6F8C3-1C2F-4ACA-86F4-4717320000FF"),
                       "5DD6F8C3-1C2F-4ACA-86F4-471732000100")
        XCTAssertNil(GoodnotesImporter.incrementUUID("not-a-uuid"))
    }

    func testRecognizedTextGroupsWordsIntoLines() {
        func word(_ text: String, _ x: Float, _ y: Float) -> Data {
            PB.bytes(6, PB.bytes(1, PB.point(1, x, y) + PB.point(2, 40, 20)) + PB.string(3, text) + PB.string(3, "alt"))
        }
        let search = PB.string(5, "id") + word("world", 200, 101) + word("hello", 50, 100) + word("next", 50, 160)
        XCTAssertEqual(GoodnotesImporter.recognizedText(search), "hello world\nnext")
    }
}

final class GoodnotesImporterTests: XCTestCase {
    /// Builds a two-page notebook exercising every converted element kind.
    func makeSource() -> MemorySource {
        let pageA = "11111111-0000-0000-0000-00000000000F", noteA = "11111111-0000-0000-0000-000000000010"
        let pageB = "22222222-0000-0000-0000-000000000001", noteB = "22222222-0000-0000-0000-000000000002"
        func event(_ id: String, _ type: Int, _ body: Data) -> Data { PB.string(1, id) + PB.bytes(type, body) }
        let events = PB.delimited([
            event("doc", 30, PB.string(1, "doc") + PB.bytes(2, PB.string(1, "Physics 2"))),
            event("tmpl", 2, PB.string(2, "tmpl") + PB.point(8, 760, 1077) + PB.string(9, "pdfbg") + PB.uint(6, 3)),
            // Order keys deliberately reversed relative to file order.
            event(pageB, 54, PB.string(2, pageB) + PB.bytes(4, PB.string(1, "b"))),
            event(pageA, 54, PB.string(2, pageA) + PB.bytes(3, PB.string(1, "tmpl")) + PB.bytes(4, PB.string(1, "a"))),
        ])
        let header = PB.string(1, "elem") + PB.uint(8, 1) + PB.uint(9, 1)
        let stroke = PB.bytes(7, PB.string(1, "s1")
            + PB.bytes(2, PB.appleRaw(PB.strokeTPL(width: 2, start: (10, 10), segments: [(20, 10, 30, 10)])))
            + PB.bytes(4, PB.float(1, 1) + PB.float(4, 1))          // red, green/blue omitted = 0
            + PB.bytes(6, PB.float(1, 5) + PB.float(2, -5)))        // moved by lasso
        let highlighter = PB.bytes(7, PB.string(1, "s2")
            + PB.bytes(2, PB.appleRaw(PB.strokeTPL(width: 18, start: (0, 50), segments: [(50, 50, 100, 50)])))
            + PB.bytes(4, PB.float(2, 1) + PB.float(4, 0.5)))
        let image = PB.bytes(1, PB.string(1, "i1") + PB.string(4, "img1")
            + PB.bytes(3, PB.point(1, 100, 200) + PB.point(2, 50, 25)))
        let text = PB.bytes(21, PB.string(1, "t1") + PB.bytes(20, PB.point(1, 300, 400))
            + PB.bytes(32, PB.bytes(1, PB.bytes(2, PB.appleRaw(PB.bytes(1, PB.string(1, "What is E?") + PB.bytes(2, PB.string(30, "Komika Hand"))))))
                + PB.point(2, 200, 40) + PB.bytes(5, PB.bytes(1, PB.float(40, 24)))))
        let unknown = PB.bytes(20, PB.string(1, "x"))
        // Variable-width signature with every array empty: a geometry-less record.
        let emptySig = "vuA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)"
        var emptyBody = PB.le16(2) + PB.le32(Float(-1).bitPattern)
        for _ in 0..<10 { emptyBody += PB.le32(0) }
        let emptyTPL = Data("tpl\0".utf8) + PB.le32(UInt32(8 + emptySig.utf8.count + 1 + emptyBody.count))
            + Data(emptySig.utf8) + Data([0]) + emptyBody
        let empty = PB.bytes(7, PB.string(1, "e") + PB.bytes(2, PB.appleRaw(emptyTPL)) + PB.uint(3, 4))
        let notes = PB.delimited([header, stroke, header, highlighter, header, image, header, text, header, unknown, header, empty])
        let search = PB.string(5, "s") + PB.bytes(6, PB.bytes(1, PB.point(1, 0, 0) + PB.point(2, 10, 10)) + PB.string(3, "charge"))
        return MemorySource(files: [
            "index.events.pb": events,
            "notes/\(noteA)": notes, "notes/\(noteB)": Data(),
            "search/\(noteA)": search,
            "attachments/img1": Data([0x89, 0x50, 0x4E, 0x47, 1]),
            "attachments/pdfbg": Data("%PDF-1.7".utf8),
        ])
    }

    func testImportsPagesInOrderWithAllElementKinds() throws {
        let result = try GoodnotesImporter.importNotebook(from: makeSource(), title: "fallback")
        let nb = result.notebook
        XCTAssertEqual(nb.title, "Physics 2")
        XCTAssertEqual(nb.pages.count, 2)

        let a = nb.pages[0]
        XCTAssertEqual(a.size, Size(760, 1077))
        XCTAssertEqual(a.paper, .asset("pdfbg.pdf", pdfPage: 2))
        XCTAssertEqual(a.recognizedText, "charge")
        let els = a.layers[0].elements
        XCTAssertEqual(els.count, 4)

        guard case .stroke(let hl) = els[0], case .stroke(let pen) = els[1] else { return XCTFail("highlighter first") }
        XCTAssertEqual(hl.brush.kind, .highlighter)
        XCTAssertEqual(hl.brush.color, RGBA(0, 1, 0, 0.5))
        XCTAssertEqual(pen.brush.kind, .pen)
        XCTAssertEqual(pen.brush.color, RGBA(1, 0, 0, 1))
        XCTAssertEqual(pen.brush.size, 2)
        XCTAssertEqual(pen.points.first?.location, Point(15, 5))     // start + offset
        XCTAssertEqual(pen.points.last?.location, Point(35, 5))      // segment end + offset

        guard case .image(let img) = els[2], case .text(let t) = els[3] else { return XCTFail("image, text") }
        XCTAssertEqual(img.frame, Rect(x: 100, y: 200, width: 50, height: 25))
        XCTAssertEqual(img.asset, "img1.png")
        XCTAssertEqual(t.text, "What is E?")
        XCTAssertEqual(t.frame, Rect(x: 300, y: 400, width: 200, height: 40))
        XCTAssertEqual(t.fontSize, 24)

        XCTAssertEqual(nb.pages[1].layers[0].elements, [])
        XCTAssertEqual(nb.pages[1].size, .letter)
        XCTAssertEqual(Set(result.assets.keys), ["img1.png", "pdfbg.pdf"])
        XCTAssertEqual(result.report.strokes, 2)
        XCTAssertEqual(result.report.images, 1)
        XCTAssertEqual(result.report.textBoxes, 1)
        XCTAssertEqual(result.report.unsupported, ["kind 20": 1])
        XCTAssertEqual(result.report.emptyStrokes, 1)
    }

    func testMissingEventLogIsAnError() {
        XCTAssertThrowsError(try GoodnotesImporter.importNotebook(from: MemorySource(files: [:]), title: "x")) {
            XCTAssertEqual($0 as? GoodnotesImportError, .missingEntry("index.events.pb"))
        }
        XCTAssertThrowsError(try GoodnotesZipSource(url: URL(fileURLWithPath: "/nonexistent.goodnotes")))
    }

    /// Opt-in check against a real notebook: INKBOOK_GOODNOTES_SAMPLE=/path/file.goodnotes swift test
    func testRealGoodnotesFileWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["INKBOOK_GOODNOTES_SAMPLE"] else {
            throw XCTSkip("Set INKBOOK_GOODNOTES_SAMPLE to a .goodnotes file to run")
        }
        let result = try GoodnotesImporter.importFile(at: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(result.report.pages, 0)
        XCTAssertEqual(result.report.unsupported["undecodable stroke"], nil, "\(result.report)")
        print("Imported \(result.notebook.title): \(result.report)")
        if let out = ProcessInfo.processInfo.environment["INKBOOK_SVG_OUT"] {
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            for (i, page) in result.notebook.pages.enumerated() {
                let svg = PageSVG.render(page) { name in
                    result.assets[name].flatMap { d in PageSVG.mimeType(d).map { (d, $0) } }
                }
                try Data(svg.utf8).write(to: URL(fileURLWithPath: out).appendingPathComponent(String(format: "page%02d.svg", i + 1)))
            }
        }
    }
}
