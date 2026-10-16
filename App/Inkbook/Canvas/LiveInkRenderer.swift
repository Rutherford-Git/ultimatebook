import UIKit
import InkbookCore

/// Draws the stroke in progress piece by piece. A dirty-rect redraw only touches the pieces that
/// intersect the rect (normally just the newest segment and the temporary tail), so the cost per
/// frame stays flat however long the stroke gets.
@MainActor
enum LiveInkRenderer {
    /// - Parameters:
    ///   - tail: temporary points after the settled part (latest raw sample + predictions).
    ///   - rect: area being redrawn; pieces outside it are skipped.
    static func draw(_ live: LiveStroke, tail: [InkPoint], in ctx: CGContext, rect: CGRect) {
        guard !live.isEmpty else { return }
        let brush = live.brush
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Draw opaque, composite once at the ink's alpha: overlapping pieces never darken.
        let c = brush.color
        ctx.setAlpha(c.a)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { ctx.endTransparencyLayer() }
        let opaque = CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)

        if brush.dash != nil {
            // Dash phase depends on the whole length; dashed lines are rare and short.
            var solid = brush
            solid.color = RGBA(c.r, c.g, c.b, 1)
            PageRenderer.drawStroke(Stroke(brush: solid, points: live.kept + tail.dropFirst()), in: ctx)
            return
        }

        let outline = brush.kind == .pen && brush.minSizeRatio < 1
        let kept = live.kept
        if outline {
            ctx.setFillColor(opaque)
            for i in kept.indices where live.pieceBounds[i].cgRect.intersects(rect) {
                fillPiece(i == 0 ? kept[0] : kept[i - 1], kept[i], live: live, in: ctx)
            }
            for i in tail.indices.dropFirst() { fillPiece(tail[i - 1], tail[i], live: live, in: ctx) }
        } else {
            ctx.setStrokeColor(opaque)
            ctx.setLineWidth(brush.size)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for i in kept.indices where live.pieceBounds[i].cgRect.intersects(rect) {
                let a = i == 0 ? kept[0].location : kept[i - 1].location
                ctx.move(to: a.cg)
                ctx.addLine(to: i == 0 ? CGPoint(x: a.x + 0.01, y: a.y) : kept[i].location.cg)
            }
            if tail.count > 1 { ctx.addLines(between: tail.map { $0.location.cg }) }
            ctx.strokePath()
        }
    }

    /// One pen segment: round ends sized by pressure joined by a quad. Filled as separate shapes
    /// (inside the transparency layer) so path winding can never cut holes.
    private static func fillPiece(_ a: InkPoint, _ b: InkPoint, live: LiveStroke, in ctx: CGContext) {
        let ra = live.radius(a), rb = live.radius(b)
        let pa = a.location.cg, pb = b.location.cg
        ctx.fillEllipse(in: CGRect(x: pb.x - rb, y: pb.y - rb, width: rb * 2, height: rb * 2))
        let dx = pb.x - pa.x, dy = pb.y - pa.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.01 else {
            ctx.fillEllipse(in: CGRect(x: pa.x - ra, y: pa.y - ra, width: ra * 2, height: ra * 2))
            return
        }
        let nx = -dy / len, ny = dx / len
        ctx.move(to: CGPoint(x: pa.x + nx * ra, y: pa.y + ny * ra))
        ctx.addLine(to: CGPoint(x: pb.x + nx * rb, y: pb.y + ny * rb))
        ctx.addLine(to: CGPoint(x: pb.x - nx * rb, y: pb.y - ny * rb))
        ctx.addLine(to: CGPoint(x: pa.x - nx * ra, y: pa.y - ny * ra))
        ctx.closePath()
        ctx.fillPath()
        ctx.fillEllipse(in: CGRect(x: pa.x - ra, y: pa.y - ra, width: ra * 2, height: ra * 2))
    }

    /// The live straight highlighter, drawn with normal blending: the multiply layer above does the
    /// blending, so the stroke must not multiply a second time.
    static func drawStraightHighlight(_ line: Stroke, in ctx: CGContext) {
        guard let a = line.points.first?.location, let b = line.points.last?.location else { return }
        let c = line.brush.color
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(c.a)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { ctx.endTransparencyLayer() }
        ctx.setStrokeColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1))
        ctx.setLineWidth(line.brush.size)
        ctx.setLineCap(.butt)
        ctx.move(to: a.cg)
        ctx.addLine(to: b.cg)
        ctx.strokePath()
    }

    /// Previous approach, kept for A/B timing: rebuilds and draws the whole stroke every frame.
    static func drawLegacy(raw: [InkPoint], predicted: [InkPoint], brush: Brush, in ctx: CGContext) {
        guard !raw.isEmpty else { return }
        PageRenderer.drawStroke(Stroke(brush: brush, points: raw + predicted), in: ctx)
    }
}
