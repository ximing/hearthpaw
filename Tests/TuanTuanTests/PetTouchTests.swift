import XCTest
@testable import TuanTuan

final class PetTouchTests: XCTestCase {
    func testAllZonesAtDefaultSize() {
        let rect = CGRect(x: 4, y: 4, width: 152, height: 152)
        for zone in PetTouchZone.allCases {
            let point = PetTouchLayout.samplePoint(for: zone, in: rect)
            XCTAssertEqual(PetTouchLayout.zone(at: point, in: rect), zone)
        }
    }

    func testZonesRemainStableAtAllSupportedScales() {
        for edge in [100.0, 160.0, 220.0] {
            let rect = CGRect(x: 4, y: 4, width: edge - 8, height: edge - 8)
            for zone in PetTouchZone.allCases {
                XCTAssertEqual(PetTouchLayout.zone(at: PetTouchLayout.samplePoint(for: zone, in: rect), in: rect), zone)
            }
        }
    }

    func testTailWinsOverLowerBodyOnRightSide() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(PetTouchLayout.zone(at: CGPoint(x: 90, y: 85), in: rect), .tail)
        XCTAssertEqual(PetTouchLayout.zone(at: CGPoint(x: 50, y: 85), in: rect), .belly)
        XCTAssertEqual(PetTouchLayout.zone(at: CGPoint(x: 30, y: 45), in: rect), .cheek)
    }

    func testOutsideImageDoesNotTriggerZone() {
        let rect = CGRect(x: 4, y: 4, width: 92, height: 92)
        XCTAssertNil(PetTouchLayout.zone(at: .zero, in: rect))
        XCTAssertNil(PetTouchLayout.zone(at: CGPoint(x: 96, y: 50), in: rect))
        XCTAssertNil(PetTouchLayout.zone(at: CGPoint(x: 50, y: 96), in: rect))
        XCTAssertNil(PetTouchLayout.zone(at: .zero, in: .zero))
    }

    func testEachZoneHasDistinctFeedbackAndAnimationKey() {
        XCTAssertEqual(Set(PetTouchZone.allCases.map(\.response)).count, 4)
        XCTAssertEqual(Set(PetTouchZone.allCases.map(\.animationKey)).count, 4)
    }

    func testDragDoesNotBecomeAClickAfterReturningToOrigin() {
        var gesture = PetDragGesture(pointer: .zero, origin: .zero)
        _ = gesture.moved(to: CGPoint(x: 10, y: 10))
        _ = gesture.moved(to: .zero)
        XCTAssertTrue(gesture.hasDragged)
    }
}
