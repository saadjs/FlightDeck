@testable import AppBundle
import XCTest

@MainActor
final class BackgroundTabTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testValidatesCompleteNativeTabGroup() {
        XCTAssertEqual(
            validatedNativeTabGroups([
                NativeTabGroupMember(signature: "shell", windowId: 10, tabCount: 2),
                NativeTabGroupMember(signature: "shell", windowId: 11, tabCount: 2),
            ]),
            ["shell": [10, 11]],
        )
    }

    func testRejectsAmbiguousIdenticalNativeTabGroups() {
        XCTAssertEqual(
            validatedNativeTabGroups([
                NativeTabGroupMember(signature: "shell", windowId: 10, tabCount: 2),
                NativeTabGroupMember(signature: "shell", windowId: 11, tabCount: 2),
                NativeTabGroupMember(signature: "shell", windowId: 12, tabCount: 2),
                NativeTabGroupMember(signature: "shell", windowId: 13, tabCount: 2),
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

    func testDetectsNativeTabSelectionSwapWhileGroupWasOffScreen() {
        XCTAssertEqual(
            updateNativeTabState(
                groups: ["shell": [10, 11]],
                windowIds: [10, 11],
                previousOnScreen: [],
                currentOnScreen: [11],
                previousBackgroundTabs: [11],
                previousGroups: ["shell": [10, 11]],
            ),
            NativeTabState(backgroundTabs: [10], replacements: [10: 11]),
        )
    }

    func testDetectsNativeTabSelectionSwapFromIncompleteGroup() {
        XCTAssertEqual(
            updateNativeTabState(
                groups: [:],
                windowIds: [10, 11],
                previousOnScreen: [10],
                currentOnScreen: [11],
                previousBackgroundTabs: [],
                previousNativeTabWindowIds: [10],
                nativeTabWindowIds: [11],
            ),
            NativeTabState(backgroundTabs: [10], replacements: [10: 11]),
        )
    }

    func testDoesNotReplaceUnrelatedWindowWithNativeTabDuringSpaceChange() {
        XCTAssertEqual(
            updateNativeTabState(
                groups: ["shell": [10, 11]],
                windowIds: [10, 11, 20],
                previousOnScreen: [20],
                currentOnScreen: [10],
                previousBackgroundTabs: [11],
                previousGroups: ["shell": [10, 11]],
                previousNativeTabWindowIds: [10, 11],
                nativeTabWindowIds: [10, 11],
            ),
            NativeTabState(backgroundTabs: [11], replacements: [:]),
        )
    }

    func testDoesNotReplaceTabWhenGroupReturnsFromOffScreenUnchanged() {
        XCTAssertEqual(
            updateNativeTabState(
                groups: ["shell": [10, 11]],
                windowIds: [10, 11],
                previousOnScreen: [],
                currentOnScreen: [10],
                previousBackgroundTabs: [11],
                previousGroups: ["shell": [10, 11]],
            ),
            NativeTabState(backgroundTabs: [11], replacements: [:]),
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
                previousGroups: ["shell": [10, 11, 12]],
            ),
            NativeTabState(backgroundTabs: [12], replacements: [10: 11]),
        )
    }

    func testDoesNotPairUnrelatedClosedWindowWithPromotedTab() {
        XCTAssertEqual(
            updateNativeTabState(
                groups: ["shell": [10, 11, 12]],
                windowIds: [10, 11, 12],
                previousOnScreen: [10, 20],
                currentOnScreen: [11],
                previousBackgroundTabs: [11, 12],
                previousGroups: ["shell": [10, 11, 12]],
            ),
            NativeTabState(backgroundTabs: [10, 12], replacements: [10: 11]),
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

    func testDefersDetectionForFocusedWindowUntilRefresh() async throws {
        let originalWorkspace = Workspace.get(byName: "original")
        let callbackWorkspace = Workspace.get(byName: "callback")
        let window = TestWindow.new(id: 10, parent: originalWorkspace.rootTilingContainer)
        config.onWindowDetected = [
            WindowDetectedCallback(rawRun: [parseCommand("move-node-to-workspace callback").cmdOrDie]),
        ]

        window.deferOnWindowDetected()

        XCTAssertEqual(window.nodeWorkspace, originalWorkspace)
        try await window.runPendingOnWindowDetected()
        XCTAssertEqual(window.nodeWorkspace, callbackWorkspace)

        config.onWindowDetected = [
            WindowDetectedCallback(rawRun: [parseCommand("move-node-to-workspace original").cmdOrDie]),
        ]
        try await window.runPendingOnWindowDetected()
        XCTAssertEqual(window.nodeWorkspace, callbackWorkspace)
    }
}
