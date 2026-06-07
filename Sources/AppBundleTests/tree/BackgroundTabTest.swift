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

    func testDoesNotReplaceTabAcrossGroupsDuringSpaceChange() {
        XCTAssertEqual(
            updateNativeTabState(
                groups: [:],
                windowIds: [10, 11, 20, 21],
                previousOnScreen: [10],
                currentOnScreen: [20],
                previousBackgroundTabs: [11, 21],
                previousGroups: [
                    "shell": [10, 11],
                    "editor": [20, 21],
                ],
                previousNativeTabWindowIds: [10, 11, 20, 21],
                nativeTabWindowIds: [10, 11, 20, 21],
            ),
            NativeTabState(backgroundTabs: [11, 21], replacements: [:]),
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

    func testPromotesNextTabAfterTransientEmptyOnScreenFrame() {
        let initialHistory = NativeTabHistory(
            onScreenWindowIds: [10],
            groups: ["shell": [10, 11, 12]],
            windowIds: [10, 11, 12],
        )
        let intermediate = updateNativeTabState(
            groups: ["shell": [11, 12]],
            windowIds: [11, 12],
            previousOnScreen: initialHistory.onScreenWindowIds,
            currentOnScreen: [],
            previousBackgroundTabs: [11, 12],
            previousGroups: initialHistory.groups,
            previousNativeTabWindowIds: initialHistory.windowIds,
            nativeTabWindowIds: [11, 12],
        )
        XCTAssertEqual(intermediate, NativeTabState(backgroundTabs: [11, 12], replacements: [:]))
        let intermediateHistory = updateNativeTabHistory(
            initialHistory,
            currentOnScreen: [],
            axWindowIds: [11, 12],
            groups: ["shell": [11, 12]],
            nativeTabWindowIds: [11, 12],
        )
        XCTAssertEqual(intermediateHistory, initialHistory)

        XCTAssertEqual(
            updateNativeTabState(
                groups: ["shell": [11, 12]],
                windowIds: [11, 12],
                previousOnScreen: intermediateHistory.onScreenWindowIds,
                currentOnScreen: [11],
                previousBackgroundTabs: intermediate.backgroundTabs,
                previousGroups: intermediateHistory.groups,
                previousNativeTabWindowIds: intermediateHistory.windowIds,
                nativeTabWindowIds: [11, 12],
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
