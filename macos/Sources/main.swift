import AppKit
import Combine
import SwiftUI
import UserNotifications

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
    private var titleObservation: AnyCancellable?
    private var progressObservation: AnyCancellable?

    init(window: NSWindow, kind: Kind) {
        self.kind = kind
        super.init(window: window)
        window.delegate = self
        if case .terminal(let model) = kind {
            titleObservation = model.$title.sink { [weak window] title in
                window?.title = title
            }
            progressObservation = model.$progress.sink { [weak self] _ in
                self?.progressChanged?()
            }
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

    func windowDidBecomeKey(_ notification: Notification) {
        progressChanged?()
    }

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
final class Delegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let preferences = Preferences()
    private var terminalWindows: [NSWindow: ManagedWindowController] = [:]
    private var settingsController: ManagedWindowController?
    private var dockProgressView: DockProgressView?
    private var dockProgressTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        NotificationCenter.default.addObserver(
            self, selector: #selector(showDesktopNotification(_:)),
            name: .terminalDesktopNotification, object: nil)
        buildMenu()
        newWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockProgressTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func showDesktopNotification(_ notification: Notification) {
        guard terminalWindows.keys.allSatisfy({ !$0.isKeyWindow }),
              let title = notification.userInfo?["title"] as? String,
              let body = notification.userInfo?["body"] as? String else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Zigonaut" : title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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

    private func makeTerminalWindow() -> ManagedWindowController {
        let model = WindowModel(preferences: preferences)
        let font = preferences.terminalFont(size: preferences.fontSize)
        let cellWidth = ceil(("M" as NSString).size(withAttributes: [.font: font]).width)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let contentSize = NSSize(
            width: max(320, CGFloat(preferences.initialColumns) * cellWidth + 2 * preferences.paddingHorizontal),
            height: max(180, CGFloat(preferences.initialRows) * lineHeight + 2 * preferences.paddingVertical)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.title
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.tabbingIdentifier = "dev.zigonaut.terminal"
        window.tabbingMode = .preferred
        window.setFrameAutosaveName("ZigonautTerminalWindow")
        window.contentView = NSHostingView(rootView: ContentView(window: model))
        let controller = ManagedWindowController(window: window, kind: .terminal(model))
        controller.didClose = { [weak self] window in
            self?.terminalWindows.removeValue(forKey: window)
            self?.updateDockProgress()
        }
        controller.addTab = { [weak self] window in self?.addTab(to: window) }
        controller.progressChanged = { [weak self] in self?.updateDockProgress() }
        terminalWindows[window] = controller
        updateDockProgress()
        return controller
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
    @objc func focusNext(_ sender: Any?) { current?.focus(1) }
    @objc func focusPrevious(_ sender: Any?) { current?.focus(-1) }

    @objc func closePane(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        guard let model = current else {
            window.performClose(sender)
            return
        }
        if !model.closeFocused() {
            window.performClose(sender)
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
        file.addItem(item("Close Pane or Tab", #selector(closePane), "w"))
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
        view.addItem(item("Focus Right/Down", #selector(focusNext), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.control, .option]))
        view.addItem(item("Focus Left/Up", #selector(focusPrevious), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.control, .option]))
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
        case #selector(splitRight), #selector(splitDown), #selector(find),
             #selector(focusNext), #selector(focusPrevious):
            return current != nil
        case #selector(findNext), #selector(findPrevious):
            return current?.findVisible == true && !(current?.findQuery.isEmpty ?? true)
        case #selector(previousPrompt), #selector(nextPrompt), #selector(copyCommandOutput):
            return current?.focused != nil
        case #selector(nextTab), #selector(previousTab):
            return (NSApp.keyWindow?.tabbedWindows?.count ?? 0) > 1
        case #selector(closePane):
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
