import SwiftUI

/// Git glyphs drawn from Lucide's 24×24 outlines (ISC, see THIRD_PARTY_NOTICES.md),
/// the same family Orca uses for branch and pull-request state.
enum GitGlyph {
    case branch, pullRequest, pullRequestDraft, pullRequestClosed, merge

    var shape: some Shape { GlyphShape(glyph: self) }
}

struct GlyphShape: Shape {
    let glyph: GitGlyph

    func path(in rect: CGRect) -> Path {
        var p = Path()
        func circle(_ x: CGFloat, _ y: CGFloat) { p.addEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)) }
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            p.move(to: CGPoint(x: x1, y: y1))
            p.addLine(to: CGPoint(x: x2, y: y2))
        }
        switch glyph {
        case .branch:
            line(6, 3, 6, 15)
            circle(18, 6)
            circle(6, 18)
            p.move(to: CGPoint(x: 18, y: 9))
            p.addArc(center: CGPoint(x: 9, y: 9), radius: 9, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        case .merge:
            circle(18, 18)
            circle(6, 6)
            p.move(to: CGPoint(x: 6, y: 21))
            p.addLine(to: CGPoint(x: 6, y: 9))
            p.addArc(center: CGPoint(x: 15, y: 9), radius: 9, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        case .pullRequest:
            circle(18, 18)
            circle(6, 6)
            p.move(to: CGPoint(x: 13, y: 6))
            p.addLine(to: CGPoint(x: 16, y: 6))
            p.addArc(center: CGPoint(x: 16, y: 8), radius: 2, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: 18, y: 15))
            line(6, 9, 6, 21)
        case .pullRequestDraft:
            circle(18, 18)
            circle(6, 6)
            line(18, 6, 18, 5)
            line(18, 11, 18, 10)
            line(6, 9, 6, 21)
        case .pullRequestClosed:
            circle(6, 6)
            line(6, 9, 6, 21)
            line(21, 3, 15, 9)
            line(21, 9, 15, 3)
            line(18, 11.5, 18, 15)
            circle(18, 18)
        }
        let scale = min(rect.width, rect.height) / 24
        return p.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: rect.minX / scale, y: rect.minY / scale))
    }
}

struct GitGlyphView: View {
    let glyph: GitGlyph
    let color: Color
    var size: CGFloat = 13

    var body: some View {
        glyph.shape
            .stroke(color, style: StrokeStyle(lineWidth: 2 * size / 24 * 1.15, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}
