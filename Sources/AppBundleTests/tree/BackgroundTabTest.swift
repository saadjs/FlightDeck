@testable import AppBundle
import XCTest

final class BackgroundTabTest: XCTestCase {
    func testValidatesCompleteNativeTabGroup() {
        XCTAssertEqual(
            validatedNativeTabGroups([
                NativeTabGroupMember(signature: "shell", windowId: 10, selectedIndex: 0, tabCount: 2),
                NativeTabGroupMember(signature: "shell", windowId: 11, selectedIndex: 1, tabCount: 2),
            ]),
            ["shell": [10, 11]],
        )
    }

    func testRejectsAmbiguousIdenticalNativeTabGroups() {
        XCTAssertEqual(
            validatedNativeTabGroups([
                NativeTabGroupMember(signature: "shell", windowId: 10, selectedIndex: 0, tabCount: 2),
                NativeTabGroupMember(signature: "shell", windowId: 11, selectedIndex: 1, tabCount: 2),
                NativeTabGroupMember(signature: "shell", windowId: 12, selectedIndex: 0, tabCount: 2),
                NativeTabGroupMember(signature: "shell", windowId: 13, selectedIndex: 1, tabCount: 2),
            ]),
            [:],
        )
    }

    func testDetectsNativeTabSelectionSwap() {
        XCTAssertEqual(
            updateNativeTabState(
                groups: ["shell": [10, 11]],
                windowIds: [10, 11],
                previousOnScreen: [10],
                currentOnScreen: [11],
                previousBackgroundTabs: [11],
            ),
            NativeTabState(backgroundTabs: [10], replacements: [10: 11]),
        )
    }

    func testSeedsRestoredTabGroup() {
        XCTAssertEqual(
            updateNativeTabState(
                groups: ["shell": [10, 11, 12]],
                windowIds: [10, 11, 12],
                previousOnScreen: [],
                currentOnScreen: [10],
                previousBackgroundTabs: [],
            ),
            NativeTabState(backgroundTabs: [11, 12], replacements: [:]),
        )
    }

    func testPromotesNextTabWhenSelectedTabCloses() {
        XCTAssertEqual(
            updateNativeTabState(
                groups: ["shell": [11, 12]],
                windowIds: [11, 12],
                previousOnScreen: [10],
                currentOnScreen: [11],
                previousBackgroundTabs: [11, 12],
            ),
            NativeTabState(backgroundTabs: [12], replacements: [10: 11]),
        )
    }

    func testDoesNotTreatInactiveNativeSpaceAsTabGroup() {
        XCTAssertEqual(
            updateNativeTabState(
                groups: ["shell": [10, 11]],
                windowIds: [10, 11],
                previousOnScreen: [10],
                currentOnScreen: [],
                previousBackgroundTabs: [],
            ),
            NativeTabState(backgroundTabs: [], replacements: [:]),
        )
    }

    func testAmbiguousGroupIsNotSeeded() {
        XCTAssertEqual(
            updateNativeTabState(
                groups: ["ambiguous": [10, 11, 12, 13]],
                windowIds: [10, 11, 12, 13],
                previousOnScreen: [],
                currentOnScreen: [10, 11],
                previousBackgroundTabs: [],
            ),
            NativeTabState(backgroundTabs: [], replacements: [:]),
        )
    }
}
