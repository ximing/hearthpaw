import XCTest
@testable import TuanTuan

final class PetGeometryTests: XCTestCase {
    func testSizeLimitsAndInvalidInput() {
        XCTAssertEqual(PetGeometry.boundedSize(20), 100)
        XCTAssertEqual(PetGeometry.boundedSize(300), 220)
        XCTAssertEqual(PetGeometry.boundedSize(.nan), 160)
        XCTAssertEqual(PetGeometry.boundedSize(175), 175)
    }

    func testKeepsPetAwayFromMenuBarAndDock() {
        let screen = CGRect(x: 0, y: 80, width: 1440, height: 790)
        let result = PetGeometry.clamped(CGRect(x: 1400, y: 10, width: 160, height: 160), to: screen)
        XCTAssertEqual(result, CGRect(x: 1280, y: 80, width: 160, height: 160))
    }

    func testNegativeCoordinateDisplayIsSupported() {
        let screens = [CGRect(x: -1920, y: 40, width: 1920, height: 1040),
                       CGRect(x: 0, y: 80, width: 1440, height: 790)]
        let frame = CGRect(x: -600, y: 100, width: 160, height: 160)
        XCTAssertEqual(PetGeometry.recovered(frame, screens: screens), frame)
    }

    func testDisconnectedDisplayRecoversVisiblePosition() {
        let screen = CGRect(x: 0, y: 80, width: 1440, height: 790)
        let result = PetGeometry.recovered(CGRect(x: -1600, y: 200, width: 160, height: 160), screens: [screen])
        XCTAssertEqual(result.minX, 0)
        XCTAssertTrue(screen.contains(result))
    }

    func testDragCanCrossDisplaysBeforeRelease() {
        var gesture = PetDragGesture(pointer: CGPoint(x: 20, y: 20), origin: CGPoint(x: -80, y: 50))
        let origin = gesture.moved(to: CGPoint(x: 1500, y: 400))
        XCTAssertTrue(gesture.hasDragged)
        XCTAssertEqual(origin, CGPoint(x: 1400, y: 430))
    }

    func testTinyPointerMovementRemainsClick() {
        var gesture = PetDragGesture(pointer: .zero, origin: .zero)
        _ = gesture.moved(to: CGPoint(x: 1, y: 1))
        XCTAssertFalse(gesture.hasDragged)
        _ = gesture.moved(to: CGPoint(x: 4, y: 0))
        XCTAssertTrue(gesture.hasDragged)
    }

    func testTransparentAndOpaquePixelsAtAnyScale() throws {
        let mask = try XCTUnwrap(AlphaMask(width: 2, height: 2, pixels: Data([0, 255, 255, 0])))
        let rect = CGRect(x: 10, y: 10, width: 200, height: 200)
        XCTAssertFalse(mask.contains(CGPoint(x: 11, y: 11), in: rect))
        XCTAssertTrue(mask.contains(CGPoint(x: 160, y: 50), in: rect))
        XCTAssertTrue(mask.contains(CGPoint(x: 50, y: 160), in: rect))
        XCTAssertFalse(mask.contains(CGPoint(x: 210, y: 50), in: rect))
        XCTAssertFalse(mask.contains(CGPoint(x: 160, y: 210), in: rect))
    }

    func testInvalidAlphaMaskFailsSafely() {
        XCTAssertNil(AlphaMask(width: 0, height: 2, pixels: Data()))
        XCTAssertNil(AlphaMask(width: 2, height: 2, pixels: Data([0])))
    }

    func testEmptyScreenListDoesNotDestroyPosition() {
        let frame = CGRect(x: 30, y: 40, width: 160, height: 160)
        XCTAssertEqual(PetGeometry.recovered(frame, screens: []), frame)
    }

    func testResizingRecoversOversizedFrame() {
        let screen = CGRect(x: 100, y: 50, width: 120, height: 100)
        let result = PetGeometry.clamped(CGRect(x: 0, y: 0, width: 220, height: 220), to: screen)
        XCTAssertEqual(result, screen)
    }
}
