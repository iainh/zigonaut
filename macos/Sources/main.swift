import AppKit
import Combine
import SwiftUI
@preconcurrency import UserNotifications
import ZigonautPaneLayout
import ZigonautRestoration

private extension NSView {
    func firstDescendant(named className: String) -> NSView? {
        if NSStringFromClass(type(of: self)).hasSuffix(className) { return self }
        for subview in subviews {
            if let match = subview.firstDescendant(named: className) { return match }
        }
        return nil
    }
}

private final class TerminalWindow: NSWindow {
    var terminalBackgroundColor: (() -> NSColor?)?

    func updateTitlebarColor() {
        guard let color = terminalBackgroundColor?() else { return }
        backgroundColor = color
        titlebarAppearsTransparent = true

        guard let frameView = contentView?.superview,
              let container = frameView.firstDescendant(named: "NSTitlebarContainerView") else { return }
        let target = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
            ? container.firstDescendant(named: "NSTitlebarView") ?? container
            : container
        target.wantsLayer = true
        target.layer?.backgroundColor = color.cgColor
    }

    override func update() {
        super.update()
        updateTitlebarColor()
    }
}

@MainActor
final class ManagedWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    enum Kind {
        case terminal(WindowModel)
        case settings(SettingsModel)
    }

    let kind: Kind
    var didClose: ((NSWindow) -> Void)?
    var addTab: ((NSWindow) -> Void)?
    var progressChanged: (() -> Void)?
    var stateChanged: (() -> Void)?
    var shouldClose: ((NSWindow) -> Bool)?
    private var titleObservation: AnyCancellable?
    private var progressObservation: AnyCancellable?
    private var activityObservation: AnyCancellable?
    private var backgroundObservations = Set<AnyCancellable>()
    private var terminalTitle = "Terminal"
    private var hasUnreadOutput = false

    init(window: NSWindow, kind: Kind) {
        self.kind = kind
        super.init(window: window)
        window.delegate = self
        if case .terminal(let model) = kind {
            terminalTitle = model.title
            titleObservation = model.$title.sink { [weak self] title in
                self?.terminalTitle = title
                self?.updateTerminalTitle()
            }
            progressObservation = model.$progress.sink { [weak self] _ in
                self?.progressChanged?()
            }
            activityObservation = model.$outputGeneration.dropFirst().sink { [weak self, weak window] _ in
                guard let self, let window else { return }
                let selected = window.tabGroup?.selectedWindow ?? window
                guard selected !== window else { return }
                self.hasUnreadOutput = true
                self.updateTerminalTitle()
                window.setAccessibilityHelp("New terminal output")
            }
            model.$focusedPane.sink { [weak window] _ in
                (window as? TerminalWindow)?.updateTitlebarColor()
            }.store(in: &backgroundObservations)
            model.preferences.objectWillChange.sink { [weak window] _ in
                DispatchQueue.main.async {
                    (window as? TerminalWindow)?.updateTitlebarColor()
                }
            }.store(in: &backgroundObservations)
        } else if case .settings(let model) = kind {
            configureSettingsToolbar(model)
            titleObservation = model.$pane.sink { [weak self, weak window] pane in
                window?.title = pane.title
                // Let NSToolbar complete its native selection tracking before
                // changing window geometry. The toolbar selects clicked items
                // automatically via toolbarSelectableItemIdentifiers(_:).
                DispatchQueue.main.async { [weak self] in
                    self?.resizeSettingsWindow(to: pane.contentSize)
                }
            }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        didClose?(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldClose?(sender) ?? true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            clearActivityIfSelected(window)
        }
        progressChanged?()
        stateChanged?()
    }

    func windowDidUpdate(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        clearActivityIfSelected(window)
    }

    private func clearActivityIfSelected(_ window: NSWindow) {
        let selected = window.tabGroup?.selectedWindow ?? window
        guard selected === window, hasUnreadOutput else { return }
        hasUnreadOutput = false
        updateTerminalTitle()
        window.setAccessibilityHelp(nil)
    }

    private func updateTerminalTitle() {
        guard let window, case .terminal = kind else { return }
        window.title = hasUnreadOutput ? "● \(terminalTitle)" : terminalTitle
    }

    func windowDidMove(_ notification: Notification) { stateChanged?() }
    func windowDidResize(_ notification: Notification) { stateChanged?() }

    override func newWindowForTab(_ sender: Any?) {
        guard case .terminal = kind, let window else { return }
        addTab?(window)
    }

    private func configureSettingsToolbar(_ model: SettingsModel) {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "ZigonautSettingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(model.pane.rawValue)
        window.toolbar = toolbar
        window.toolbarStyle = .preference
    }

    private func resizeSettingsWindow(to size: NSSize) {
        guard let window else { return }
        let oldFrame = window.frame
        let newSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        guard oldFrame.size != newSize else { return }
        let frame = NSRect(x: oldFrame.minX, y: oldFrame.maxY - newSize.height,
            width: newSize.width, height: newSize.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    @objc private func selectSettingsPane(_ sender: NSToolbarItem) {
        guard case .settings(let model) = kind,
              let pane = SettingsPane(rawValue: sender.itemIdentifier.rawValue) else { return }
        model.pane = pane
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.toolTip = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectSettingsPane(_:))
        return item
    }
}

@MainActor
private final class DockProgressView: NSView {
    private let icon = NSImageView()
    private let indicator = NSProgressIndicator()
    private let stateMarker = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        indicator.style = .bar
        indicator.minValue = 0
        indicator.maxValue = 100
        stateMarker.wantsLayer = true
        addSubview(icon)
        addSubview(indicator)
        addSubview(stateMarker)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        icon.frame = bounds
        stateMarker.frame = NSRect(x: 10, y: 10, width: 8, height: 8)
        stateMarker.layer?.cornerRadius = 4
        indicator.frame = NSRect(x: 20, y: 8, width: max(1, bounds.width - 30), height: 12)
    }

    func update(_ progress: TerminalProgress) {
        indicator.stopAnimation(nil)
        indicator.isIndeterminate = progress.state == .indeterminate
        indicator.doubleValue = Double(progress.value)
        switch progress.state {
        case .normal, .indeterminate: stateMarker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        case .error: stateMarker.layer?.backgroundColor = NSColor.systemRed.cgColor
        case .paused: stateMarker.layer?.backgroundColor = NSColor.systemYellow.cgColor
        }
        if indicator.isIndeterminate { indicator.startAnimation(nil) }
    }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate, NSMenuItemValidation,
                     UNUserNotificationCenterDelegate {
    private final class NotificationCompletion: @unchecked Sendable {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
    }

    nonisolated private static let notificationPaneKey = "paneID"
    let preferences = Preferences()
    private var terminalWindows: [NSWindow: ManagedWindowController] = [:]
    private var settingsController: ManagedWindowController?
    private var dockProgressView: DockProgressView?
    private var dockProgressTimer: Timer?
    private var saveWorkItem: DispatchWorkItem?
    private var confirmedWindows = Set<ObjectIdentifier>()
    private var pendingWindows = Set<ObjectIdentifier>()
    private var pendingPanes = Set<UUID>()
    private var quitConfirmationPending = false
    private var quitConfirmed = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        NotificationCenter.default.addObserver(
            self, selector: #selector(showDesktopNotification(_:)),
            name: .terminalDesktopNotification, object: nil)
        buildMenu()
        if !restoreWindows() { newWindow(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveState()
        dockProgressTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func showDesktopNotification(_ notification: Notification) {
        guard terminalWindows.keys.allSatisfy({ !$0.isKeyWindow }),
              let pane = notification.object as? TerminalModel,
              let title = notification.userInfo?["title"] as? String,
              let body = notification.userInfo?["body"] as? String else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Zigonaut" : title
        content.body = body
        content.userInfo[Self.notificationPaneKey] = pane.id.uuidString
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        let paneValue = request.content.userInfo[Self.notificationPaneKey] as? String
        let paneID = paneValue.flatMap(UUID.init(uuidString:))
          ?? UUID(uuidString: request.identifier)
        let completion = NotificationCompletion(completionHandler)
        Task { @MainActor [weak self] in
            self?.activate(pane: paneID)
            center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
            completion.handler()
        }
    }

    private func activate(pane paneID: UUID?) {
        NSApp.activate(ignoringOtherApps: true)
        guard let paneID,
              let match = terminalWindows.first(where: { _, controller in
                  guard case .terminal(let model) = controller.kind else { return false }
                  return model.panes.contains { $0.id == paneID }
              }) else { return }
        let (window, controller) = match
        guard case .terminal(let model) = controller.kind else { return }
        model.focusedPane = paneID
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.tabGroup?.selectedWindow = window
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitConfirmed { return .terminateNow }
        if quitConfirmationPending { return .terminateLater }
        let jobs = terminalWindows.values.reduce(0) { count, controller in
            guard case .terminal(let model) = controller.kind else { return count }
            return count + model.foregroundJobCount
        }
        guard jobs > 0 else { return .terminateNow }
        quitConfirmationPending = true
        presentCloseAlert(jobCount: jobs, action: "Quit", window: NSApp.keyWindow) { [weak self] confirmed in
            guard let self else { return }
            self.quitConfirmationPending = false
            self.quitConfirmed = confirmed
            sender.reply(toApplicationShouldTerminate: confirmed)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !terminalWindows.keys.contains(where: \.isVisible) {
            newWindow(nil)
        }
        return true
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = makeTerminalWindow()
        guard let window = controller.window else { return }
        if !window.setFrameUsingName("ZigonautTerminalWindow") { window.center() }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeTerminalWindow(saved: SavedTab? = nil) -> ManagedWindowController {
        let model = saved.map { WindowModel(saved: $0, preferences: preferences) }
          ?? WindowModel(preferences: preferences)
        let font = preferences.terminalFont(size: preferences.fontSize)
        let cellWidth = ceil(("M" as NSString).size(withAttributes: [.font: font]).width)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let contentSize = NSSize(
            width: max(320, CGFloat(preferences.initialColumns) * cellWidth + 2 * preferences.paddingHorizontal),
            height: max(180, CGFloat(preferences.initialRows) * lineHeight + 2 * preferences.paddingVertical)
        )
        let window = TerminalWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.terminalBackgroundColor = { [weak window, weak model] in
            guard let window, let model else { return nil }
            let dark = switch model.preferences.colourScheme {
            case "Dark": true
            case "Light": false
            default: window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }
            let pane = model.focused ?? model.panes.first
            return pane.map {
                NSColor(rgb: model.preferences.terminalPalette(dark: dark, seed: $0.themeSeed).background)
            }
        }
        window.title = model.title
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .none
        window.tabbingIdentifier = "dev.zigonaut.terminal"
        window.tabbingMode = .preferred
        window.setFrameAutosaveName("ZigonautTerminalWindow")
        window.contentView = NSHostingView(rootView: ContentView(window: model))
        window.updateTitlebarColor()
        let controller = ManagedWindowController(window: window, kind: .terminal(model))
        controller.didClose = { [weak self] window in
            self?.terminalWindows.removeValue(forKey: window)
            self?.updateDockProgress()
            self?.scheduleSave()
        }
        controller.addTab = { [weak self] window in self?.addTab(to: window) }
        controller.progressChanged = { [weak self] in self?.updateDockProgress() }
        controller.stateChanged = { [weak self] in self?.scheduleSave() }
        controller.shouldClose = { [weak self] window in self?.shouldClose(window) ?? true }
        model.stateChanged = { [weak self] in self?.scheduleSave() }
        terminalWindows[window] = controller
        updateDockProgress()
        return controller
    }

    private func restoreWindows() -> Bool {
        guard let state = RestorationStore.load() else { return false }
        var restored = false
        for group in state.groups {
            var windows: [NSWindow] = []
            for tab in group.tabs {
                let controller = makeTerminalWindow(saved: tab)
                if let window = controller.window { windows.append(window) }
            }
            guard let first = windows.first else { continue }
            let frame = NSRectFromString(group.frame)
            if frame.width >= 320, frame.height >= 180 {
                let bestScreen = NSScreen.screens.max {
                    let first = $0.visibleFrame.intersection(frame)
                    let second = $1.visibleFrame.intersection(frame)
                    return first.width * first.height < second.width * second.height
                }
                let overlap = bestScreen?.visibleFrame.intersection(frame) ?? .zero
                let screen = overlap.width * overlap.height > 0 ? bestScreen : NSScreen.main
                if let screen {
                    first.setFrame(first.constrainFrameRect(frame, to: screen), display: false)
                } else {
                    first.setFrame(frame, display: false)
                }
            } else if !first.setFrameUsingName("ZigonautTerminalWindow") { first.center() }
            for window in windows.dropFirst() { first.addTabbedWindow(window, ordered: .above) }
            let selected = windows[min(group.selectedTab, windows.count - 1)]
            selected.makeKeyAndOrderFront(nil)
            restored = true
        }
        return restored
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveState() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: item)
    }

    private func saveState() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        var seen = Set<ObjectIdentifier>()
        var groups: [SavedWindowGroup] = []
        for candidate in NSApp.orderedWindows where terminalWindows[candidate] != nil {
            let tabs = candidate.tabbedWindows ?? [candidate]
            guard let first = tabs.first else { continue }
            let identities = tabs.map(ObjectIdentifier.init)
            guard identities.allSatisfy({ !seen.contains($0) }) else { continue }
            let savedWindows = tabs.compactMap { window -> (NSWindow, SavedTab)? in
                guard let controller = terminalWindows[window],
                  case .terminal(let model) = controller.kind else { return nil }
                return (window, model.saved)
            }
            guard !savedWindows.isEmpty else { continue }
            let selectedWindow = candidate.tabGroup?.selectedWindow ?? candidate
            let selected = savedWindows.firstIndex { $0.0 === selectedWindow } ?? 0
            groups.append(SavedWindowGroup(frame: NSStringFromRect(first.frame),
              tabs: savedWindows.map(\.1),
              selectedTab: selected))
            seen.formUnion(identities)
        }
        guard !groups.isEmpty else {
            RestorationStore.clear()
            return
        }
        RestorationStore.save(SavedApplication(groups: groups))
    }

    private func updateDockProgress() {
        dockProgressTimer?.invalidate()
        let keyProgress = NSApp.keyWindow.flatMap { window -> TerminalProgress? in
            guard let controller = terminalWindows[window], case .terminal(let model) = controller.kind else {
                return nil
            }
            return model.progress
        }
        let fallback = NSApp.orderedWindows.lazy.compactMap { window -> TerminalProgress? in
            guard window.isVisible, let controller = self.terminalWindows[window],
                  case .terminal(let model) = controller.kind else { return nil }
            return model.progress
        }.first
        guard let progress = keyProgress ?? fallback,
              Date().timeIntervalSince(progress.updatedAt) < 15 else {
            NSApp.dockTile.contentView = nil
            dockProgressView = nil
            NSApp.dockTile.display()
            return
        }
        let view = dockProgressView ?? DockProgressView(
            frame: NSRect(origin: .zero, size: NSApp.dockTile.size))
        dockProgressView = view
        view.frame.size = NSApp.dockTile.size
        view.update(progress)
        NSApp.dockTile.contentView = view
        NSApp.dockTile.display()
        let remaining = max(0.05, 15 - Date().timeIntervalSince(progress.updatedAt))
        dockProgressTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) {
            [weak self] _ in Task { @MainActor in self?.updateDockProgress() }
        }
    }

    private var current: WindowModel? {
        guard let window = NSApp.keyWindow,
              let controller = terminalWindows[window],
              case .terminal(let model) = controller.kind else { return nil }
        return model
    }

    /// AppKit's native tab-bar add button dispatches this standard action.
    @objc func newWindowForTab(_ sender: Any?) {
        let host = NSApp.keyWindow.flatMap { terminalWindows[$0] == nil ? nil : $0 }
          ?? NSApp.orderedWindows.first { terminalWindows[$0] != nil }
        guard let host else {
            newWindow(sender)
            return
        }
        addTab(to: host)
    }

    private func addTab(to currentWindow: NSWindow) {
        let controller = makeTerminalWindow()
        guard let window = controller.window else { return }
        currentWindow.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
    @objc func splitRight(_ sender: Any?) { current?.split(.horizontal) }
    @objc func splitDown(_ sender: Any?) { current?.split(.vertical) }
    @objc func find(_ sender: Any?) { current?.showFind() }
    @objc func findNext(_ sender: Any?) { current?.navigateSearch(forward: true) }
    @objc func findPrevious(_ sender: Any?) { current?.navigateSearch(forward: false) }
    @objc func previousPrompt(_ sender: Any?) { current?.focused?.navigatePrompt(forward: false) }
    @objc func nextPrompt(_ sender: Any?) { current?.focused?.navigatePrompt(forward: true) }
    @objc func copyCommandOutput(_ sender: Any?) { current?.focused?.copyLastCommandOutput() }
    @objc func nextTab(_ sender: Any?) { NSApp.keyWindow?.selectNextTab(sender) }
    @objc func previousTab(_ sender: Any?) { NSApp.keyWindow?.selectPreviousTab(sender) }
    @objc func focusLeft(_ sender: Any?) { current?.focus(.left) }
    @objc func focusRight(_ sender: Any?) { current?.focus(.right) }
    @objc func focusUp(_ sender: Any?) { current?.focus(.up) }
    @objc func focusDown(_ sender: Any?) { current?.focus(.down) }
    @objc func focusPreviousPane(_ sender: Any?) { current?.focusCycle(forward: false) }
    @objc func focusNextPane(_ sender: Any?) { current?.focusCycle(forward: true) }
    @objc func resizePaneLeft(_ sender: Any?) { current?.resize(.left) }
    @objc func resizePaneRight(_ sender: Any?) { current?.resize(.right) }
    @objc func resizePaneUp(_ sender: Any?) { current?.resize(.up) }
    @objc func resizePaneDown(_ sender: Any?) { current?.resize(.down) }
    @objc func equalizePanes(_ sender: Any?) { current?.equalizePanes() }
    @objc func togglePaneZoom(_ sender: Any?) { current?.togglePaneZoom() }

    @objc func closePane(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        guard let model = current else {
            window.performClose(sender)
            return
        }
        guard let pane = model.focused else { return }
        guard !pendingPanes.contains(pane.id) else { return }
        let close = { [weak self, weak model, weak window] in
            guard let model else { return }
            if !model.closePane(pane.id), let window {
                self?.confirmedWindows.insert(ObjectIdentifier(window))
                window.performClose(sender)
            }
        }
        guard pane.hasForegroundJob else { close(); return }
        pendingPanes.insert(pane.id)
        presentCloseAlert(jobCount: 1, action: "Close Terminal", window: window) {
            self.pendingPanes.remove(pane.id)
            if $0 { close() }
        }
    }

    private func shouldClose(_ window: NSWindow) -> Bool {
        if quitConfirmed { return true }
        let identity = ObjectIdentifier(window)
        if confirmedWindows.remove(identity) != nil { return true }
        if pendingWindows.contains(identity) { return false }
        guard let controller = terminalWindows[window], case .terminal(let model) = controller.kind else {
            return true
        }
        let jobs = model.foregroundJobCount
        guard jobs > 0 else { return true }
        pendingWindows.insert(identity)
        presentCloseAlert(jobCount: jobs, action: "Close Terminal", window: window) { [weak self, weak window] confirmed in
            guard let self else { return }
            self.pendingWindows.remove(identity)
            guard confirmed, let window else { return }
            self.confirmedWindows.insert(ObjectIdentifier(window))
            window.performClose(nil)
        }
        return false
    }

    private func presentCloseAlert(jobCount: Int, action: String, window: NSWindow?,
                                   completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = action == "Quit" ? "Quit Zigonaut?" : "Close Terminal?"
        alert.informativeText = jobCount == 1
          ? "A foreground job is still running. Closing the terminal will terminate it."
          : "\(jobCount) foreground jobs are still running. Closing these terminals will terminate them."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
        alert.buttons[1].hasDestructiveAction = true
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { completion($0 == .alertSecondButtonReturn) }
        } else {
            completion(alert.runModal() == .alertSecondButtonReturn)
        }
    }

    @objc func settings(_ sender: Any?) {
        if let controller = settingsController, let window = controller.window {
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = SettingsModel()
        let hosting = NSHostingController(rootView: SettingsView(preferences: preferences, model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = model.pane.title
        window.styleMask = [.titled, .closable]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        let controller = ManagedWindowController(window: window, kind: .settings(model))
        settingsController = controller
        window.center()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func zoomIn(_ sender: Any?) { preferences.fontSize = min(32, preferences.fontSize + 1) }
    @objc func zoomOut(_ sender: Any?) { preferences.fontSize = max(9, preferences.fontSize - 1) }
    @objc func zoomReset(_ sender: Any?) { preferences.fontSize = 14 }

    func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    func buildMenu() {
        let bar = NSMenu()
        NSApp.mainMenu = bar
        func menu(_ title: String) -> NSMenu {
            let root = NSMenuItem()
            bar.addItem(root)
            let menu = NSMenu(title: title)
            root.submenu = menu
            return menu
        }
        let app = menu("Zigonaut")
        app.addItem(item("About Zigonaut", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(settings), ","))
        app.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let services = NSMenu(title: "Services")
        servicesItem.submenu = services
        app.addItem(servicesItem)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(item("Hide Zigonaut", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""))
        app.addItem(.separator())
        app.addItem(item("Quit Zigonaut", #selector(NSApplication.terminate(_:)), "q"))
        let file = menu("File")
        file.addItem(item("New Tab", #selector(newWindowForTab), "t"))
        file.addItem(item("New Window", #selector(newWindow), "n"))
        file.addItem(item("Split Right", #selector(splitRight), "o", [.control, .shift]))
        file.addItem(item("Split Down", #selector(splitDown), "e", [.control, .shift]))
        file.addItem(item("Close", #selector(closePane), "w"))
        let edit = menu("Edit")
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(.separator())
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(item("Find…", #selector(find), "f"))
        findMenu.addItem(item("Find Next", #selector(findNext), "g"))
        findMenu.addItem(item("Find Previous", #selector(findPrevious), "g", [.command, .shift]))
        findItem.submenu = findMenu
        edit.addItem(findItem)
        edit.addItem(.separator())
        edit.addItem(item("Previous Prompt", #selector(previousPrompt), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.control, .shift]))
        edit.addItem(item("Next Prompt", #selector(nextPrompt), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.control, .shift]))
        edit.addItem(item("Copy or Pipe Last Command Output", #selector(copyCommandOutput), "g", [.control, .shift]))
        let view = menu("View")
        view.addItem(item("Zoom In", #selector(zoomIn), "+"))
        view.addItem(item("Zoom Out", #selector(zoomOut), "-"))
        view.addItem(item("Actual Size", #selector(zoomReset), "0"))
        view.addItem(item("Next Tab", #selector(nextTab), "}", [.command, .shift]))
        view.addItem(item("Previous Tab", #selector(previousTab), "{", [.command, .shift]))
        view.addItem(item("Focus Left", #selector(focusLeft), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.control, .option]))
        view.addItem(item("Focus Right", #selector(focusRight), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.control, .option]))
        view.addItem(item("Focus Up", #selector(focusUp), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.control, .option]))
        view.addItem(item("Focus Down", #selector(focusDown), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.control, .option]))
        view.addItem(item("Focus Previous Pane", #selector(focusPreviousPane), String(UnicodeScalar(NSPageUpFunctionKey)!), [.control, .option]))
        view.addItem(item("Focus Next Pane", #selector(focusNextPane), String(UnicodeScalar(NSPageDownFunctionKey)!), [.control, .option]))
        view.addItem(.separator())
        view.addItem(item("Resize Panes Left", #selector(resizePaneLeft), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.control, .option, .shift]))
        view.addItem(item("Resize Panes Right", #selector(resizePaneRight), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.control, .option, .shift]))
        view.addItem(item("Resize Panes Up", #selector(resizePaneUp), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.control, .option, .shift]))
        view.addItem(item("Resize Panes Down", #selector(resizePaneDown), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.control, .option, .shift]))
        view.addItem(item("Equalize Panes", #selector(equalizePanes), "=", [.control, .option]))
        view.addItem(item("Toggle Pane Zoom", #selector(togglePaneZoom), "\r", [.control, .shift]))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        let window = menu("Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        window.addItem(.separator())
        window.addItem(item("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:)), ""))
        window.addItem(item("Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""))
        NSApp.windowsMenu = window
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(NSText.copy(_:)):
            return current?.focused?.hasSelection == true
        case #selector(NSText.paste(_:)):
            return current?.focused?.acceptsPaste == true
                && !(NSPasteboard.general.string(forType: .string)?.isEmpty ?? true)
        case #selector(splitRight), #selector(splitDown), #selector(find):
            return current != nil
        case #selector(focusLeft): return current?.canFocus(.left) == true
        case #selector(focusRight): return current?.canFocus(.right) == true
        case #selector(focusUp): return current?.canFocus(.up) == true
        case #selector(focusDown): return current?.canFocus(.down) == true
        case #selector(focusPreviousPane), #selector(focusNextPane),
          #selector(equalizePanes), #selector(togglePaneZoom):
            return (current?.panes.count ?? 0) > 1
        case #selector(resizePaneLeft): return current?.canResize(.left) == true
        case #selector(resizePaneRight): return current?.canResize(.right) == true
        case #selector(resizePaneUp): return current?.canResize(.up) == true
        case #selector(resizePaneDown): return current?.canResize(.down) == true
        case #selector(findNext), #selector(findPrevious):
            return current?.findVisible == true && !(current?.findQuery.isEmpty ?? true)
                && (current?.focused?.searchMatchCount ?? 0) > 0
        case #selector(previousPrompt), #selector(nextPrompt), #selector(copyCommandOutput):
            return current?.focused != nil
        case #selector(nextTab), #selector(previousTab):
            return (NSApp.keyWindow?.tabbedWindows?.count ?? 0) > 1
        case #selector(closePane):
            if let model = current {
                menuItem.title = model.panes.count > 1 ? "Close Pane"
                    : (NSApp.keyWindow?.tabbedWindows?.count ?? 0) > 1 ? "Close Tab" : "Close Window"
            } else {
                menuItem.title = "Close Window"
            }
            return NSApp.keyWindow != nil
        default:
            return true
        }
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
