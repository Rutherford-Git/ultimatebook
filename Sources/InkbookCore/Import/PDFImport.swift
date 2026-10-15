import Foundation

/// Builds a notebook whose pages use the pages of one PDF as backgrounds. PDF parsing itself
/// (page count, sizes, rotation) is done by the platform (CGPDFDocument on iOS); this owns the
/// mapping into the notebook model.
public enum PDFImport {
    public struct PageInfo: Equatable, Sendable {
        /// Displayed size in points, after applying the page's rotation.
        public var size: Size
        /// Extracted page text, if the PDF has any (scans don't).
        public var text: String?
        public init(size: Size, text: String? = nil) { self.size = size; self.text = text }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noPages
        case invalidPageSize(index: Int)

        public var description: String {
            switch self {
            case .noPages: "The PDF has no pages."
            case .invalidPageSize(let i): "PDF page \(i + 1) has an invalid size."
            }
        }
    }

    /// - Parameter asset: name under which the caller stores the PDF in the notebook's assets.
    public static func notebook(title: String, asset: String, pages: [PageInfo]) throws -> Notebook {
        guard !pages.isEmpty else { throw Failure.noPages }
        let built = try pages.enumerated().map { i, info -> Page in
            guard info.size.width.isFinite, info.size.height.isFinite, info.size.width > 0, info.size.height > 0 else {
                throw Failure.invalidPageSize(index: i)
            }
            let text = info.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Page(size: info.size, paper: .asset(asset, pdfPage: i), backgroundText: text?.isEmpty == false ? text : nil)
        }
        return Notebook(title: title, pages: built)
    }
}
