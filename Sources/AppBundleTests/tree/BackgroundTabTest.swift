@testable import AppBundle
import XCTest

final class BackgroundTabTest: XCTestCase {
    func testDetectsNativeTabSelectionSwap() {
        XCTAssertEqual(
            nativeTabReplacements(
                groups: ["shell": [10, 11]],
                previousOnScreen: [10],
                currentOnScreen: [11],
            ),
            [10: 11],
        )
    }

    func testDoesNotTreatInactiveNativeSpaceAsTabSwitch() {
        XCTAssertEqual(
            nativeTabReplacements(
                groups: ["shell": [10, 11]],
                previousOnScreen: [10],
                currentOnScreen: [],
            ),
            [:],
        )
    }

    func testDoesNotPairWindowsFromDifferentTabGroups() {
        XCTAssertEqual(
            nativeTabReplacements(
                groups: ["first": [10], "second": [11]],
                previousOnScreen: [10],
                currentOnScreen: [11],
            ),
            [:],
        )
    }

    func testAmbiguousGroupTransitionIsIgnored() {
        XCTAssertEqual(
            nativeTabReplacements(
                groups: ["shell": [10, 11, 12, 13]],
                previousOnScreen: [10, 11],
                currentOnScreen: [12, 13],
            ),
            [:],
        )
    }
}
