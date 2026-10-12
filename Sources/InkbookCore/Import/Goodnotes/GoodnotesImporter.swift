import Foundation
import ZIPFoundation

/// What the importer converted or could not convert. Nothing is dropped silently.
public struct ImportReport: Equatable, Sendable {
    public var pages = 0
    public var strokes = 0
    /// Variable-width (fountain pen) strokes, imported as their exact filled outline.
    public var outlinedStrokes = 0
    /// Shape-tool lines (dashed connectors), imported as strokes.
    public var lines = 0
    public var stickyNotes = 0
    /// Stroke records that carry no geometry (seen with header kind 4); nothing to draw.
    public var emptyStrokes = 0
    /// Text boxes with styling but no text.
    public var emptyTextBoxes = 0
    public var images = 0
    public var textBoxes = 0
    /// Element kinds present in the file but not converted, with counts (e.g. "kind 20": 3).
    public var unsupported: [String: Int] = [:]
    public var warnings: [String] = []
}

public struct GoodnotesImport: Sendable {
    public var notebook: Notebook
    /// Files to store under the notebook's `assets/` directory, keyed by asset name.
    public var assets: [String: Data]
    public var report: ImportReport
}

public enum GoodnotesImportError: Error, Equatable, CustomStringConvertible {
    case notAGoodnotesFile(String)
    case missingEntry(String)

    public var description: String {
        switch self {
        case .notAGoodnotesFile(let why): "Not a Goodnotes notebook: \(why)"
        case .missingEntry(let path): "Goodnotes file is missing \(path)"
        }
    }
}

/// Read access to the files inside a `.goodnotes` archive (a ZIP), abstracted for tests.
public protocol GoodnotesSource {
    func data(at path: String) -> Data?
}

/// `.goodnotes` ZIP archive reader.
public struct GoodnotesZipSource: GoodnotesSource {
    private let archive: Archive

    public init(url: URL) throws {
        do { archive = try Archive(url: url, accessMode: .read) } catch {
            throw GoodnotesImportError.notAGoodnotesFile("not a ZIP archive (\(error))")
        }
    }

    public func data(at path: String) -> Data? {
        guard let entry = archive[path] else { return nil }
        var out = Data()
        do { _ = try archive.extract(entry, skipCRC32: false) { out.append($0) } } catch { return nil }
        return out
    }
}

/// Converts a Goodnotes 6 (`schema.pb` = 35) notebook into an Inkbook `Notebook`.
/// Field numbers are documented in docs/GOODNOTES_FORMAT.md; they were reverse-engineered
/// from real files, so anything not understood is counted in the report.
public enum GoodnotesImporter {
    public static func importFile(at url: URL, title: String? = nil) throws -> GoodnotesImport {
        let name = title ?? url.deletingPathExtension().lastPathComponent
        return try importNotebook(from: GoodnotesZipSource(url: url), title: name)
    }

    public static func importNotebook(from source: GoodnotesSource, title fallbackTitle: String) throws -> GoodnotesImport {
        guard let events = source.data(at: "index.events.pb") else {
            throw GoodnotesImportError.missingEntry("index.events.pb")
        }
        var report = ImportReport()
        var assets: [String: Data] = [:]

        // 1. Entities from the event log (first record per id wins; later duplicates are history).
        var title = fallbackTitle
        var templates: [String: ProtoMessage] = [:]
        var pageRecords: [(id: String, order: String, template: String?)] = []
        var seenPages = Set<String>()
        for raw in ProtoMessage.delimitedStream(events) {
            guard let record = ProtoMessage(raw), let entity = record.string(1),
                  let typeField = record.fields.dropFirst().first, case .bytes(let body) = typeField.value,
                  let msg = ProtoMessage(body) else { continue }
            switch typeField.number {
            case 30:
                if let t = msg.message(2)?.string(1), !t.isEmpty { title = t }
            case 2:
                templates[msg.string(2) ?? entity] = msg
            case 54:
                guard seenPages.insert(entity).inserted else { continue }
                pageRecords.append((entity, msg.message(4)?.string(1) ?? "", msg.message(3)?.string(1)))
            default:
                break
            }
        }
        // Pages are ordered by a fractional-index key compared bytewise.
        pageRecords.sort { Array($0.order.utf8).lexicographicallyPrecedes(Array($1.order.utf8)) }

        // 2. Pages.
        var pages: [Page] = []
        for record in pageRecords {
            let template = record.template.flatMap { templates[$0] }
            var page = Page(size: pageSize(template), paper: paper(template, source: source, assets: &assets))
            guard let noteID = incrementUUID(record.id) else {
                report.warnings.append("Page \(record.id) has a malformed id; imported blank")
                pages.append(page); continue
            }
            if let ink = source.data(at: "notes/\(noteID)"), !ink.isEmpty {
                page.layers[0].elements = convertElements(ink, source: source, assets: &assets, report: &report)
            }
            if let search = source.data(at: "search/\(noteID)") {
                let text = recognizedText(search)
                page.recognizedText = text.isEmpty ? nil : text
            }
            pages.append(page)
        }
        report.pages = pages.count
        if pages.isEmpty { pages = [Page()]; report.warnings.append("No pages found; created one blank page") }
        return GoodnotesImport(notebook: Notebook(title: title, pages: pages), assets: assets, report: report)
    }

    // MARK: Page helpers

    static func pageSize(_ template: ProtoMessage?) -> Size {
        guard let size = template?.message(8), let w = size.float(1), let h = size.float(2), w > 0, h > 0 else {
            return .letter
        }
        return Size(w, h)
    }

    static func paper(_ template: ProtoMessage?, source: GoodnotesSource, assets: inout [String: Data]) -> Paper {
        guard let background = template?.string(9), !background.isEmpty,
              let data = source.data(at: "attachments/\(background)") else { return .blank(.white) }
        let isPDF = data.starts(with: Data("%PDF".utf8))
        let name = background + (isPDF ? ".pdf" : imageExtension(data))
        assets[name] = data
        // Field 6 looks like a 1-based PDF page number (inferred from one sample).
        let pdfPage = isPDF ? max(0, Int(template?.uint(6) ?? 1) - 1) : nil
        return .asset(name, pdfPage: pdfPage)
    }

    /// Goodnotes stores a page's ink in `notes/<pageId + 1>` (UUID as a 128-bit integer).
    static func incrementUUID(_ string: String) -> String? {
        guard let uuid = UUID(uuidString: string) else { return nil }
        var bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        for i in stride(from: 15, through: 0, by: -1) {
            bytes[i] &+= 1
            if bytes[i] != 0 { break }
        }
        let t = bytes
        return UUID(uuid: (t[0], t[1], t[2], t[3], t[4], t[5], t[6], t[7],
                           t[8], t[9], t[10], t[11], t[12], t[13], t[14], t[15])).uuidString
    }

    static func imageExtension(_ data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ".png" }
        if data.starts(with: [0xFF, 0xD8]) { return ".jpg" }
        return ""
    }

    // MARK: Elements

    /// `notes/<id>` is a stream of (header, body) messages; the body's single field number
    /// is the element kind: 7 stroke, 1 image, 21 text box, 20 sticky note, 22 line shape.
    static func convertElements(_ data: Data, source: GoodnotesSource,
                                assets: inout [String: Data], report: inout ImportReport) -> [Element] {
        var elements: [Element] = []
        for raw in ProtoMessage.delimitedStream(data) {
            guard let msg = ProtoMessage(raw), msg.fields.count == 1, let field = msg.fields.first,
                  case .bytes(let bodyData) = field.value, let body = ProtoMessage(bodyData) else {
                continue   // headers have several fields
            }
            switch field.number {
            case 7:
                switch stroke(body) {
                case .exact(let paths): elements += paths.map(Element.stroke); report.strokes += 1
                case .outline(let shape): elements.append(.shape(shape)); report.strokes += 1; report.outlinedStrokes += 1
                case .empty: report.emptyStrokes += 1
                case .failed: report.unsupported["undecodable stroke", default: 0] += 1
                }
            case 1:
                if let image = image(body, source: source, assets: &assets) {
                    elements.append(.image(image)); report.images += 1
                } else {
                    report.unsupported["image without attachment", default: 0] += 1
                }
            case 21:
                switch textBox(body) {
                case .some(let t) where t.text.isEmpty: report.emptyTextBoxes += 1
                case .some(let t): elements.append(.text(t)); report.textBoxes += 1
                case .none: report.unsupported["text box", default: 0] += 1
                }
            case 20:
                if let note = stickyNote(body) { elements.append(.text(note)); report.stickyNotes += 1 }
                else { report.unsupported["sticky note", default: 0] += 1 }
            case 22:
                if let line = shapeLine(body) { elements.append(.stroke(line)); report.lines += 1 }
                else { report.unsupported["line shape", default: 0] += 1 }
            default:
                report.unsupported["kind \(field.number)", default: 0] += 1
            }
        }
        // Highlighters render below ink, as in Goodnotes.
        return elements.filter(isHighlighter) + elements.filter { !isHighlighter($0) }
    }

    private static func isHighlighter(_ e: Element) -> Bool {
        if case .stroke(let s) = e { return s.brush.kind == .highlighter }
        return false
    }

    enum StrokeResult { case exact([Stroke]), outline(FilledShape), empty, failed }

    static func stroke(_ body: ProtoMessage) -> StrokeResult {
        guard let blob = body.bytes(2), let raw = try? AppleLZ4.decode(blob),
              let doc = try? TPL.decode(raw) else { return .failed }
        let color = rgba(body.message(4))
        let offset = Point(body.message(6)?.float(1) ?? 0, body.message(6)?.float(2) ?? 0)
        let kind: BrushKind = color.a < 0.99 ? .highlighter : .pen
        let v = doc.values

        // Uniform-width pen: [version, width, commands, moveTo points, quadratic segments, ...].
        if doc.signature.hasPrefix("vuA(v)A(S(uu))A(S(uuuu))"), v.count >= 5, let width = v[1].asFloat {
            let starts = v[3].items.flatMap { $0.items.compactMap(\.asFloat) }
            let segments = v[4].items.flatMap { $0.items.compactMap(\.asFloat) }
            guard let paths = quadraticPaths(v[2].items.compactMap(\.asInt), starts, segments) else { return .failed }
            let brush = Brush(kind: kind, color: color, size: max(0.3, width), minSizeRatio: 1)
            return .exact(paths.map { Stroke(brush: brush, points: $0.map { InkPoint($0 + offset) }) })
        }

        guard doc.signature.hasSuffix("A(u)A(u)A(u)A(u)A(v)"), v.count >= 11 else { return .failed }
        if v.allSatisfy({ $0.items.isEmpty }) { return .empty }
        let base = v.count - 10   // index of the first array (signature may start "vu" or "v")
        let commands = v[base].items.compactMap(\.asInt)

        // Same path model with flat arrays: commands 0/1, (x, y) starts, (cx, cy, x, y) segments.
        if !commands.isEmpty, commands.allSatisfy({ $0 <= 1 }) {
            guard let paths = quadraticPaths(commands, v[base + 1].items.compactMap(\.asFloat),
                                             v[base + 2].items.compactMap(\.asFloat)) else { return .failed }
            let width = base == 2 ? (v[1].asFloat ?? 1.6) : 1.6
            let brush = Brush(kind: kind, color: color, size: width > 0 ? width : 1.6, minSizeRatio: 1)
            return .exact(paths.map { Stroke(brush: brush, points: $0.map { InkPoint($0 + offset) }) })
        }

        // Variable-width pens store the filled outline: codes at base+4, moveTo points at
        // base+5, cubic control/end points at base+7 (see docs/GOODNOTES_FORMAT.md).
        guard let path = outlinePath(codes: v[base + 4].items.compactMap(\.asInt),
                                     starts: v[base + 5].items.compactMap(\.asFloat),
                                     cubics: v[base + 7].items.compactMap(\.asFloat)) else { return .failed }
        return .outline(FilledShape(path: path.map { $0.translated(by: offset) }, color: color))
    }

    /// Outline code tables observed in Goodnotes files. A table applies only when its moveTo and
    /// cubic counts account for every coordinate exactly; otherwise the stroke is reported.
    static let outlineCodeTables: [(move: Int, cubic: Int, close: Int?)] = [(2, 4, nil), (0, 2, 6)]

    static func outlinePath(codes: [Int], starts: [Double], cubics: [Double]) -> [PathCommand]? {
        guard !codes.isEmpty, starts.count % 2 == 0, cubics.count % 6 == 0 else { return nil }
        for table in outlineCodeTables {
            let known = Set([table.move, table.cubic] + (table.close.map { [$0] } ?? []))
            guard codes.allSatisfy(known.contains),
                  codes.filter({ $0 == table.move }).count * 2 == starts.count,
                  codes.filter({ $0 == table.cubic }).count * 6 == cubics.count,
                  codes.first == table.move else { continue }
            var path: [PathCommand] = []
            var si = 0, ci = 0
            for code in codes {
                if code == table.move {
                    if !path.isEmpty { path.append(.close) }
                    path.append(.move(Point(starts[si], starts[si + 1]))); si += 2
                } else if code == table.cubic {
                    let c = cubics[ci..<(ci + 6)].map { $0 }; ci += 6
                    path.append(.cubic(control1: Point(c[0], c[1]), control2: Point(c[2], c[3]), to: Point(c[4], c[5])))
                } else {
                    path.append(.close)
                }
            }
            if path.last != .close { path.append(.close) }
            return path
        }
        return nil
    }

    /// Kind 22: shape-tool line. Points are field 20 {1: start, 2: via (repeated), 3: end}, or
    /// field 21 {1: start, 3: end, 5.2: midpoint}; style is field 32 {1: width, 2.2: dash, 3.1: color}.
    static func shapeLine(_ body: ProtoMessage) -> Stroke? {
        func point(_ m: ProtoMessage?) -> Point? {
            guard let m, let x = m.float(1), let y = m.float(2) else { return nil }
            return Point(x, y)
        }
        var points: [Point] = []
        if let g = body.message(20), let start = point(g.message(1)?.message(1)), let end = point(g.message(3)?.message(1)) {
            let via = g.all(2).compactMap { value -> Point? in
                if case .bytes(let d) = value { return point(ProtoMessage(d)) }
                return nil
            }
            points = [start] + via + [end]
        } else if let g = body.message(21), let start = point(g.message(1)?.message(1)), let end = point(g.message(3)?.message(1)) {
            // A midpoint off the chord makes a curve; flatten it as a quadratic through that point.
            if let mid = point(g.message(5)?.message(2)) {
                let control = mid * 2 - (start + end) * 0.5
                points = [start] + flattenQuadratic(from: start, control: control, to: end)
            } else {
                points = [start, end]
            }
        }
        guard points.count >= 2 else { return nil }
        let style = body.message(32)
        let width = style?.float(1) ?? 1
        let dash = style?.message(2)?.message(2).flatMap { d -> [Double]? in
            guard let on = d.float(1), let off = d.float(2), on > 0, off > 0 else { return nil }
            return [on, off]
        }
        let brush = Brush(kind: .pen, color: rgba(style?.message(3)?.message(1)), size: max(0.3, width),
                          minSizeRatio: 1, dash: dash)
        return Stroke(brush: brush, points: points.map { InkPoint($0) })
    }

    /// Kind 20: sticky note. Field 20.1 origin, 21.2 size, 30 background RGBA, 31 text content
    /// (same run format as text boxes), 33 author name (not imported).
    static func stickyNote(_ body: ProtoMessage) -> TextBox? {
        guard let origin = body.message(20)?.message(1) else { return nil }
        let size = body.message(21)?.message(2)
        let content = body.message(31)
        let run = content?.message(1)?.bytes(2).flatMap { try? AppleLZ4.decode($0) }.flatMap(ProtoMessage.init)?.message(1)
        let style = content?.message(5)?.message(1)
        let background = body.message(30).map { rgba($0) } ?? RGBA(1, 0.95, 0.6)
        return TextBox(frame: Rect(x: origin.float(1) ?? 0, y: origin.float(2) ?? 0,
                                   width: size?.float(1) ?? 256, height: size?.float(2) ?? 256),
                       text: run?.string(1) ?? "", fontSize: style?.float(40) ?? 18,
                       color: rgba(style?.message(3)), background: background)
    }

    /// Rebuilds subpaths from moveTo (0) / quadTo (1) commands and flat float arrays.
    /// Returns nil when the arrays disagree with the command list.
    static func quadraticPaths(_ commands: [Int], _ starts: [Double], _ segments: [Double]) -> [[Point]]? {
        guard starts.count % 2 == 0, segments.count % 4 == 0,
              commands.filter({ $0 == 0 }).count == starts.count / 2,
              commands.filter({ $0 == 1 }).count == segments.count / 4 else { return nil }
        var paths: [[Point]] = []
        var si = 0, gi = 0
        for command in commands {
            if command == 0 {
                paths.append([Point(starts[si], starts[si + 1])]); si += 2
            } else {
                guard let last = paths.last?.last else { return nil }   // quadTo before any moveTo
                let c = Point(segments[gi], segments[gi + 1]), e = Point(segments[gi + 2], segments[gi + 3]); gi += 4
                paths[paths.count - 1].append(contentsOf: flattenQuadratic(from: last, control: c, to: e))
            }
        }
        return paths
    }

    static func flattenQuadratic(from a: Point, control c: Point, to b: Point) -> [Point] {
        let length = a.distance(to: c) + c.distance(to: b)
        let steps = max(1, min(32, Int(length / 3)))
        return (1...steps).map { i in
            let t = Double(i) / Double(steps), u = 1 - t
            return a * (u * u) + c * (2 * u * t) + b * (t * t)
        }
    }

    /// `{1: r, 2: g, 3: b, 4: a}` as f32; an omitted component is 0 (protobuf default).
    static func rgba(_ m: ProtoMessage?) -> RGBA {
        guard let m else { return .black }
        return RGBA(m.float(1) ?? 0, m.float(2) ?? 0, m.float(3) ?? 0, m.float(4) ?? 0)
    }

    static func rect(_ m: ProtoMessage?) -> Rect? {
        guard let o = m?.message(1), let s = m?.message(2) else { return nil }
        return Rect(x: o.float(1) ?? 0, y: o.float(2) ?? 0, width: s.float(1) ?? 0, height: s.float(2) ?? 0)
    }

    static func image(_ body: ProtoMessage, source: GoodnotesSource, assets: inout [String: Data]) -> PlacedImage? {
        guard let id = body.string(4), let frame = rect(body.message(3)),
              let data = source.data(at: "attachments/\(id)") else { return nil }
        let name = id + imageExtension(data)
        assets[name] = data
        return PlacedImage(frame: frame, asset: name)
    }

    static func textBox(_ body: ProtoMessage) -> TextBox? {
        guard let content = body.message(32), let blob = content.message(1)?.bytes(2),
              let raw = try? AppleLZ4.decode(blob),
              // Decoded payload: {1: {1: text, 2: run style, 3: paragraph style}}.
              let run = ProtoMessage(raw)?.message(1) else { return nil }
        let text = run.string(1) ?? ""
        let origin = body.message(20)?.message(1)
        let size = content.message(2)
        let style = content.message(5)?.message(1)
        return TextBox(frame: Rect(x: origin?.float(1) ?? 0, y: origin?.float(2) ?? 0,
                                   width: size?.float(1) ?? 300, height: size?.float(2) ?? 40),
                       text: text, fontSize: style?.float(40) ?? 18, color: rgba(style?.message(3)))
    }

    // MARK: Handwriting recognition

    /// `search/<noteId>`: one message whose repeated field 6 holds recognized words
    /// (1 = bbox, 3 = ranked candidates). Words are grouped into lines by vertical center.
    static func recognizedText(_ data: Data) -> String {
        guard let msg = ProtoMessage(data) else { return "" }
        let words = msg.all(6).compactMap { value -> TextLayout.Word? in
            guard case .bytes(let raw) = value, let w = ProtoMessage(raw), let best = w.string(3),
                  let box = rect(w.message(1)) else { return nil }
            return TextLayout.Word(frame: box, text: best)
        }
        return TextLayout.transcript(words)
    }
}
