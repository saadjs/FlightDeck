@testable import AppBundle
import XCTest

/// Regression tests for the "stale native focus" trap: after FlightDeck focuses an empty
/// workspace, macOS keeps the previous app active while its window is hidden. Re-activating
/// that app (Dock/Spotlight/Raycast) fires no didActivateApplication notification, so
/// FlightDeck must proactively take native focus away (takeNativeFocusIfFocusedWorkspaceIsEmpty).
@MainActor
final class FocusCacheTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testStaleNativeFocusDetectedAfterSwitchingToEmptyWorkspace() {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        _ = window.focusWindow()

        // Switching to a non-empty workspace: native focus follows the new window -> no trap
        assertEquals(staleNativeFocusedWindowOrNil(nativeFocusedWindowId: 1)?.windowId, nil)

        // Switching to an empty workspace: native focus stays on the hidden window -> trap
        _ = Workspace.get(byName: "empty").focusWorkspace()
        assertEquals(staleNativeFocusedWindowOrNil(nativeFocusedWindowId: 1)?.windowId, 1)
    }

    func testNoStaleNativeFocusWhenWindowIsGoneOrWorkspaceVisible() {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        _ = window.focusWindow()
        _ = Workspace.get(byName: "empty").focusWorkspace()

        // Unknown/closed window id -> no trap
        assertEquals(staleNativeFocusedWindowOrNil(nativeFocusedWindowId: 42)?.windowId, nil)

        // The window's workspace is visible (it is the active workspace again) -> no trap
        _ = Workspace.get(byName: "a").focusWorkspace()
        assertEquals(staleNativeFocusedWindowOrNil(nativeFocusedWindowId: 1)?.windowId, nil)
    }
}
