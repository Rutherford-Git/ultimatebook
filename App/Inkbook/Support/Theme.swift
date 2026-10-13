import SwiftUI
import UIKit
import InkbookCore

/// Inkbook's small design system: a calm neutral backdrop, one accent, eight cloth cover colors.
enum Theme {
    static let accent = Color(red: 0.26, green: 0.42, blue: 0.85)

    /// Desk-like backdrop around pages (warm light gray / near-black).
    static let backdrop = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.09, alpha: 1)
            : UIColor(red: 0.925, green: 0.918, blue: 0.902, alpha: 1)
    }

    /// Cover cloths: ink, forest, clay, plum, mustard, slate, rose, sand.
    static let covers: [Color] = [
        Color(red: 0.18, green: 0.29, blue: 0.49), Color(red: 0.18, green: 0.36, blue: 0.31),
        Color(red: 0.71, green: 0.40, blue: 0.29), Color(red: 0.36, green: 0.29, blue: 0.48),
        Color(red: 0.79, green: 0.60, blue: 0.23), Color(red: 0.29, green: 0.33, blue: 0.38),
        Color(red: 0.72, green: 0.42, blue: 0.49), Color(red: 0.80, green: 0.73, blue: 0.60),
    ]

    static func cover(_ index: Int) -> Color { covers[((index % covers.count) + covers.count) % covers.count] }

    /// Quick palette for ink (first row) and highlighters (second row).
    static let inkColors: [RGBA] = [
        RGBA(0.10, 0.10, 0.12), RGBA(0.20, 0.35, 0.80), RGBA(0.80, 0.18, 0.20), RGBA(0.13, 0.55, 0.33),
        RGBA(0.50, 0.30, 0.75), RGBA(0.92, 0.50, 0.12),
    ]
    static let highlighterColors: [RGBA] = [
        RGBA(1, 0.92, 0.23, 0.35), RGBA(0.45, 0.90, 0.45, 0.35), RGBA(1, 0.55, 0.75, 0.35),
        RGBA(0.45, 0.75, 1, 0.35), RGBA(1, 0.65, 0.30, 0.35), RGBA(0.75, 0.60, 1, 0.35),
    ]

    static let paperWhite = RGBA(1, 1, 1)
    static let paperCream = RGBA(0.985, 0.972, 0.945)
}

extension RGBA {
    var swiftUI: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    /// Full-strength version for swatches (translucent highlighter colors would look washed out).
    var swatch: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
}

extension Color {
    var rgba: RGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(r, g, b, a)
    }
}

/// Notebook cover: cloth color with a spine and a paper label, or the first page as a thumbnail.
struct CoverView: View {
    let cover: NotebookCover
    let title: String
    var thumbnail: UIImage?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                switch cover {
                case .color(let i):
                    Theme.cover(i)
                    LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(title)
                        .font(.system(size: max(11, w * 0.085), weight: .semibold, design: .serif))
                        .foregroundStyle(Color.black.opacity(0.75))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(width: w * 0.62)
                        .background(Color(white: 0.98), in: RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .offset(y: -geo.size.height * 0.12)
                case .firstPage:
                    Color.white
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: "doc.richtext").font(.largeTitle).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                // Spine
                Rectangle().fill(.black.opacity(cover == .firstPage ? 0.08 : 0.22)).frame(width: w * 0.06)
                Rectangle().fill(.white.opacity(0.15)).frame(width: 1).offset(x: w * 0.06)
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3,
                                              bottomTrailingRadius: 10, topTrailingRadius: 10))
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 5)
        }
        .aspectRatio(0.77, contentMode: .fit)
    }
}

enum PaperStyle: String, CaseIterable, Identifiable {
    case blank, ruled, grid, dotted
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    func paper(_ tone: RGBA) -> Paper {
        switch self {
        case .blank: .blank(tone)
        case .ruled: .ruled(tone, spacing: 34)
        case .grid: .grid(tone, spacing: 28)
        case .dotted: .dotted(tone, spacing: 28)
        }
    }
}

/// Small drawing of a paper style for the new-notebook sheet.
struct PaperPreview: View {
    let style: PaperStyle
    let tone: RGBA

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(tone.swiftUI))
            let line = Color(red: 0.66, green: 0.77, blue: 0.91)
            let step = size.width / 7
            switch style {
            case .blank: break
            case .ruled:
                for y in stride(from: step, to: size.height, by: step * 0.8) {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(line), lineWidth: 0.8)
                }
            case .grid:
                for v in stride(from: step, to: max(size.width, size.height), by: step) {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: v)); $0.addLine(to: CGPoint(x: size.width, y: v)) },
                               with: .color(line), lineWidth: 0.6)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: v, y: 0)); $0.addLine(to: CGPoint(x: v, y: size.height)) },
                               with: .color(line), lineWidth: 0.6)
                }
            case .dotted:
                for y in stride(from: step, to: size.height, by: step) {
                    for x in stride(from: step, to: size.width, by: step) {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4)), with: .color(line))
                    }
                }
            }
        }
        .aspectRatio(0.77, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.black.opacity(0.08)))
    }
}
