import AppKit
import Common

// Potential alternative implementation
// https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md
// (only available since macOS 14)
final class MacApp: AbstractApp {
    /*conforms*/ let pid: Int32
    /*conforms*/ let rawAppBundleId: String?
    let appId: KnownBundleId?
    let nsApp: NSRunningApplication
    private let axApp: ThreadGuardedValue<AXUIElement>
    private let appAxSubscriptions: ThreadGuardedValue<[AxSubscription]> // keep subscriptions in memory
    private let windows: ThreadGuardedValue<[UInt32: AxWindow]> = .init([:])
    private let previousOnScreenWindowIds: ThreadGuardedValue<Set<UInt32>> = .init([])
    private let backgroundTabWindowIds: ThreadGuardedValue<Set<UInt32>> = .init([])
    private var windowsCount = 0
    var lastNativeFocusedWindowId: UInt32? = nil
    private var thread: Thread?
    private var setFrameJobs: [UInt32: RunLoopJob] = [:]
    @MainActor private static var focusJob: RunLoopJob? = nil

    /*conforms*/ var name: String? { nsApp.localizedName }
    /*conforms*/ var execPath: String? { nsApp.executableURL?.path }
    /*conforms*/ var bundlePath: String? { nsApp.bundleURL?.path }

    // todo think if it's possible to integrate this global mutable state to https://github.com/nikitabobko/AeroSpace/issues/1215
    //      and make deinitialization automatic in deinit
    @MainActor static var allAppsMap: [pid_t: MacApp] = [:]
    @MainActor private static var wipPids: [pid_t: AwaitableOneTimeBroadcastLatch] = [:]

    private init(_ nsApp: NSRunningApplication, _ axApp: AXUIElement, _ axSubscriptions: [AxSubscription], _ thread: Thread) {
        self.nsApp = nsApp
        self.axApp = .init(axApp)
        self.pid = nsApp.processIdentifier
        self.rawAppBundleId = nsApp.bundleIdentifier
        self.appId = nsApp.bundleIdentifier.flatMap { KnownBundleId.init(rawValue: $0) }
        assert(!axSubscriptions.isEmpty)
        self.appAxSubscriptions = .init(axSubscriptions)
        self.thread = thread
    }

    @MainActor
    @discardableResult
    static func getOrRegister(_ nsApp: NSRunningApplication) async throws -> MacApp? {
        // Don't perceive any of the lock screen windows as real windows
        // Otherwise, false positive ax notifications might trigger that lead to gcWindows
        if nsApp.bundleIdentifier == lockScreenAppBundleId { return nil }
        let pid = nsApp.processIdentifier
        // AX requests crash if you send them to yourself
        if pid == myPid { return nil }

        while true {
            if let existing = allAppsMap[pid] { return existing }
            try checkCancellation()
            if let wip = wipPids[pid] {
                try await wip.await()
                continue
            }
            let wip = AwaitableOneTimeBroadcastLatch()
            wipPids[pid] = wip

            let thread = Thread {
                $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: pid, idForDebug: nsApp.idForDebug)) {
                    let axApp = AXUIElementCreateApplication(nsApp.processIdentifier)
                    let handlers: HandlerToNotifKeyMapping = unsafe [
                        (refreshObs, [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]),
                    ]
                    let job = RunLoopJob()
                    let subscriptions = (try? unsafe AxSubscription.bulkSubscribe(nsApp, axApp, job, handlers)) ?? []
                    let isGood = !subscriptions.isEmpty
                    let app = isGood ? MacApp(nsApp, axApp, subscriptions, Thread.current) : nil
                    Task { @MainActor in
                        allAppsMap[pid] = app
                        await wip.signalToAll()
                        wipPids[pid] = nil
                    }
                    if isGood {
                        CFRunLoopRun()
                    }
                }
            }
            thread.name = "AxAppThread \(nsApp.idForDebug)"
            thread.start()
        }
    }

    func closeAndUnregisterAxWindow(_ windowId: UInt32) {
        if serverArgs.isReadOnly { return }
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        _ = withWindowAsync(windowId) { [windows] window, job in
            guard let closeButton = window.get(Ax.closeButtonAttr) else { return }
            if AXUIElementPerformAction(closeButton.cast, kAXPressAction as CFString) == .success {
                windows.threadGuarded.removeValue(forKey: windowId)
            }
        }
    }

    func getAxSize(_ windowId: UInt32) async throws -> CGSize? {
        try await withWindow(windowId) { window, job in
            window.get(Ax.sizeAttr)
        }
    }

    // todo merge together with detectNewWindows
    func getFocusedWindow() async throws -> Window? {
        let windowId = try await thread?.runInLoop { [nsApp, axApp, windows] job in
            try axApp.threadGuarded.get(Ax.focusedWindowAttr)
                .flatMap { try windows.threadGuarded.getOrRegisterAxWindow(windowId: $0.windowId, $0.ax.cast, nsApp, job) }?
                .windowId
        }
        guard let windowId else { return nil }
        return try await MacWindow.getOrRegister(windowId: windowId, macApp: self)
    }

    @MainActor func nativeFocus(_ windowId: UInt32) {
        if serverArgs.isReadOnly { return }
        MacApp.focusJob?.cancel()
        // Performance optimization. If possible avoid doing AX requests
        // (important for apps which are slow at responding even such basic AX requests. E.g. Godot)
        // Beware of the macOS bug: https://github.com/nikitabobko/AeroSpace/issues/101
        if (!NSScreen.screensHaveSeparateSpaces || monitors.count == 1) &&
            (lastNativeFocusedWindowId == windowId || windowsCount == 1)
        {
            nsApp.activate(options: .activateIgnoringOtherApps)
        } else {
            MacApp.focusJob = withWindowAsync(windowId) { [nsApp] window, job in
                // Raise firstly to make sure that by the time we activate the app, the window would be already on top
                window.set(Ax.isMainAttr, true)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                nsApp.activate(options: .activateIgnoringOtherApps)
            }
        }
    }

    func setAxFrame(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId) { [axApp] window, job in
            try disableAnimations(app: axApp.threadGuarded, job) {
                try setFrame(window, topLeft, size, job)
            }
        }
    }

    func setAxFrameBlocking(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) async throws {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        try await withWindow(windowId) { [axApp] window, job in
            try disableAnimations(app: axApp.threadGuarded, job) {
                try setFrame(window, topLeft, size, job)
            }
        }
    }

    func getAxWindowsCount() async throws -> Int? {
        try await thread?.runInLoop { [axApp] job in
            axApp.threadGuarded.get(Ax.windowsAttr)?.count
        }
    }

    func getAxRect(_ windowId: UInt32) async throws -> Rect? {
        try await withWindow(windowId) { window, job in
            guard let topLeftCorner = window.get(Ax.topLeftCornerAttr) else { return nil }
            guard let size = window.get(Ax.sizeAttr) else { return nil }
            return Rect(topLeftX: topLeftCorner.x, topLeftY: topLeftCorner.y, width: size.width, height: size.height)
        }
    }

    func isWindowHeuristic(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?) async throws -> Bool {
        return try await withWindow(windowId) { [nsApp, axApp, appId] window, job in
            window.isWindowHeuristic(axApp: axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } == true
    }

    func getAxUiElementWindowType(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?) async throws -> AxUiElementWindowType {
        return try await withWindow(windowId) { [nsApp, axApp, appId] window, job in
            window.getWindowType(axApp: axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } ?? .window
    }

    func isDialogHeuristic(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?) async throws -> Bool {
        try await withWindow(windowId) { [appId] window, job in
            window.isDialogHeuristic(appId, windowLevel)
        } == true
    }

    func setNativeFullscreen(_ windowId: UInt32, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId) { window, job in
            window.set(Ax.isFullscreenAttr, value)
        }
    }

    func setNativeMinimized(_ windowId: UInt32, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId) { window, job in
            window.set(Ax.minimizedAttr, value)
        }
    }

    func dumpWindowAxInfo(windowId: UInt32) async throws -> [String: Json] {
        try await withWindow(windowId) { window, job in
            dumpAxRecursive(window, .window)
        } ?? [:]
    }

    func dumpAppAxInfo() async throws -> [String: Json] {
        try await thread?.runInLoop { [axApp] job in
            dumpAxRecursive(axApp.threadGuarded, .app)
        } ?? [:]
    }

    func getAxTitle(_ windowId: UInt32) async throws -> String? {
        try await withWindow(windowId) { window, job in
            window.get(Ax.titleAttr)
        }
    }

    func isMacosNativeFullscreen(_ windowId: UInt32) async throws -> Bool? {
        try await withWindow(windowId) { window, job in
            window.get(Ax.isFullscreenAttr)
        }
    }

    func isMacosNativeMinimized(_ windowId: UInt32) async throws -> Bool? {
        try await withWindow(windowId) { window, job in
            window.get(Ax.minimizedAttr)
        }
    }

    @MainActor
    static func refreshAllAndGetAliveWindowIds(frontmostAppBundleId: String?) async throws -> [MacApp: AppRefreshResult] {
        for (_, app) in MacApp.allAppsMap { // gc dead apps
            try checkCancellation()
            if app.nsApp.isTerminated {
                await app.destroy()
            }
        }
        // Snapshot once so every app sees a consistent native-tab transition.
        let onScreenWindowIds = currentlyOnScreenWindowIds()
        return try await withThrowingTaskGroup(of: (pid_t, AppRefreshResult).self, returning: [MacApp: AppRefreshResult].self) { group in
            func refreshTheApp(_ nsApp: NSRunningApplication) {
                group.addTask { @Sendable @MainActor in
                    guard let app = try await MacApp.getOrRegister(nsApp) else {
                        return (nsApp.processIdentifier, AppRefreshResult())
                    }
                    return (nsApp.processIdentifier, try await app.refreshAndGetAliveWindowIds(
                        frontmostAppBundleId: frontmostAppBundleId,
                        onScreenWindowIds: onScreenWindowIds,
                    ))
                }
            }
            // Register new apps
            for nsApp in NSWorkspace.shared.runningApplications {
                try checkCancellation()
                if nsApp.activationPolicy == .regular {
                    refreshTheApp(nsApp)
                }
            }
            for (_, app) in MacApp.allAppsMap {
                try checkCancellation()
                // "About this Mac" window, TouchID, and a lot of other utility windows
                // We don't monitor them actively as we do for regular apps, but if a window of one of those utility
                // apps got focused it will end up in allAppsMap
                if app.nsApp.activationPolicy != .regular {
                    refreshTheApp(app.nsApp)
                }
            }
            var result: [MacApp: AppRefreshResult] = [:]
            for try await (pid, refreshResult) in group {
                if let app = MacApp.allAppsMap[pid] {
                    result[app] = refreshResult
                }
            }
            return result
        }
    }

    private func refreshAndGetAliveWindowIds(frontmostAppBundleId: String?, onScreenWindowIds: Set<UInt32>) async throws -> AppRefreshResult {
        if nsApp.isTerminated {
            await destroy()
            return AppRefreshResult()
        }
        guard let thread else { return AppRefreshResult() }
        let result = try await thread.runInLoop {
            [nsApp, windows, axApp, previousOnScreenWindowIds, backgroundTabWindowIds] (job) -> AppRefreshResult in
            var alive: [UInt32: AxWindow] = windows.threadGuarded
            var dead = [UInt32: AxWindow]()
            let axWindows = axApp.threadGuarded.get(Ax.windowsAttr) ?? []
            let axWindowIds = axWindows.map(\.windowId).toSet()
            let currentOnScreen = axWindowIds.intersection(onScreenWindowIds)
            let groups = validatedNativeTabGroups(axWindows.compactMap { window in
                window.ax.nativeTabGroupMember.map {
                    NativeTabGroupMember(signature: $0.signature, windowId: window.windowId, selectedIndex: $0.selectedIndex, tabCount: $0.tabCount)
                }
            })
            let tabState = updateNativeTabState(
                groups: groups,
                windowIds: axWindowIds,
                previousOnScreen: previousOnScreenWindowIds.threadGuarded,
                currentOnScreen: currentOnScreen,
                previousBackgroundTabs: backgroundTabWindowIds.threadGuarded,
            )
            previousOnScreenWindowIds.threadGuarded = currentOnScreen
            backgroundTabWindowIds.threadGuarded = tabState.backgroundTabs

            // Second line of defence against lock screen. See the first line of defence: closedWindowsCache
            // Second and third lines of defence are technically needed only to avoid potential flickering
            if frontmostAppBundleId != lockScreenAppBundleId {
                (alive, dead) = try alive.partition {
                    try job.checkCancellation()
                    return $0.value.ax.containingWindowId() != nil && !tabState.backgroundTabs.contains($0.key)
                }
            }

            for (id, window) in axWindows {
                try job.checkCancellation()
                if tabState.backgroundTabs.contains(id) { continue }
                try alive.getOrRegisterAxWindow(windowId: id, window, nsApp, job)
            }

            windows.threadGuarded = alive
            return AppRefreshResult(aliveWindowIds: Array(alive.keys), deadWindowIds: Array(dead.keys), replacements: tabState.replacements)
        }
        windowsCount = result.aliveWindowIds.count
        for windowId in result.deadWindowIds {
            setFrameJobs.removeValue(forKey: windowId)?.cancel()
        }
        return result
    }

    private func destroy() async {
        _ = await Task { @MainActor [pid] in _ = MacApp.allAppsMap.removeValue(forKey: pid) }.result
        for (_, job) in setFrameJobs {
            job.cancel()
        }
        setFrameJobs = [:]
        thread?.runInLoopAsync { [windows, appAxSubscriptions, axApp] job in
            appAxSubscriptions.destroy() // Destroy AX objects in reverse order of their creation
            windows.destroy()
            axApp.destroy()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        thread = nil // Disallow all future job submissions
    }

    private func withWindow<T>(_ windowId: UInt32, _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> T?) async throws -> T? {
        try await thread?.runInLoop { [windows] job in
            guard let window = windows.threadGuarded[windowId] else { return nil }
            return try body(window.ax, job)
        }
    }

    private func withWindowAsync(_ windowId: UInt32, _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> ()) -> RunLoopJob {
        thread?.runInLoopAsync { [windows] job in
            guard let window = windows.threadGuarded[windowId] else { return }
            try? body(window.ax, job)
        } ?? .cancelled
    }
}

private final class AxWindow {
    let windowId: UInt32
    let ax: AXUIElement
    // periphery:ignore
    private let axSubscriptions: [AxSubscription] // keep subscriptions in memory

    private init(windowId: UInt32, _ ax: AXUIElement, _ axSubscriptions: [AxSubscription]) {
        self.windowId = windowId
        self.ax = ax
        assert(!axSubscriptions.isEmpty)
        self.axSubscriptions = axSubscriptions
    }

    static func new(windowId: UInt32, _ ax: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        let handlers: HandlerToNotifKeyMapping = unsafe [
            (refreshObs, [kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMiniaturizedNotification]),
            (movedObs, [kAXMovedNotification]),
            (resizedObs, [kAXResizedNotification]),
        ]
        let subscriptions = try unsafe AxSubscription.bulkSubscribe(nsApp, ax, job, handlers)
        return !subscriptions.isEmpty ? AxWindow(windowId: windowId, ax, subscriptions) : nil
    }
}

extension [UInt32: AxWindow] {
    @discardableResult
    fileprivate mutating func getOrRegisterAxWindow(windowId id: UInt32, _ axWindow: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        if let existing = self[id] { return existing }
        // Delay new window detection if mouse is down
        // It helps with apps that allow dragging their tabs out to create new windows
        // https://github.com/nikitabobko/AeroSpace/issues/1001
        if isLeftMouseButtonDown { return nil }

        if let window = try AxWindow.new(windowId: id, axWindow, nsApp, job) {
            self[id] = window
            return window
        } else {
            return nil
        }
    }
}

struct AppRefreshResult: Sendable {
    var aliveWindowIds: [UInt32] = []
    var deadWindowIds: [UInt32] = []
    var replacements: [UInt32: UInt32] = [:]
}

struct NativeTabState: Equatable {
    var backgroundTabs: Set<UInt32>
    var replacements: [UInt32: UInt32]
}

struct NativeTabGroupMember: Equatable {
    var signature: String
    var windowId: UInt32
    var selectedIndex: Int
    var tabCount: Int
}

func validatedNativeTabGroups(_ members: [NativeTabGroupMember]) -> [String: Set<UInt32>] {
    Dictionary(grouping: members, by: \.signature).compactMapValues { group in
        guard let tabCount = group.first?.tabCount,
              tabCount > 1,
              group.count == tabCount,
              group.allSatisfy({ $0.tabCount == tabCount }),
              group.map(\.selectedIndex).toSet().count == tabCount
        else {
            return nil
        }
        return group.map(\.windowId).toSet()
    }
}

func updateNativeTabState(
    groups: [String: Set<UInt32>],
    windowIds: Set<UInt32>,
    previousOnScreen: Set<UInt32>,
    currentOnScreen: Set<UInt32>,
    previousBackgroundTabs: Set<UInt32>,
) -> NativeTabState {
    var backgroundTabs = previousBackgroundTabs.intersection(windowIds)
    var replacements: [UInt32: UInt32] = [:]

    // Seed restored/new tab groups. Requiring exactly one on-screen member avoids mistaking a group on an
    // inactive native macOS Space (zero on-screen members) or an ambiguous signature (multiple) for background tabs.
    for ids in groups.values {
        let onScreen = ids.intersection(currentOnScreen)
        if onScreen.count == 1 {
            backgroundTabs.formUnion(ids.subtracting(onScreen))
        }

        let becameOffScreen = ids.intersection(previousOnScreen).subtracting(currentOnScreen)
        let becameOnScreen = ids.intersection(currentOnScreen).subtracting(previousOnScreen)
        if let oldWindowId = becameOffScreen.singleOrNil(), let newWindowId = becameOnScreen.singleOrNil() {
            replacements[oldWindowId] = newWindowId
        }
    }

    // Some apps remove the selected tab's old window id before exposing the next selected tab. Pair the single
    // disappeared selected id with the single previously-background id that became visible.
    let disappearedSelected = previousOnScreen.subtracting(currentOnScreen).subtracting(windowIds)
    let promotedBackground = currentOnScreen.subtracting(previousOnScreen).intersection(previousBackgroundTabs)
    if let oldWindowId = disappearedSelected.singleOrNil(), let newWindowId = promotedBackground.singleOrNil() {
        replacements[oldWindowId] = newWindowId
    }

    for (oldWindowId, newWindowId) in replacements {
        if windowIds.contains(oldWindowId) {
            backgroundTabs.insert(oldWindowId)
        }
        backgroundTabs.remove(newWindowId)
    }
    // A visible tab must never remain excluded, even if an app reports an unexpected transition.
    backgroundTabs.subtract(currentOnScreen)
    return NativeTabState(backgroundTabs: backgroundTabs, replacements: replacements)
}

extension AXUIElement {
    fileprivate var nativeTabGroupMember: (signature: String, selectedIndex: Int, tabCount: Int)? {
        let tabGroups = (get(Ax.childrenAttr) ?? []).filter { $0.get(Ax.roleAttr) == kAXTabGroupRole }
        guard let tabGroup = tabGroups.singleOrNil() else { return nil }
        let tabs = (tabGroup.get(Ax.childrenAttr) ?? []).filter { $0.get(Ax.subroleAttr) == "AXTabButton" }
        guard tabs.count > 1, let selectedIndex = tabs.firstIndex(where: { $0.get(Ax.valueAttr) == true }) else { return nil }
        return (tabs.map { $0.get(Ax.titleAttr) ?? "" }.joined(separator: "\u{0}"), selectedIndex, tabs.count)
    }
}

private func setFrame(_ window: AXUIElement, _ topLeft: CGPoint?, _ size: CGSize?, _ job: RunLoopJob) throws {
    // Set size and then the position. The order is important https://github.com/nikitabobko/AeroSpace/issues/143
    //                                                        https://github.com/nikitabobko/AeroSpace/issues/335
    if let size { window.set(Ax.sizeAttr, size) }
    try job.checkCancellation()
    if let topLeft { window.set(Ax.topLeftCornerAttr, topLeft) } else { return }
    try job.checkCancellation()
    if let size { window.set(Ax.sizeAttr, size) }
}

// Some undocumented magic
// References: https://github.com/koekeishiya/yabai/commit/3fe4c77b001e1a4f613c26f01ea68c0f09327f3a
//             https://github.com/rxhanson/Rectangle/pull/285
private func disableAnimations<T>(app: AXUIElement, _ job: RunLoopJob, _ body: () throws -> T) throws -> T {
    let wasEnabled = app.get(Ax.enhancedUserInterfaceAttr) == true
    if wasEnabled {
        app.set(Ax.enhancedUserInterfaceAttr, false)
    }
    defer {
        if wasEnabled {
            app.set(Ax.enhancedUserInterfaceAttr, true)
        }
    }
    try job.checkCancellation()
    return try body()
}
