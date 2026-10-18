import SwiftUI

/// A drawn mark for each engine, so connections read at a glance the way Termius shows a host's OS.
/// The marks are simple original silhouettes on a 24-point grid, not the projects' own logos.
struct EngineGlyph: Shape {
    let engine: DatabaseEngine

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        var transform = CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale).scaledBy(x: scale, y: scale)
        return Path(Self.glyphs[engine]?.copy(using: &transform) ?? CGMutablePath())
    }

    // CGPath is immutable once built; the marks are drawn once and shared.
    nonisolated(unsafe) private static let glyphs: [DatabaseEngine: CGPath] = Dictionary(
        uniqueKeysWithValues: DatabaseEngine.allCases.map { ($0, glyph(for: $0)) }
    )

    private static func glyph(for engine: DatabaseEngine) -> CGPath {
        switch engine {
        case .postgresql: elephant
        case .mysql: dolphin
        case .mariadb: seaLion
        case .sqlite: feather
        case .clickhouse: columns
        case .mongodb: leaf
        case .redis: layers
        case .elasticsearch: bands
        }
    }

    // MARK: Marks

    private static var elephant: CGPath {
        let head = CGPath(ellipseIn: CGRect(x: 7, y: 3.8, width: 13, height: 12.4), transform: nil)
        let ear = CGPath(ellipseIn: CGRect(x: 12.9, y: 4.8, width: 9.2, height: 12.4), transform: nil)
        let earEdge = curve(from: (15.6, 5.4), (12.6, 8.4), (12.6, 13.6), (15.6, 16.6)).stroked(1.1)
        let trunk = path { p in
            p.move(to: CGPoint(x: 9.6, y: 11.5))
            p.addCurve(to: CGPoint(x: 7.4, y: 19.4), control1: CGPoint(x: 8, y: 14.6), control2: CGPoint(x: 7.2, y: 17))
            p.addCurve(to: CGPoint(x: 4.4, y: 18), control1: CGPoint(x: 7.6, y: 21.4), control2: CGPoint(x: 4.8, y: 21))
        }.stroked(2.8)
        let eye = CGPath(ellipseIn: CGRect(x: 10.3, y: 7.6, width: 1.7, height: 1.7), transform: nil)
        return head.union(ear).subtracting(earEdge).union(trunk).subtracting(eye)
    }

    private static var dolphin: CGPath {
        let body = path { p in
            p.move(to: CGPoint(x: 21.6, y: 9.6))
            p.addCurve(to: CGPoint(x: 17, y: 6.6), control1: CGPoint(x: 20.2, y: 8.2), control2: CGPoint(x: 18.8, y: 6.7))
            p.addCurve(to: CGPoint(x: 13.2, y: 7.2), control1: CGPoint(x: 15.6, y: 6.5), control2: CGPoint(x: 14.4, y: 6.7))
            p.addCurve(to: CGPoint(x: 10.2, y: 3.4), control1: CGPoint(x: 12.4, y: 5.6), control2: CGPoint(x: 11.6, y: 4.2))
            p.addCurve(to: CGPoint(x: 9.8, y: 8.8), control1: CGPoint(x: 10.4, y: 5.4), control2: CGPoint(x: 10.4, y: 7.4))
            p.addCurve(to: CGPoint(x: 5, y: 15.8), control1: CGPoint(x: 7.8, y: 10.6), control2: CGPoint(x: 6, y: 13))
            p.addLine(to: CGPoint(x: 2.2, y: 15.2))
            p.addLine(to: CGPoint(x: 4.3, y: 17.6))
            p.addLine(to: CGPoint(x: 3.4, y: 20.8))
            p.addLine(to: CGPoint(x: 6.4, y: 17.2))
            p.addCurve(to: CGPoint(x: 16.4, y: 12.2), control1: CGPoint(x: 9.2, y: 14), control2: CGPoint(x: 12.6, y: 12.4))
            p.addCurve(to: CGPoint(x: 21.6, y: 9.6), control1: CGPoint(x: 18.6, y: 12), control2: CGPoint(x: 20.4, y: 10.8))
            p.closeSubpath()
        }.rounded(0.3)
        let flipper = polygon((13.6, 12.4), (12, 16), (15.8, 12.4)).rounded(0.5)
        let eye = CGPath(ellipseIn: CGRect(x: 17.4, y: 8, width: 1.3, height: 1.3), transform: nil)
        return body.union(flipper).subtracting(eye)
    }

    private static var seaLion: CGPath {
        let body = path { p in
            p.move(to: CGPoint(x: 3.6, y: 7.4))
            p.addCurve(to: CGPoint(x: 8.6, y: 3.8), control1: CGPoint(x: 4.6, y: 5), control2: CGPoint(x: 6.6, y: 3.6))
            p.addCurve(to: CGPoint(x: 11.8, y: 8.8), control1: CGPoint(x: 10.8, y: 4), control2: CGPoint(x: 11.6, y: 6.4))
            p.addCurve(to: CGPoint(x: 19.4, y: 16.8), control1: CGPoint(x: 12.2, y: 12.6), control2: CGPoint(x: 16, y: 13.6))
            p.addLine(to: CGPoint(x: 22.2, y: 15.4))
            p.addLine(to: CGPoint(x: 21, y: 18.8))
            p.addLine(to: CGPoint(x: 22.4, y: 20.8))
            p.addLine(to: CGPoint(x: 17.8, y: 20.6))
            p.addCurve(to: CGPoint(x: 9.4, y: 17.4), control1: CGPoint(x: 14.6, y: 21), control2: CGPoint(x: 11, y: 20.2))
            p.addCurve(to: CGPoint(x: 8, y: 10.2), control1: CGPoint(x: 8.2, y: 15.6), control2: CGPoint(x: 7.6, y: 12.6))
            p.addCurve(to: CGPoint(x: 3.6, y: 7.4), control1: CGPoint(x: 6.6, y: 9), control2: CGPoint(x: 4.4, y: 8.6))
            p.closeSubpath()
        }.rounded(0.3)
        let flipper = polygon((9.4, 15.6), (5, 20.8), (11.6, 19.8)).rounded(0.5)
        let eye = CGPath(ellipseIn: CGRect(x: 7.4, y: 5, width: 1.3, height: 1.3), transform: nil)
        return body.union(flipper).subtracting(eye)
    }

    private static var feather: CGPath {
        let vane = path { p in
            p.move(to: CGPoint(x: 7, y: 17.5))
            p.addCurve(to: CGPoint(x: 20.5, y: 3.5), control1: CGPoint(x: 5.5, y: 10.5), control2: CGPoint(x: 12, y: 4.5))
            p.addCurve(to: CGPoint(x: 7, y: 17.5), control1: CGPoint(x: 20, y: 11), control2: CGPoint(x: 13.5, y: 17))
            p.closeSubpath()
        }
        let shaft = line((3.4, 20.6), (17.6, 6.4))
        let quill = line((3.4, 20.6), (8.4, 15.6)).stroked(1.6)
        return vane.subtracting(shaft.stroked(1.1)).union(quill)
    }

    private static var columns: CGPath {
        let bars = (0..<4).map { CGRect(x: 2.5 + Double($0) * 4.1, y: 4, width: 2.6, height: 16) } + [CGRect(x: 18.9, y: 10, width: 2.6, height: 4)]
        return bars.reduce(CGMutablePath() as CGPath) { $0.union(CGPath(roundedRect: $1, cornerWidth: 0.5, cornerHeight: 0.5, transform: nil)) }
    }

    private static var leaf: CGPath {
        let blade = path { p in
            p.move(to: CGPoint(x: 12, y: 2.2))
            p.addCurve(to: CGPoint(x: 12, y: 19), control1: CGPoint(x: 18.6, y: 6.6), control2: CGPoint(x: 16.8, y: 14.6))
            p.addCurve(to: CGPoint(x: 12, y: 2.2), control1: CGPoint(x: 7.2, y: 14.6), control2: CGPoint(x: 5.4, y: 6.6))
            p.closeSubpath()
        }
        let vein = CGPath(roundedRect: CGRect(x: 11.55, y: 6.5, width: 0.9, height: 10.5), cornerWidth: 0.45, cornerHeight: 0.45, transform: nil)
        let stem = CGPath(roundedRect: CGRect(x: 11.25, y: 18.2, width: 1.5, height: 3.6), cornerWidth: 0.75, cornerHeight: 0.75, transform: nil)
        return blade.subtracting(vein).union(stem)
    }

    private static var layers: CGPath {
        // Slabs of an isometric stack with clear gaps between them.
        let top = polygon((12, 3.8), (21, 7.4), (12, 11), (3, 7.4)).rounded(0.4)
        let middle = polygon((3, 9.6), (12, 13.2), (21, 9.6), (21, 11.8), (12, 15.4), (3, 11.8)).rounded(0.4)
        let bottom = polygon((3, 14), (12, 17.6), (21, 14), (21, 16.2), (12, 19.8), (3, 16.2)).rounded(0.4)
        return top.union(middle).union(bottom)
    }

    private static var bands: CGPath {
        let disc = CGPath(ellipseIn: CGRect(x: 3, y: 3, width: 18, height: 18), transform: nil)
        let gaps = CGPath(rect: CGRect(x: 0, y: 8.6, width: 24, height: 1.3), transform: nil)
            .union(CGPath(rect: CGRect(x: 0, y: 14.1, width: 24, height: 1.3), transform: nil))
        return disc.subtracting(gaps)
    }

    // MARK: Building blocks

    private static func path(_ build: (CGMutablePath) -> Void) -> CGPath {
        let path = CGMutablePath()
        build(path)
        return path
    }

    private static func polygon(_ points: (Double, Double)...) -> CGPath {
        path { p in
            p.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
            p.closeSubpath()
        }
    }

    private static func line(_ from: (Double, Double), _ to: (Double, Double)) -> CGPath {
        path { p in
            p.move(to: CGPoint(x: from.0, y: from.1))
            p.addLine(to: CGPoint(x: to.0, y: to.1))
        }
    }

    private static func curve(from: (Double, Double), _ c1: (Double, Double), _ c2: (Double, Double), _ to: (Double, Double)) -> CGPath {
        path { p in
            p.move(to: CGPoint(x: from.0, y: from.1))
            p.addCurve(to: CGPoint(x: to.0, y: to.1), control1: CGPoint(x: c1.0, y: c1.1), control2: CGPoint(x: c2.0, y: c2.1))
        }
    }
}

private extension CGPath {
    func stroked(_ width: CGFloat) -> CGPath {
        copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    /// Softens corners by growing the shape with a round-joined outline.
    func rounded(_ radius: CGFloat = 0.6) -> CGPath {
        union(stroked(radius * 2))
    }
}

/// An engine's mark on its brand gradient, used where a connection or engine needs an icon.
struct EngineBadge: View {
    let engine: DatabaseEngine
    var size: CGFloat = 24
    var cornerRadius: CGFloat = 8
    /// A connection's color tag, which replaces the engine's gradient.
    var colors: [Color]? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: colors ?? engine.brandColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                EngineGlyph(engine: engine)
                    .fill(colors == nil ? engine.glyphColor : .white)
                    .frame(width: size * 0.64, height: size * 0.64)
            }
            .accessibilityHidden(true)
    }
}
