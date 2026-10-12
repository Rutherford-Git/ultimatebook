import Foundation

/// A change the agent wants to make. Never applied without an explicit user approval.
public enum AgentProposal: Equatable, Sendable {
    case note(pageIndex: Int, box: TextBox)
    case highlight(pageIndex: Int, region: HighlightRegion)

    public var pageIndex: Int {
        switch self {
        case .note(let i, _), .highlight(let i, _): i
        }
    }

    /// Short human-readable description for the approval sheet.
    public var summary: String {
        switch self {
        case .note(let i, let box):
            "Add a note on page \(i + 1): \u{201C}\(box.text.prefix(120))\u{201D}"
        case .highlight(let i, let r):
            "Highlight a \(Int(r.frame.size.width))\u{00D7}\(Int(r.frame.size.height)) pt region on page \(i + 1)"
        }
    }

    /// Applies the change to the page's dedicated Agent layer (created on demand), so agent
    /// content is always separable from the user's own ink.
    public func apply(to notebook: inout Notebook) throws {
        guard notebook.pages.indices.contains(pageIndex) else { throw AgentToolError.noSuchPage(pageIndex + 1) }
        let layer = notebook.pages[pageIndex].ensureAgentLayer()
        switch self {
        case .note(_, let box): notebook.pages[pageIndex].layers[layer].elements.append(.text(box))
        case .highlight(_, let r): notebook.pages[pageIndex].layers[layer].elements.append(.highlight(r))
        }
        notebook.modified = Date()
    }
}

public enum ApprovalDecision: Equatable, Sendable {
    case approve
    case reject(reason: String?)
}

/// The app's side of the bridge. All methods are called from the agent loop.
public protocol AgentNotebookHost: AnyObject {
    func snapshot() async -> Notebook
    /// Called only after the user approved `proposal`.
    func apply(_ proposal: AgentProposal) async throws
    /// PNG of the page with long edge <= `maxPixels`, or nil when rendering is unavailable.
    func renderPage(_ index: Int, maxPixels: Int) async -> Data?
    /// Shows the proposal to the user and waits for their decision.
    func requestApproval(_ proposal: AgentProposal) async -> ApprovalDecision
}

public enum AgentToolError: Error, Equatable, CustomStringConvertible {
    case unknownTool(String)
    case invalidInput(String)
    case noSuchPage(Int)
    case notebookClosed

    public var description: String {
        switch self {
        case .unknownTool(let n): "Unknown tool \(n)"
        case .invalidInput(let why): "Invalid input: \(why)"
        case .noSuchPage(let p): "Page \(p) does not exist"
        case .notebookClosed: "The notebook was closed"
        }
    }
}

/// Result content for one tool call (text plus optional page image).
public struct ToolOutput: Equatable, Sendable {
    public var text: String
    public var png: Data?
    public var isError: Bool

    public init(text: String, png: Data? = nil, isError: Bool = false) {
        self.text = text; self.png = png; self.isError = isError
    }
}

/// Notebook tools exposed to the model. Reads run immediately; writes become proposals
/// that the user approves or rejects one by one.
public enum NotebookTools {
    /// Long edge of page images sent to the model (the API downsamples beyond ~1568 px).
    public static let imageLongEdge = 1500

    public static let highlightColors: [String: RGBA] = [
        "yellow": RGBA(1, 0.92, 0.23, 0.35), "green": RGBA(0.3, 0.9, 0.4, 0.3),
        "pink": RGBA(1, 0.4, 0.7, 0.3), "blue": RGBA(0.3, 0.6, 1, 0.3),
    ]

    static func schema(_ properties: [String: JSONValue]) -> JSONValue {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(properties.keys.sorted().map { .string($0) }),
            "additionalProperties": false,
        ])
    }

    static func tool(_ name: String, _ description: String, _ properties: [String: JSONValue]) -> JSONValue {
        ["name": .string(name), "description": .string(description), "strict": true, "input_schema": schema(properties)]
    }

    static let page: JSONValue = ["type": "integer", "description": "1-based page number"]
    static func number(_ d: String) -> JSONValue { ["type": "number", "description": .string(d)] }

    /// Tool definitions in Messages API form, in a fixed order (stable prompt-cache prefix).
    public static let definitions: [JSONValue] = [
        tool("list_pages",
             "List every page in the open notebook with its size, element counts and a short text preview. Call this first to orient yourself.",
             [:]),
        tool("read_page",
             "Read one page: typed text boxes, the handwriting transcript, and the positions of strokes, images and annotations. Set include_image to also receive a rendered picture of the page (needed for diagrams, math and drawings, which transcripts miss).",
             ["page": page, "include_image": ["type": "boolean", "description": "Attach a PNG rendering of the page"]]),
        tool("add_note",
             "Propose a sticky note on a page's Agent layer. Coordinates are page points, origin top-left. The user must approve it before it appears; the result says whether it was approved.",
             ["page": page, "x": number("Left edge in page points"), "y": number("Top edge in page points"),
              "width": number("Note width in page points (120-500 is typical)"),
              "text": ["type": "string", "description": "Note text, plain text, at most ~600 characters"]]),
        tool("add_highlight",
             "Propose a translucent highlight rectangle over a page region on the Agent layer. Coordinates are page points, origin top-left. Requires user approval.",
             ["page": page, "x": number("Left edge in page points"), "y": number("Top edge in page points"),
              "width": number("Width in page points"), "height": number("Height in page points"),
              "color": ["type": "string", "enum": ["yellow", "green", "pink", "blue"]]]),
    ]

    public static func run(_ name: String, input: JSONValue, host: AgentNotebookHost) async -> ToolOutput {
        do {
            switch name {
            case "list_pages": return ToolOutput(text: listPages(await host.snapshot()))
            case "read_page": return try await readPage(input, host: host)
            case "add_note", "add_highlight": return try await propose(name, input, host: host)
            default: throw AgentToolError.unknownTool(name)
            }
        } catch {
            return ToolOutput(text: "\(error)", isError: true)
        }
    }

    static func listPages(_ notebook: Notebook) -> String {
        var lines = ["Notebook \u{201C}\(notebook.title)\u{201D}, \(notebook.pages.count) page(s). Units are points, origin top-left."]
        for (i, p) in notebook.pages.enumerated() {
            let c = counts(p)
            let preview = p.allText.replacingOccurrences(of: "\n", with: " ").prefix(100)
            lines.append("page \(i + 1): \(Int(p.size.width))x\(Int(p.size.height)), \(c.strokes) strokes, "
                + "\(c.texts) text boxes, \(c.images) images, \(c.agent) agent annotations"
                + (preview.isEmpty ? "" : " \u{2014} \u{201C}\(preview)\u{201D}"))
        }
        return lines.joined(separator: "\n")
    }

    static func counts(_ p: Page) -> (strokes: Int, texts: Int, images: Int, agent: Int) {
        var r = (strokes: 0, texts: 0, images: 0, agent: 0)
        for layer in p.layers {
            if layer.kind == .agent { r.agent += layer.elements.count; continue }
            for e in layer.elements {
                switch e {
                case .stroke: r.strokes += 1
                case .text: r.texts += 1
                case .image: r.images += 1
                case .highlight: break
                }
            }
        }
        return r
    }

    static func pageIndex(_ input: JSONValue, _ notebook: Notebook) throws -> Int {
        guard let n = input["page"]?.number, n.rounded() == n else { throw AgentToolError.invalidInput("page must be an integer") }
        let i = Int(n) - 1
        guard notebook.pages.indices.contains(i) else { throw AgentToolError.noSuchPage(Int(n)) }
        return i
    }

    static func readPage(_ input: JSONValue, host: AgentNotebookHost) async throws -> ToolOutput {
        let notebook = await host.snapshot()
        let i = try pageIndex(input, notebook)
        let page = notebook.pages[i]
        var out = ["Page \(i + 1) of \(notebook.pages.count), \(Int(page.size.width))x\(Int(page.size.height)) pt."]
        for layer in page.layers {
            out.append("\nLayer \u{201C}\(layer.name)\u{201D} (\(layer.kind.rawValue)\(layer.isVisible ? "" : ", hidden")):")
            if layer.kind == .raster { out.append("  painted bitmap layer (see image)"); continue }
            var strokeBounds: [Rect] = []
            for e in layer.elements {
                switch e {
                case .text(let t): out.append("  text box at \(box(t.frame)): \(t.text)")
                case .image(let img): out.append("  image at \(box(img.frame))")
                case .highlight(let h): out.append("  highlight at \(box(h.frame))")
                case .stroke(let s): if let b = s.bounds { strokeBounds.append(b) }
                }
            }
            if let ink = Rect.bounding(strokeBounds.flatMap { [$0.origin, Point($0.maxX, $0.maxY)] }) {
                out.append("  \(strokeBounds.count) handwritten strokes covering \(box(ink))")
            }
        }
        if let text = page.recognizedText, !text.isEmpty {
            out.append("\nHandwriting transcript (machine-recognized, may contain errors):\n\(text)")
        }
        var png: Data?
        if input["include_image"]?.bool == true {
            png = await host.renderPage(i, maxPixels: imageLongEdge)
            if png != nil {
                let scale = max(page.size.width, page.size.height) / Double(imageLongEdge)
                out.append("\nImage attached. Multiply image pixel coordinates by \(String(format: "%.4f", scale)) to get page points.")
            } else {
                out.append("\nImage rendering is unavailable on this device.")
            }
        }
        return ToolOutput(text: out.joined(separator: "\n"), png: png)
    }

    static func box(_ r: Rect) -> String {
        "x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.size.width)) h=\(Int(r.size.height))"
    }

    static func propose(_ name: String, _ input: JSONValue, host: AgentNotebookHost) async throws -> ToolOutput {
        let notebook = await host.snapshot()
        let i = try pageIndex(input, notebook)
        let size = notebook.pages[i].size
        func coord(_ key: String) throws -> Double {
            guard let v = input[key]?.number, v.isFinite else { throw AgentToolError.invalidInput("\(key) must be a number") }
            return v
        }
        let x = try coord("x"), y = try coord("y"), w = try coord("width")
        guard w > 0, x >= 0, y >= 0, x < size.width, y < size.height else {
            throw AgentToolError.invalidInput("rectangle must start on the page (0..\(Int(size.width)), 0..\(Int(size.height))) with positive size")
        }
        let proposal: AgentProposal
        if name == "add_note" {
            guard let text = input["text"]?.string, !text.isEmpty else { throw AgentToolError.invalidInput("text is required") }
            let clipped = String(text.prefix(600))
            let width = min(w, size.width - x)
            let lines = max(1, Int(ceil(Double(clipped.count) * 8.5 / max(width - 12, 40)))) + clipped.filter { $0 == "\n" }.count
            proposal = .note(pageIndex: i, box: TextBox(
                frame: Rect(x: x, y: y, width: width, height: Double(lines) * 20 + 16),
                text: clipped, fontSize: 15, color: RGBA(0.15, 0.15, 0.2), background: RGBA(1, 0.95, 0.6, 0.92)))
        } else {
            let h = try coord("height")
            guard h > 0 else { throw AgentToolError.invalidInput("height must be positive") }
            let color = highlightColors[input["color"]?.string ?? "yellow"] ?? highlightColors["yellow"]!
            proposal = .highlight(pageIndex: i, region: HighlightRegion(
                frame: Rect(x: x, y: y, width: min(w, size.width - x), height: min(h, size.height - y)), color: color))
        }
        switch await host.requestApproval(proposal) {
        case .approve:
            try await host.apply(proposal)
            return ToolOutput(text: "Approved by the user and added to page \(i + 1).")
        case .reject(let reason):
            return ToolOutput(text: "The user rejected this change" + (reason.map { ": \($0)" } ?? ".")
                + " Do not retry the same change unless asked.")
        }
    }
}
