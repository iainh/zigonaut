import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class ManagedWindowController: NSWindowController, NSWindowDelegate {
    enum Kind {
        case terminal(WindowModel)
        case settings
    }

    let kind: Kind
    var didClose: ((NSWindow) -> Void)?
    private var titleObservation: AnyCancellable?

    init(window: NSWindow, kind: Kind) {
        self.kind = kind
        super.init(window: window)
        window.delegate = self
        if case .terminal(let model) = kind {
            titleObservation = model.$title.sink { [weak window] title in
                window?.title = title
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
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    private var terminalWindows: [NSWindow: ManagedWindowController] = [:]
    private var settingsWindows: [NSWindow: ManagedWindowController] = [:]

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
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func showDesktopNotification(_ notification: Notification) {
        guard NSApp.keyWindow == nil,
              let title = notification.userInfo?["title"] as? String,
              let body = notification.userInfo?["body"] as? String else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Zigonaut" : title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = makeTerminalWindow()
        guard let window = controller.window else { return }
        window.center()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeTerminalWindow() -> ManagedWindowController {
        let model = WindowModel(preferences: preferences)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.title
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.tabbingIdentifier = "dev.zigonaut.terminal"
        window.tabbingMode = .preferred
        window.contentView = NSHostingView(rootView: ContentView(window: model))
        let controller = ManagedWindowController(window: window, kind: .terminal(model))
        controller.didClose = { [weak self] window in self?.terminalWindows.removeValue(forKey: window) }
        terminalWindows[window] = controller
        return controller
    }

    private var current: WindowModel? {
        guard let window = NSApp.keyWindow,
              let controller = terminalWindows[window],
              case .terminal(let model) = controller.kind else { return nil }
        return model
    }

    /// AppKit's native tab-bar add button dispatches this standard action.
    @objc func newWindowForTab(_ sender: Any?) {
        guard let currentWindow = NSApp.keyWindow, terminalWindows[currentWindow] != nil else {
            newWindow(sender)
            return
        }
        let controller = makeTerminalWindow()
        guard let window = controller.window else { return }
        currentWindow.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
    @objc func splitRight(_ sender: Any?) { current?.split(.horizontal) }
    @objc func splitDown(_ sender: Any?) { current?.split(.vertical) }
    @objc func find(_ sender: Any?) { current?.findVisible = true }
    @objc func nextTab(_ sender: Any?) { NSApp.keyWindow?.selectNextTab(sender) }
    @objc func previousTab(_ sender: Any?) { NSApp.keyWindow?.selectPreviousTab(sender) }
    @objc func focusNext(_ sender: Any?) { current?.focus(1) }
    @objc func focusPrevious(_ sender: Any?) { current?.focus(-1) }

    @objc func closePane(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        if settingsWindows[window] != nil {
            window.performClose(sender)
            return
        }
        if current?.closeFocused() == false {
            window.performClose(sender)
        }
    }

    @objc func settings(_ sender: Any?) {
        let hosting = NSHostingController(rootView: SettingsView(preferences: preferences))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        let controller = ManagedWindowController(window: window, kind: .settings)
        controller.didClose = { [weak self] window in self?.settingsWindows.removeValue(forKey: window) }
        settingsWindows[window] = controller
        window.center()
        controller.showWindow(nil)
        window.makeKey()
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
        app.addItem(item("Settings…", #selector(settings), ","))
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
        edit.addItem(item("Find…", #selector(find), "f"))
        let view = menu("View")
        view.addItem(item("Zoom In", #selector(zoomIn), "+"))
        view.addItem(item("Zoom Out", #selector(zoomOut), "-"))
        view.addItem(item("Actual Size", #selector(zoomReset), "0"))
        view.addItem(item("Next Tab", #selector(nextTab), "}", [.command, .shift]))
        view.addItem(item("Previous Tab", #selector(previousTab), "{", [.command, .shift]))
        view.addItem(item("Focus Right/Down", #selector(focusNext), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.control, .option]))
        view.addItem(item("Focus Left/Up", #selector(focusPrevious), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.control, .option]))
        let window = menu("Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(.separator())
        window.addItem(item("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:)), ""))
        window.addItem(item("Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]))
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
