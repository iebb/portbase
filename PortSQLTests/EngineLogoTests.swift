import CoreGraphics
import XCTest
@testable import PortSQL

final class EngineLogoTests: XCTestCase {
    func testParsesAbsoluteAndRelativeLinesAndCloses() {
        let square = SVGPathParser.path(from: "M2 2h10v10H2z")
        XCTAssertEqual(square.boundingBoxOfPath, CGRect(x: 2, y: 2, width: 10, height: 10))
        let relative = SVGPathParser.path(from: "m2 2 10 0 0 10-10 0z")
        XCTAssertEqual(relative.boundingBoxOfPath, square.boundingBoxOfPath, "Pairs after a move continue as lines")
    }

    func testReadsRunTogetherNumbersAndCompactArcFlags() {
        // "0120" is large-arc 0, sweep 1, then x = 20: a half circle over the top from (0,10) to (20,10).
        let arc = SVGPathParser.path(from: "M0 10a10 10 0 0120 0")
        XCTAssertEqual(arc.currentPoint.x, 20, accuracy: 0.0001)
        XCTAssertEqual(arc.currentPoint.y, 10, accuracy: 0.0001)
        XCTAssertEqual(arc.boundingBoxOfPath.minY, 0, accuracy: 0.05)
        XCTAssertEqual(arc.boundingBoxOfPath.width, 20, accuracy: 0.05)

        let dots = SVGPathParser.path(from: "M.5.5L1.5-.5e1")
        XCTAssertEqual(dots.currentPoint, CGPoint(x: 1.5, y: -5))
    }

    func testSmoothCurvesReflectThePreviousControlPoint() {
        let wave = SVGPathParser.path(from: "M0 0C0 10 10 10 10 0S20-10 20 0")
        XCTAssertEqual(wave.currentPoint, CGPoint(x: 20, y: 0))
        XCTAssertEqual(wave.boundingBoxOfPath.maxY, 7.5, accuracy: 0.05)
        XCTAssertEqual(wave.boundingBoxOfPath.minY, -7.5, accuracy: 0.05)
    }

    func testEveryEngineLogoFillsItsGrid() {
        for engine in DatabaseEngine.allCases {
            let bounds = SVGPathParser.path(from: EngineGlyph.pathData(for: engine)).boundingBoxOfPath
            XCTAssertFalse(bounds.isEmpty, "\(engine.rawValue) has a logo")
            XCTAssertTrue(CGRect(x: -0.01, y: -0.01, width: 24.02, height: 24.02).contains(bounds), "\(engine.rawValue) stays on the 24-point grid: \(bounds)")
            XCTAssertGreaterThan(max(bounds.width, bounds.height), 20, "\(engine.rawValue) reaches across the grid")
        }
        let dolphin = EngineGlyph.glyph(for: .mysql).boundingBoxOfPath
        XCTAssertLessThan(dolphin.maxY, 14, "MySQL's icon leaves out the wordmark")
        XCTAssertGreaterThan(dolphin.width, 8, "and keeps the dolphin")
    }
}
