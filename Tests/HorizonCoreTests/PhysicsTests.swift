import CoreGraphics
import HorizonCore
import XCTest

final class PhysicsTests: XCTestCase {
    func testRadiusGrowsWithEachItemAndStopsAtMaximum() {
        let empty = Physics.radius(items: 0, bytes: 0)
        let one = Physics.radius(items: 1, bytes: 0)
        let seven = Physics.radius(items: 7, bytes: 0)

        XCTAssertEqual(empty, Physics.baseRadius)
        XCTAssertEqual(one, Physics.baseRadius * 1.08, accuracy: 0.001)
        XCTAssertEqual(seven, Physics.baseRadius * 1.24, accuracy: 0.001)
        XCTAssertEqual(Physics.radius(items: 100_000, bytes: 500_000_000_000_000), Physics.maxRadius, accuracy: 0.001)
        XCTAssertEqual(Physics.radius(items: -3, bytes: -10), Physics.baseRadius)
    }

    func testBiggerItemsGrowTheHoleMore() {
        let text = Physics.radius(items: 1, bytes: 4_000)
        let archive = Physics.radius(items: 1, bytes: 1_400_000_000)
        XCTAssertGreaterThan(archive, text)
    }

    func testPullIsZeroOutsideInfluenceAndOneAtCenter() {
        let radius: CGFloat = 20
        XCTAssertEqual(Physics.pull(distance: 0, radius: radius), 1)
        XCTAssertEqual(Physics.pull(distance: Physics.influenceRadius(radius), radius: radius), 0)
        XCTAssertEqual(Physics.pull(distance: 10_000, radius: radius), 0)
        XCTAssertGreaterThan(Physics.pull(distance: radius * 3, radius: radius), Physics.pull(distance: radius * 5, radius: radius))
    }

    func testFallStartsAtDropPointAndEndsInvisibleAtCenter() {
        let start = CGVector(dx: 60, dy: -20)
        let begin = Physics.fall(t: 0, start: start, radius: 20)
        XCTAssertEqual(begin.offset.dx, start.dx, accuracy: 0.001)
        XCTAssertEqual(begin.offset.dy, start.dy, accuracy: 0.001)
        XCTAssertEqual(begin.alpha, 1)
        XCTAssertEqual(begin.stretch, 1)

        let end = Physics.fall(t: 1, start: start, radius: 20)
        XCTAssertEqual(hypot(end.offset.dx, end.offset.dy), 0, accuracy: 0.001)
        XCTAssertEqual(end.alpha, 0, accuracy: 0.001)
        XCTAssertEqual(end.stretch, 4, accuracy: 0.001)
    }

    func testEjectEndsAtTargetAndFadesOut() {
        let target = CGVector(dx: -80, dy: 40)
        let begin = Physics.eject(t: 0, target: target)
        XCTAssertEqual(hypot(begin.offset.dx, begin.offset.dy), 0, accuracy: 0.001)

        let end = Physics.eject(t: 1, target: target)
        XCTAssertEqual(end.offset.dx, target.dx, accuracy: 0.001)
        XCTAssertEqual(end.offset.dy, target.dy, accuracy: 0.001)
        XCTAssertEqual(end.alpha, 0, accuracy: 0.001)
    }

    func testBiggerItemsFallSlower() {
        XCTAssertGreaterThan(Physics.fallDuration(bytes: 2_000_000_000), Physics.fallDuration(bytes: 2_000))
    }
}
