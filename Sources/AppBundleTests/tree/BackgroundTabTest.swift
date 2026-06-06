@testable import AppBundle
import XCTest

final class BackgroundTabTest: XCTestCase {
    // An off-screen window that isn't minimized/fullscreen is a background tab of a natively-tabbed app that
    // AppKit ordered out -> exclude it from the tree (otherwise it gets its own empty tile/accordion slot).
    func testBackgroundTabIsExcluded() {
        XCTAssertTrue(shouldExcludeAsBackgroundTab(
            detectBackgroundTabs: true, isOnScreen: false, isMinimized: false, isFullscreen: false,
        ))
    }

    // The active tab (on-screen) is a normal window -> keep it. NB kCGWindowIsOnscreen tracks ordered-in/out,
    // not pixel position, so a window merely repositioned off-screen (e.g. an inactive workspace hidden in a
    // corner) is still on-screen here and therefore kept.
    func testOnScreenWindowIsKept() {
        XCTAssertFalse(shouldExcludeAsBackgroundTab(
            detectBackgroundTabs: true, isOnScreen: true, isMinimized: false, isFullscreen: false,
        ))
    }

    // Minimized and native-fullscreen windows are legitimately off-screen and tracked via their own containers.
    func testMinimizedAndFullscreenAreKept() {
        XCTAssertFalse(shouldExcludeAsBackgroundTab(
            detectBackgroundTabs: true, isOnScreen: false, isMinimized: true, isFullscreen: false,
        ))
        XCTAssertFalse(shouldExcludeAsBackgroundTab(
            detectBackgroundTabs: true, isOnScreen: false, isMinimized: false, isFullscreen: true,
        ))
    }

    // When detection is disabled (lock screen, hidden app, empty on-screen snapshot) nothing is excluded.
    func testDetectionDisabledKeepsEverything() {
        XCTAssertFalse(shouldExcludeAsBackgroundTab(
            detectBackgroundTabs: false, isOnScreen: false, isMinimized: false, isFullscreen: false,
        ))
    }
}
