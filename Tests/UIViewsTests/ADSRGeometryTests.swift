import XCTest
import CoreGraphics
@testable import UIViews

/// v15 §3.4 — ADSR curve-point math (pure function, no rendering).
final class ADSRGeometryTests: XCTestCase {

    private let size = (width: CGFloat(200), height: CGFloat(48))

    private func points(_ a: Double, _ d: Double, _ s: Double, _ r: Double) -> [CGPoint] {
        ADSRCurve.points(attack: a, decay: d, sustain: s, release: r,
                         width: size.width, height: size.height)
    }

    func testCurveStartsAtBottomLeftAndEndsAtBottomRight() {
        let pts = points(64, 64, 64, 64)
        XCTAssertEqual(pts.first, CGPoint(x: 0, y: size.height))
        XCTAssertEqual(pts.last?.x, size.width)
        XCTAssertEqual(pts.last?.y, size.height, "release always falls back to zero level")
    }

    func testRaisingAttackMovesThePeakRightAndKeepsItAtTop() {
        let fast = points(0, 64, 64, 64)
        let slow = points(127, 64, 64, 64)

        XCTAssertEqual(fast[1].x, 0, "zero attack is an instant rise")
        XCTAssertGreaterThan(slow[1].x, fast[1].x, "higher attack = wider rise")
        XCTAssertEqual(slow[1].y, 0, "the peak is always full level")
    }

    func testSustainLevelMapsOntoTheVerticalAxis() {
        let bottom = points(64, 64, 0, 64)
        let top = points(64, 64, 127, 64)

        XCTAssertEqual(bottom[2].y, size.height, "sustain 0 rests at the bottom")
        XCTAssertEqual(top[2].y, 0, "sustain 127 holds at the top")
    }

    func testDecayAndReleaseWidenTheirSegments() {
        let shortDecay = points(64, 0, 64, 64)
        let longDecay = points(64, 127, 64, 64)
        XCTAssertGreaterThan(longDecay[2].x, shortDecay[2].x)

        let shortRelease = points(64, 64, 64, 0)
        let longRelease = points(64, 64, 64, 127)
        // Release segment start (end of the sustain hold) shifts left when
        // more time is given to release, because all phases share the width.
        XCTAssertLessThan(longRelease[3].x, shortRelease[3].x)
    }

    func testXCoordinatesNeverGoBackwardsOrLeaveTheBox() {
        for sustain in [UInt8(0), 64, 127] {
            let pts = points(30, 90, Double(sustain), 45)
            for (prev, next) in zip(pts, pts.dropFirst()) {
                XCTAssertLessThanOrEqual(prev.x, next.x)
            }
            XCTAssertTrue(pts.allSatisfy { $0.x >= 0 && $0.x <= size.width })
            XCTAssertTrue(pts.allSatisfy { $0.y >= 0 && $0.y <= size.height })
        }
    }

    func testAllZeroValuesStillProduceAValidSustainHold() {
        let pts = points(0, 0, 0, 0)
        XCTAssertEqual(pts.count, 5)
        XCTAssertEqual(pts.last?.x, size.width, "the hold segment absorbs the full width")
    }
}
