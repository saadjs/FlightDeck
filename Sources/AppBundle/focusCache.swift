import AppKit
import Common
import Darwin

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}

/// The window that silently retains macOS-native focus even though FlightDeck hid it
/// (the focused workspace is empty, so there was no window to pass native focus to).
/// In that state, re-activating the window's app via Dock/Spotlight/Raycast is a macOS no-op:
/// no didActivateApplication notification fires, and FlightDeck never learns it must switch workspaces.
@MainActor func staleNativeFocusedWindowOrNil() -> Window? {
    staleNativeFocusedWindowOrNil(nativeFocusedWindowId: lastKnownNativeFocusedWindowId)
}

@MainActor func staleNativeFocusedWindowOrNil(nativeFocusedWindowId: UInt32?) -> Window? {
    guard focus.windowOrNil == nil,
          let id = nativeFocusedWindowId,
          let window = Window.get(byId: id),
          window.visualWorkspace?.isVisible == false
    else { return nil }
    return window
}

/// Break the stale native focus trap: take macOS activation ourselves so that the next
/// user-initiated activation of the hidden app (Dock click, Spotlight, Raycast) is a real
/// app transition that fires didActivateApplication, which FlightDeck handles by switching
/// to the app's workspace.
@MainActor func takeNativeFocusIfFocusedWorkspaceIsEmpty() {
    if isUnitTest || serverArgs.isReadOnly { return }
    // NSApp.isActive is not reliable here: SkyLight-fronting doesn't run the AppKit activation
    // handshake, so judge by what macOS reports as the frontmost application.
    let selfIsFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == myPid
    if staleNativeFocusedWindowOrNil() != nil {
        if !selfIsFrontmost {
            activateSelf()
        }
    } else if !selfIsFrontmost && NSApp.activationPolicy() == .regular {
        // Another app took over activation: drop the temporary .regular policy (Dock icon).
        // Reverting earlier (while we are still frontmost) would make macOS bounce activation
        // right back to the hidden app, restoring the trap.
        NSApp.setActivationPolicy(.accessory)
    }
}

private typealias SLPSSetFrontProcessFn = @convention(c) (UnsafeRawPointer, UInt32, UInt32) -> Int32
private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

/// Activate FlightDeck itself. macOS cooperative activation silently denies NSApp.activate for a
/// background accessory app, and SkyLight refuses to front an accessory process (-606 appIsDaemon),
/// so temporarily become a .regular app and front ourselves with the same SkyLight call that AltTab
/// and yabai use. The policy is reverted in takeNativeFocusIfFocusedWorkspaceIsEmpty once another
/// app becomes active.
@MainActor private func activateSelf() {
    if NSApp.activationPolicy() != .regular {
        NSApp.setActivationPolicy(.regular)
    }
    guard let skyLight = unsafe dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let setFrontRaw = unsafe dlsym(skyLight, "_SLPSSetFrontProcessWithOptions"),
          let getPsnRaw = unsafe dlsym(unsafe dlopen(nil, RTLD_LAZY), "GetProcessForPID")
    else {
        NSApp.activate(ignoringOtherApps: true)
        return
    }
    var psn: (UInt32, UInt32) = (0, 0)
    guard unsafe unsafeBitCast(getPsnRaw, to: GetProcessForPIDFn.self)(getpid(), &psn) == 0 else {
        NSApp.activate(ignoringOtherApps: true)
        return
    }
    let kCPSUserGenerated: UInt32 = 0x200
    _ = unsafe unsafeBitCast(setFrontRaw, to: SLPSSetFrontProcessFn.self)(&psn, 0, kCPSUserGenerated)
}
