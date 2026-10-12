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
        let unknown = PB.bytes(99, PB.string(1, "x"))
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
        XCTAssertEqual(result.report.unsupported, ["kind 99": 1])
        XCTAssertEqual(result.report.emptyStrokes, 1)
    }

    /// Kinds 20 (sticky note), 22 (line shape, both geometry forms) and an outlined stroke.
    func testImportsStickyNotesLineShapesAndOutlinedStrokes() throws {
        let page = "33333333-0000-0000-0000-000000000001", note = "33333333-0000-0000-0000-000000000002"
        let events = PB.delimited([PB.string(1, page) + PB.bytes(54, PB.string(2, page) + PB.bytes(4, PB.string(1, "a")))])
        let header = PB.string(1, "h") + PB.uint(8, 1) + PB.uint(9, 1)
        let style = PB.bytes(32, PB.float(1, 2) + PB.bytes(2, PB.bytes(2, PB.float(1, 3) + PB.float(2, 4)))
            + PB.bytes(3, PB.bytes(1, PB.float(3, 1) + PB.float(4, 1))))
        let polyline = PB.bytes(22, PB.bytes(20, PB.bytes(1, PB.point(1, 0, 0)) + PB.point(2, 5, 5)
            + PB.point(2, 10, 0) + PB.bytes(3, PB.point(1, 20, 0))) + style)
        let straight = PB.bytes(22, PB.bytes(21, PB.bytes(1, PB.point(1, 0, 100)) + PB.bytes(3, PB.point(1, 40, 100))
            + PB.bytes(5, PB.point(2, 20, 100))) + style)
        let sticky = PB.bytes(20, PB.bytes(20, PB.point(1, 600, 40)) + PB.bytes(21, PB.point(2, 256, 200))
            + PB.bytes(30, PB.float(1, 0.9) + PB.float(2, 0.9) + PB.float(3, 0.8) + PB.float(4, 1))
            + PB.bytes(31, PB.bytes(1, PB.bytes(2, PB.appleRaw(PB.bytes(1, PB.string(1, "Ask about Gauss")))))))

        // Variable-width signature, table A: codes 2 = moveTo (starts), 4 = cubic (6 floats).
        let sig = "vuA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)"
        func words(_ v: [UInt32]) -> Data { PB.le32(UInt32(v.count)) + v.reduce(Data()) { $0 + PB.le32($1) } }
        func floats(_ v: [Float]) -> Data { words(v.map(\.bitPattern)) }
        func shorts(_ v: [UInt16]) -> Data { PB.le32(UInt32(v.count)) + v.reduce(Data()) { $0 + PB.le16($1) } }
        var body = PB.le16(2) + PB.le32(Float(-1).bitPattern)
        body += shorts([2, 3]) + floats([]) + floats([]) + shorts([2]) + shorts([2, 4, 4])
        body += floats([10, 10]) + floats([]) + floats([12, 8, 14, 8, 16, 10, 14, 12, 12, 12, 10, 10]) + floats([]) + shorts([])
        let tpl = Data("tpl\0".utf8) + PB.le32(UInt32(8 + sig.utf8.count + 1 + body.count)) + Data(sig.utf8) + Data([0]) + body
        let outlined = PB.bytes(7, PB.string(1, "o") + PB.bytes(2, PB.appleRaw(tpl))
            + PB.bytes(4, PB.float(3, 1) + PB.float(4, 1)) + PB.bytes(6, PB.float(1, 100)))

        let notes = PB.delimited([header, polyline, header, straight, header, sticky, header, outlined])
        let result = try GoodnotesImporter.importNotebook(
            from: MemorySource(files: ["index.events.pb": events, "notes/\(note)": notes]), title: "t")
        let els = result.notebook.pages[0].layers[0].elements
        XCTAssertEqual(result.report.lines, 2)
        XCTAssertEqual(result.report.stickyNotes, 1)
        XCTAssertEqual(result.report.outlinedStrokes, 1)
        XCTAssertEqual(result.report.unsupported, [:])

        guard case .stroke(let poly) = els[0], case .stroke(let line) = els[1], case .text(let note) = els[2],
              case .shape(let shape) = els[3] else { return XCTFail("\(els)") }
        XCTAssertEqual(poly.points.map(\.location), [Point(0, 0), Point(5, 5), Point(10, 0), Point(20, 0)])
        XCTAssertEqual(poly.brush.dash, [3, 4])
        XCTAssertEqual(poly.brush.size, 2)
        XCTAssertEqual(poly.brush.color, RGBA(0, 0, 1, 1))
        XCTAssertEqual(line.points.first?.location, Point(0, 100))
        XCTAssertEqual(line.points.last?.location, Point(40, 100))
        XCTAssertTrue(line.points.allSatisfy { abs($0.location.y - 100) < 1e-9 })   // midpoint on chord: straight
        XCTAssertEqual(note.text, "Ask about Gauss")
        XCTAssertEqual(note.frame, Rect(x: 600, y: 40, width: 256, height: 200))
        XCTAssertNotNil(note.background)
        XCTAssertEqual(shape.color, RGBA(0, 0, 1, 1))
        XCTAssertEqual(shape.path.first, .move(Point(110, 10)))   // offset applied
        XCTAssertEqual(shape.path.filter { if case .cubic = $0 { return true }; return false }.count, 2)
        XCTAssertEqual(shape.path.last, .close)
    }

    func testOutlineCodesMustAccountForEveryCoordinate() {
        // Table B: 0 = move, 2 = cubic, 6 = close.
        let b = GoodnotesImporter.outlinePath(codes: [0, 2, 6], starts: [1, 1], cubics: [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(b, [.move(Point(1, 1)), .cubic(control1: Point(1, 2), control2: Point(3, 4), to: Point(5, 6)), .close])
        XCTAssertNil(GoodnotesImporter.outlinePath(codes: [2, 4, 4], starts: [1, 1], cubics: [1, 2, 3, 4, 5, 6]))  // one cubic short
        XCTAssertNil(GoodnotesImporter.outlinePath(codes: [2, 9], starts: [1, 1], cubics: []))                     // unknown code
        XCTAssertNil(GoodnotesImporter.outlinePath(codes: [], starts: [], cubics: []))
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
