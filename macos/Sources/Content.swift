import AppKit
import SwiftUI

struct PaneView: View {
  let node: PaneNode
  @ObservedObject var window: WindowModel

  var body: some View {
    switch node {
    case .leaf(let pane):
      TerminalSurface(
        model: pane,
        preferences: window.preferences,
        focused: window.focusedPane == pane.id
      ) {
        window.focusedPane = pane.id
      }
      .id(pane.id)
    case .split(_, let axis, let first, let second):
      if axis == .horizontal {
        HSplitView {
          PaneView(node: first, window: window)
          PaneView(node: second, window: window)
        }
      } else {
        VSplitView {
          PaneView(node: first, window: window)
          PaneView(node: second, window: window)
        }
      }
    }
  }
}

struct ContentView: View {
  @ObservedObject var window: WindowModel
  @ObservedObject private var preferences: Preferences

  init(window: WindowModel) {
    self.window = window
    preferences = window.preferences
  }

  var body: some View {
    VStack(spacing: 0) {
      if window.findVisible {
        if let terminal = window.focused {
          FindBar(window: window, terminal: terminal)
        }
      }
      PaneView(node: window.root, window: window)
    }
    .preferredColorScheme(colourScheme)
    .onExitCommand {
      closeFind()
    }
  }

  private var colourScheme: ColorScheme? {
    switch preferences.colourScheme {
    case "Dark": return .dark
    case "Light": return .light
    default: return nil
    }
  }

  private func closeFind() {
    guard window.findVisible else { return }
    window.findVisible = false
  }
}

private struct FindBar: View {
  @ObservedObject var window: WindowModel
  @ObservedObject var terminal: TerminalModel
  var body: some View {
    HStack {
      TextField("Find in scrollback", text: Binding(
        get: { window.findQuery }, set: { window.updateFindQuery($0) }))
        .textFieldStyle(.roundedBorder)
        .onSubmit { terminal.navigateSearch(forward: true) }
      Text(description)
      Button("‹") { terminal.navigateSearch(forward: false) }.disabled(terminal.searchMatchCount == 0)
      Button("›") { terminal.navigateSearch(forward: true) }.disabled(terminal.searchMatchCount == 0)
      Button("Done") { window.findVisible = false }
    }
    .padding(6)
    .background(.bar)
  }
  private var description: String {
    if terminal.searchError { return "Query too long" }
    guard terminal.searchMatchCount > 0 else { return "No matches" }
    let active = min((terminal.searchActiveIndex ?? -1) + 1, terminal.searchMatchCount)
    return active > 0 ? "\(active) of \(terminal.searchMatchCount)" : "\(terminal.searchMatchCount) matches"
  }
}

struct SettingsView: View {
  @ObservedObject var preferences: Preferences

  var body: some View {
    Form {
      Slider(value: $preferences.fontSize, in: 9...32) { Text("Font size") }
      Slider(value: $preferences.padding, in: 0...32) { Text("Padding") }
      Picker("Colour scheme", selection: $preferences.colourScheme) {
        ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) }
      }
      TextField("Shell path", text: $preferences.shellPath)
      if preferences.validShell != preferences.shellPath {
        Text("Shell must be an executable absolute path; new panes use /bin/zsh.")
          .foregroundStyle(.red)
      }
      Slider(value: $preferences.opacity, in: 0.5...1) { Text("Terminal background opacity") }
      Toggle("Allow terminal clipboard writes", isOn: $preferences.terminalClipboardWrites)
      Text("Security warning: terminal programs may replace the system clipboard when enabled.")
        .foregroundStyle(.orange)
      Stepper("Maximum clipboard write: \(preferences.terminalClipboardMaxBytes) bytes",
        value: $preferences.terminalClipboardMaxBytes, in: 1024...4_194_304, step: 1024)
    }
    .formStyle(.grouped)
    .padding()
    .frame(width: 460)
  }
}
