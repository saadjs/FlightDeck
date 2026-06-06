import CoreGraphics
import Foundation

@MainActor
private var cache: [UInt32: MacOsWindowLevel] = [:]

@MainActor
func getWindowLevel(for windowId: UInt32) -> MacOsWindowLevel? {
    if let existing = cache[windowId] { return existing }

    var result: [UInt32: MacOsWindowLevel] = [:]
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    guard let cfArray = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [CFDictionary] else { return nil }
    for elem in cfArray {
        let dict = elem as NSDictionary

        guard let _windowLayer = dict[kCGWindowLayer] else { continue }
        let windowLayer = ((_windowLayer as! CFNumber) as NSNumber).intValue

        guard let _windowId = dict[kCGWindowNumber] else { continue }
        let windowId = ((_windowId as! CFNumber) as NSNumber).uint32Value

        result[windowId] = .new(windowLevel: windowLayer)
    }
    cache = result
    return result[windowId]
}

/// Window ids that macOS currently reports as on-screen.
///
/// Used to detect background tabs of natively-tabbed apps (e.g. Terminal.app, or Ghostty with
/// `macos-titlebar-style = tabs`/`native`). Such tabs remain in the app's `kAXWindowsAttribute`
/// and keep a valid `_AXUIElementGetWindow` id, but AppKit *orders the inactive tab out*, so it drops
/// out of this list. That lets us avoid giving every background tab its own tile.
///
/// Note: `kCGWindowIsOnscreen` reflects whether a window is ordered-in, not whether it lands within a
/// display's bounds — a window merely repositioned off-screen (e.g. an inactive AeroSpace workspace hidden in
/// a corner, even Zoom's fully-off-screen 0px placement) stays ordered-in and therefore remains in this set.
/// Not on-screen but legitimately tracked (minimized, native-fullscreen on another Space, windows of a hidden
/// app) must still be excluded from "background tab" detection by their own checks.
func currentlyOnScreenWindowIds() -> Set<UInt32> {
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    guard let cfArray = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [CFDictionary] else { return [] }
    var result: Set<UInt32> = []
    for elem in cfArray {
        let dict = elem as NSDictionary
        guard let _windowId = dict[kCGWindowNumber] else { continue }
        result.insert(((_windowId as! CFNumber) as NSNumber).uint32Value)
    }
    return result
}

enum MacOsWindowLevel: Sendable, Equatable {
    case normalWindow
    case alwaysOnTopWindow
    case unknown(windowLevel: Int)

    static func new(windowLevel: Int) -> MacOsWindowLevel {
        switch windowLevel {
            case 0: .normalWindow
            case 3: .alwaysOnTopWindow
            default: .unknown(windowLevel: windowLevel)
        }
    }

    static func fromJson(_ json: Json) -> MacOsWindowLevel? {
        switch json {
            case .string("normalWindow"): .normalWindow
            case .string("alwaysOnTopWindow"): .alwaysOnTopWindow
            case .int(let int): .new(windowLevel: Int(exactly: int).orDie())
            default: nil
        }
    }

    func toJson() -> Json {
        switch self {
            case .normalWindow: .string("normalWindow")
            case .alwaysOnTopWindow: .string("alwaysOnTopWindow")
            case .unknown(let layerNumber): .int(layerNumber)
        }
    }
}
