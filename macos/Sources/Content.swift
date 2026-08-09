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
    .background(windowBackground)
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

  private var windowBackground: AnyShapeStyle {
    switch preferences.windowMaterial {
    case "Under Window": return AnyShapeStyle(.ultraThinMaterial)
    case "Sidebar": return AnyShapeStyle(.thinMaterial)
    case "HUD": return AnyShapeStyle(.regularMaterial)
    default: return AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
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

enum SettingsPane: String, CaseIterable {
  case appearance
  case terminal
  case advanced

  var title: String {
    switch self {
    case .appearance: "Appearance"
    case .terminal: "Terminal"
    case .advanced: "Advanced"
    }
  }

  var symbol: String {
    switch self {
    case .appearance: "paintbrush"
    case .terminal: "terminal"
    case .advanced: "gearshape.2"
    }
  }

  var contentSize: NSSize {
    switch self {
    case .appearance: NSSize(width: 650, height: 390)
    case .terminal: NSSize(width: 700, height: 410)
    case .advanced: NSSize(width: 700, height: 300)
    }
  }
}

@MainActor final class SettingsModel: ObservableObject {
  @Published var pane: SettingsPane {
    didSet { UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane") }
  }

  init() {
    pane = SettingsPane(rawValue: UserDefaults.standard.string(forKey: "settingsPane") ?? "")
      ?? .appearance
  }
}

struct SettingsView: View {
  @ObservedObject var preferences: Preferences
  @ObservedObject var model: SettingsModel
  @State private var confirmRestore = false

  var body: some View {
    ScrollView {
      Group {
        switch model.pane {
        case .appearance: appearance
        case .terminal: terminal
        case .advanced: advanced
        }
      }
      .scenePadding()
    }
    .frame(width: model.pane.contentSize.width, height: model.pane.contentSize.height)
    .alert("Restore Defaults?", isPresented: $confirmRestore) {
      Button("Restore Defaults", role: .destructive) { preferences.restoreDefaults() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("All Zigonaut settings will be returned to their original values.")
    }
  }

  private var appearance: some View {
    Form {
      Section("Application") {
        Picker("Colour scheme", selection: $preferences.colourScheme) {
          ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) }
        }
        .pickerStyle(.segmented)
        Picker("Window material", selection: $preferences.windowMaterial) {
          Text("Window").tag("Window")
          Text("Under Window").tag("Under Window")
          Text("Sidebar").tag("Sidebar")
          Text("HUD").tag("HUD")
        }
        LabeledContent("Background opacity") {
          HStack {
            Slider(value: $preferences.opacity, in: 0.5...1, step: 0.05)
            Text(preferences.opacity, format: .percent.precision(.fractionLength(0)))
              .monospacedDigit()
              .frame(width: 42, alignment: .trailing)
          }
        }
      }
      Section("Terminal themes") {
        Picker("Dark appearance", selection: $preferences.darkTerminalTheme) {
          ForEach(Preferences.themeNames, id: \.self) { Text(themeTitle($0)).tag($0) }
        }
        Picker("Light appearance", selection: $preferences.lightTerminalTheme) {
          ForEach(Preferences.themeNames, id: \.self) { Text(themeTitle($0)).tag($0) }
        }
        Toggle("Gently tint each tab background", isOn: $preferences.randomizeTabBackground)
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
        Picker("Normal weight", selection: $preferences.fontWeight) {
          ForEach(Preferences.fontWeights, id: \.self) { Text($0) }
        }
        Picker("Intense weight", selection: $preferences.intenseFontWeight) {
          ForEach(Preferences.fontWeights, id: \.self) { Text($0) }
        }
      }
    }
    .formStyle(.columns)
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
          Label {
            Text("New panes will use /bin/zsh until this is an executable absolute path.")
              .foregroundStyle(.secondary)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
        }
      }
      Section("Layout") {
        LabeledContent("Horizontal padding") {
          HStack {
            Slider(value: $preferences.paddingHorizontal, in: 0...64, step: 1)
            Text("\(Int(preferences.paddingHorizontal)) pt")
              .monospacedDigit()
              .frame(width: 42, alignment: .trailing)
          }
        }
        LabeledContent("Vertical padding") {
          HStack {
            Slider(value: $preferences.paddingVertical, in: 0...64, step: 1)
            Text("\(Int(preferences.paddingVertical)) pt")
              .monospacedDigit()
              .frame(width: 42, alignment: .trailing)
          }
        }
        Picker("Grid alignment", selection: $preferences.paddingBalance) {
          Text("Top Left").tag("Top Left")
          Text("Centered").tag("Centered")
        }
        Picker("Padding colour", selection: $preferences.paddingColor) {
          Text("Terminal Background").tag("Background")
          Text("Extend Edge Colours").tag("Extend")
          Text("Always Extend Edge Colours").tag("Always Extend")
        }
      }
      Section("History and initial size") {
        LabeledContent("Scrollback lines") {
          Stepper(value: $preferences.scrollbackSize, in: 0...1_000_000, step: 1_000) {
            Text(preferences.scrollbackSize.formatted())
              .monospacedDigit()
          }
        }
        LabeledContent("New window") {
          HStack {
            Stepper("\(preferences.initialColumns) columns", value: $preferences.initialColumns,
              in: 10...1_000)
            Stepper("\(preferences.initialRows) rows", value: $preferences.initialRows,
              in: 4...1_000)
          }
        }
      }
      Section("Palette overrides") {
        PaletteEditor(preferences: preferences)
      }
      Text("Shell changes apply to new tabs and panes. Appearance changes apply immediately.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .formStyle(.columns)
  }

  private var advanced: some View {
    Form {
      Section("Terminal clipboard") {
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
        Label {
          Text("Terminal programs can replace the system clipboard when this is enabled.")
            .foregroundStyle(.secondary)
        } icon: {
          Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
        }
      }
      Section("Shell integration") {
        TextField("Pipe command output", text: $preferences.pipeCommandOutput,
          prompt: Text("Copy output to the clipboard"))
        Text("The command receives the latest OSC 133 command output on standard input. Leave empty to copy it.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("Defaults") {
        LabeledContent("All settings") {
          Button("Restore Defaults…") { confirmRestore = true }
        }
      }
    }
    .formStyle(.columns)
  }

  private var fontFamilies: [String] {
    let installed = Preferences.monospacedFontFamilies
    let selected = installed.contains(preferences.fontFamily) ? [] : [preferences.fontFamily]
    return [Preferences.defaultFontFamily] + selected.filter { $0 != Preferences.defaultFontFamily } + installed
  }

  private func themeTitle(_ name: String) -> String {
    name.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
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

private struct PaletteEditor: View {
  @ObservedObject var preferences: Preferences
  @State private var expanded = false

  private var base: TerminalPalette { TerminalPalette.load(preferences.darkTerminalTheme) }
  private var entries: [(String, String, UInt32)] {
    var values = [
      ("Foreground", "foreground", base.foreground),
      ("Background", "background", base.background),
      ("Cursor", "cursor", base.cursor),
    ]
    let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
      "Bright Black", "Bright Red", "Bright Green", "Bright Yellow", "Bright Blue",
      "Bright Magenta", "Bright Cyan", "Bright White"]
    values += names.enumerated().map { ($0.element, "ansi\($0.offset)", base.ansi[$0.offset]) }
    return values
  }

  var body: some View {
    DisclosureGroup("Edit foreground, background, cursor and ANSI colours", isExpanded: $expanded) {
      ForEach(entries, id: \.1) { entry in
        HStack {
          ColorPicker(entry.0, selection: Binding(
            get: { preferences.overrideColor(entry.1, fallback: entry.2) },
            set: { preferences.setOverrideColor($0, for: entry.1) }
          ), supportsOpacity: false)
          if preferences.hasOverride(entry.1) {
            Button {
              preferences.clearOverride(entry.1)
            } label: {
              Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Use Theme Default")
          }
        }
      }
    }
  }
}
