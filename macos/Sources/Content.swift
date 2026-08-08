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
        focused: window.focusedPane == pane.id,
        wantsKeyboardFocus: window.focusedPane == pane.id && !window.findVisible
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
      NativeSearchField(text: Binding(
        get: { window.findQuery }, set: { window.updateFindQuery($0) }
      ), focusRequest: window.findFocusRequest) {
        terminal.navigateSearch(forward: true)
      }
      .frame(minWidth: 220, idealWidth: 320)
      Text(description)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      Button { terminal.navigateSearch(forward: false) } label: {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless)
      .help("Previous Match")
      .disabled(terminal.searchMatchCount == 0)
      Button { terminal.navigateSearch(forward: true) } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .help("Next Match")
      .disabled(terminal.searchMatchCount == 0)
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

private struct NativeSearchField: NSViewRepresentable {
  @Binding var text: String
  let focusRequest: Int
  let submit: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = "Find in Scrollback"
    field.sendsWholeSearchString = true
    field.delegate = context.coordinator
    field.target = context.coordinator
    field.action = #selector(Coordinator.submit)
    context.coordinator.lastFocusRequest = focusRequest
    DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
    if context.coordinator.lastFocusRequest != focusRequest {
      context.coordinator.lastFocusRequest = focusRequest
      DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
    }
  }

  @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: NativeSearchField
    var lastFocusRequest = 0
    init(_ parent: NativeSearchField) { self.parent = parent }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      parent.text = field.stringValue
    }

    @objc func submit() { parent.submit() }
  }
}

struct SettingsView: View {
  @ObservedObject var preferences: Preferences
  @State private var confirmRestore = false

  var body: some View {
    VStack(spacing: 0) {
      TabView {
        appearance
          .tabItem { Label("Appearance", systemImage: "paintbrush") }
        terminal
          .tabItem { Label("Terminal", systemImage: "terminal") }
        advanced
          .tabItem { Label("Advanced", systemImage: "gearshape.2") }
      }
      Divider()
      HStack {
        Button("Restore Defaults…") { confirmRestore = true }
        Spacer()
      }
      .padding(16)
    }
    .frame(width: 560, height: 410)
    .confirmationDialog(
      "Restore all settings to their defaults?", isPresented: $confirmRestore,
      titleVisibility: .visible
    ) {
      Button("Restore Defaults", role: .destructive) { preferences.restoreDefaults() }
      Button("Cancel", role: .cancel) {}
    }
  }

  private var appearance: some View {
    Form {
      Section("Application") {
        Picker("Colour scheme", selection: $preferences.colourScheme) {
          ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) }
        }
        .pickerStyle(.segmented)
        LabeledContent("Background opacity") {
          HStack {
            Slider(value: $preferences.opacity, in: 0.5...1, step: 0.05)
            Text(preferences.opacity, format: .percent.precision(.fractionLength(0)))
              .monospacedDigit()
              .frame(width: 42, alignment: .trailing)
          }
        }
      }
      Section("Font") {
        Picker("Family", selection: $preferences.fontFamily) {
          ForEach(fontFamilies, id: \.self) { Text($0) }
        }
        LabeledContent("Size") {
          HStack {
            Slider(value: $preferences.fontSize, in: 9...32, step: 1)
            Text("\(Int(preferences.fontSize)) pt")
              .monospacedDigit()
              .frame(width: 42, alignment: .trailing)
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var terminal: some View {
    Form {
      Section("Shell") {
        LabeledContent("Executable") {
          HStack {
            TextField("/bin/zsh", text: $preferences.shellPath)
            Button("Choose…", action: chooseShell)
          }
        }
        if preferences.validShell != preferences.shellPath {
          Label("New panes will use /bin/zsh until this is an executable absolute path.",
            systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
      }
      Section("Layout") {
        LabeledContent("Padding") {
          HStack {
            Slider(value: $preferences.padding, in: 0...32, step: 1)
            Text("\(Int(preferences.padding)) pt")
              .monospacedDigit()
              .frame(width: 42, alignment: .trailing)
          }
        }
      }
      Text("Shell changes apply to new tabs and panes. Appearance changes apply immediately.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
  }

  private var advanced: some View {
    Form {
      Section("Terminal Clipboard") {
        Toggle("Allow terminal applications to write to the clipboard",
          isOn: $preferences.terminalClipboardWrites)
        LabeledContent("Maximum write") {
          Stepper(value: $preferences.terminalClipboardMaxBytes,
            in: 1_024...4_194_304, step: 1_024) {
            Text(ByteCountFormatter.string(
              fromByteCount: Int64(preferences.terminalClipboardMaxBytes), countStyle: .memory))
              .monospacedDigit()
          }
        }
        .disabled(!preferences.terminalClipboardWrites)
        Label("Terminal programs can replace the system clipboard when this is enabled.",
          systemImage: "exclamationmark.shield.fill")
          .foregroundStyle(.orange)
      }
      Section("Shell Integration") {
        TextField("Pipe command output", text: $preferences.pipeCommandOutput,
          prompt: Text("Copy output to the clipboard"))
        Text("The command receives the latest OSC 133 command output on standard input. Leave empty to copy it.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var fontFamilies: [String] {
    let installed = Preferences.monospacedFontFamilies
    let selected = installed.contains(preferences.fontFamily) ? [] : [preferences.fontFamily]
    return [Preferences.defaultFontFamily] + selected.filter { $0 != Preferences.defaultFontFamily } + installed
  }

  private func chooseShell() {
    let panel = NSOpenPanel()
    panel.title = "Choose a Shell"
    panel.prompt = "Choose"
    panel.directoryURL = URL(fileURLWithPath: "/bin", isDirectory: true)
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    preferences.shellPath = url.path
  }
}
