import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZigonautPaneLayout

private let paneCoordinateSpace = "ZigonautContentView"

private struct PaneFrameKey: PreferenceKey {
  static let defaultValue: [UUID: CGRect] = [:]
  static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

struct PaneView: View {
  let node: PaneNode
  @ObservedObject var window: WindowModel

  var body: some View {
    switch node {
    case .leaf(let pane):
      PaneLeafView(pane: pane, window: window)
    case .split(let id, let axis, let ratio, let first, let second):
      RestorableSplit(axis: axis, ratio: ratio, ratioChanged: { window.setRatio(id, $0) }) {
        PaneView(node: first, window: window)
      } second: {
        PaneView(node: second, window: window)
      }
    }
  }
}

private struct PaneLeafView: View {
  @ObservedObject var pane: TerminalModel
  @ObservedObject var window: WindowModel
  @State private var hovered = false
  @State private var dropEdge: PaneDropEdge?

  var body: some View {
    GeometryReader { geometry in
      TerminalSurface(
        model: pane,
        preferences: window.preferences,
        focused: window.focusedPane == pane.id,
        wantsKeyboardFocus: window.focusedPane == pane.id && !window.findVisible
      ) {
        window.focusedPane = pane.id
      }
      .overlay(alignment: .top) {
        if window.panes.count > 1 {
          Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 13)
            .background(.ultraThinMaterial, in: Capsule())
            .contentShape(Rectangle())
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
            .onDrag {
              window.draggingPane = pane.id
              return NSItemProvider(object: pane.id.uuidString as NSString)
            } preview: {
              TerminalDragPreview()
            }
            .help("Drag to move this pane")
        }
      }
      .overlay {
        if let dropEdge {
          PaneDropPreview(edge: dropEdge)
            .allowsHitTesting(false)
        }
      }
      .onHover { hovered = $0 }
      .onDrop(of: [.plainText], delegate: PaneDropDelegate(
        edge: $dropEdge, size: geometry.size, destination: pane.id, window: window))
    }
    .id(pane.id)
    .background(GeometryReader { geometry in
      Color.clear.preference(key: PaneFrameKey.self,
        value: [pane.id: geometry.frame(in: .named(paneCoordinateSpace))])
    })
  }
}

private struct TerminalDragPreview: View {
  var body: some View {
    Label("Move Pane", systemImage: "rectangle.split.2x1")
      .padding(8)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
  }
}

private struct PaneDropPreview: View {
  let edge: PaneDropEdge

  var body: some View {
    GeometryReader { geometry in
      let color = Color.accentColor.opacity(0.3)
      switch edge {
      case .left:
        HStack(spacing: 0) {
          Rectangle().fill(color).frame(width: geometry.size.width / 2)
          Spacer(minLength: 0)
        }
      case .right:
        HStack(spacing: 0) {
          Spacer(minLength: 0)
          Rectangle().fill(color).frame(width: geometry.size.width / 2)
        }
      case .top:
        VStack(spacing: 0) {
          Rectangle().fill(color).frame(height: geometry.size.height / 2)
          Spacer(minLength: 0)
        }
      case .bottom:
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          Rectangle().fill(color).frame(height: geometry.size.height / 2)
        }
      }
    }
  }
}

private struct PaneDropDelegate: DropDelegate {
  @Binding var edge: PaneDropEdge?
  let size: CGSize
  let destination: UUID
  let window: WindowModel

  func validateDrop(info: DropInfo) -> Bool {
    window.draggingPane != nil && window.draggingPane != destination
      && info.hasItemsConforming(to: [.plainText])
  }

  func dropEntered(info: DropInfo) { update(info) }
  func dropUpdated(info: DropInfo) -> DropProposal? {
    guard validateDrop(info: info) else { edge = nil; return DropProposal(operation: .forbidden) }
    update(info)
    return DropProposal(operation: .move)
  }
  func dropExited(info: DropInfo) { edge = nil }

  func performDrop(info: DropInfo) -> Bool {
    guard validateDrop(info: info), let source = window.draggingPane,
      let destinationEdge = PaneDropEdge.nearest(to: info.location, in: size) else { return false }
    edge = nil
    window.draggingPane = nil
    return window.movePane(source, onto: destination, edge: destinationEdge)
  }

  private func update(_ info: DropInfo) {
    edge = validateDrop(info: info) ? PaneDropEdge.nearest(to: info.location, in: size) : nil
  }
}

private struct SplitFirstSizeKey: PreferenceKey {
  static let defaultValue: [UUID: CGFloat] = [:]
  static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

private struct RestorableSplit<First: View, Second: View>: View {
  private let observationID = UUID()
  let axis: Axis
  let ratio: Double
  let ratioChanged: (Double) -> Void
  @ViewBuilder let first: First
  @ViewBuilder let second: Second

  var body: some View {
    GeometryReader { geometry in
      let length = axis == .horizontal ? geometry.size.width : geometry.size.height
      Group {
        if axis == .horizontal {
          HSplitView {
            measuredFirst(first.frame(idealWidth: max(0, length * ratio)))
            second
          }
        } else {
          VSplitView {
            measuredFirst(first.frame(idealHeight: max(0, length * ratio)))
            second
          }
        }
      }
      .onPreferenceChange(SplitFirstSizeKey.self) { sizes in
        guard length > 0, let firstLength = sizes[observationID] else { return }
        let measured = Double(firstLength / length)
        guard measured.isFinite, abs(measured - ratio) >= 0.005 else { return }
        ratioChanged(measured)
      }
    }
  }

  private func measuredFirst<V: View>(_ view: V) -> some View {
    view.background(GeometryReader { geometry in
      Color.clear.preference(key: SplitFirstSizeKey.self,
        value: [observationID: axis == .horizontal ? geometry.size.width : geometry.size.height])
    })
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
      PaneView(node: window.visibleRoot, window: window)
    }
    .background(windowBackground)
    .coordinateSpace(name: paneCoordinateSpace)
    .onPreferenceChange(PaneFrameKey.self) { window.updatePaneFrames($0) }
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
    case .appearance: NSSize(width: 680, height: 570)
    case .terminal: NSSize(width: 700, height: 560)
    case .advanced: NSSize(width: 680, height: 440)
    }
  }

  var subtitle: String {
    switch self {
    case .appearance: "Personalize how Zigonaut looks and presents terminal content."
    case .terminal: "Choose how new terminals start, fit and retain output."
    case .advanced: "Control integrations, security-sensitive features and defaults."
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
      VStack(alignment: .leading, spacing: 24) {
        SettingsPaneHeader(pane: model.pane)
        Group {
          switch model.pane {
          case .appearance: appearance
          case .terminal: terminal
          case .advanced: advanced
          }
        }
      }
      .padding(.horizontal, 28)
      .padding(.top, 24)
      .padding(.bottom, 28)
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
    VStack(alignment: .leading, spacing: 20) {
      TerminalAppearancePreview(preferences: preferences)
      Form {
        Section("Window") {
          Picker("Colour scheme", selection: $preferences.colourScheme) {
            ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) }
          }
          .pickerStyle(.segmented)
          .frame(width: 240)
          Picker("Material", selection: $preferences.windowMaterial) {
            Text("Standard").tag("Window")
            Text("Translucent").tag("Under Window")
            Text("Sidebar").tag("Sidebar")
            Text("Heads-up display").tag("HUD")
          }
          LabeledContent("Background opacity") {
            HStack(spacing: 10) {
              Slider(value: $preferences.opacity, in: 0.5...1, step: 0.05)
                .frame(width: 180)
              Text(preferences.opacity, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
            }
          }
        }
        Section("Terminal theme") {
          Picker("Dark appearance", selection: $preferences.darkTerminalTheme) {
            ForEach(Preferences.themeNames, id: \.self) { Text(themeTitle($0)).tag($0) }
          }
          Picker("Light appearance", selection: $preferences.lightTerminalTheme) {
            ForEach(Preferences.themeNames, id: \.self) { Text(themeTitle($0)).tag($0) }
          }
          Toggle("Gently tint each tab background", isOn: $preferences.randomizeTabBackground)
        }
        Section("Typography") {
          Picker("Typeface", selection: $preferences.fontFamily) {
            ForEach(fontFamilies, id: \.self) { Text($0) }
          }
          LabeledContent("Size") {
            HStack(spacing: 10) {
              Slider(value: $preferences.fontSize, in: 9...32, step: 1)
                .frame(width: 180)
              Text("\(Int(preferences.fontSize)) pt")
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
            }
          }
          Picker("Regular text", selection: $preferences.fontWeight) {
            ForEach(Preferences.fontWeights, id: \.self) { Text($0) }
          }
          Picker("Intense text", selection: $preferences.intenseFontWeight) {
            ForEach(Preferences.fontWeights, id: \.self) { Text($0) }
          }
          Picker("Intensity treatment", selection: $preferences.intenseTextStyle) {
            Text("Weight only").tag("bold")
            Text("Weight and bright colours").tag("all")
            Text("Bright colours only").tag("bright")
          }
        }
      }
      .formStyle(.columns)
    }
  }

  private var terminal: some View {
    Form {
      Section("Shell") {
        LabeledContent("Executable") {
          HStack(spacing: 8) {
            TextField("/bin/zsh", text: $preferences.shellPath)
              .frame(minWidth: 280)
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
        Toggle("Automatic shell integration", isOn: $preferences.automaticShellIntegration)
        SettingsNote("Adds prompt and working-directory reporting to supported shells. Changes apply to new terminals only.")
      }
      Section("Layout") {
        LabeledContent("Horizontal padding") {
          HStack(spacing: 10) {
            Slider(value: $preferences.paddingHorizontal, in: 0...64, step: 1)
              .frame(width: 180)
            Text("\(Int(preferences.paddingHorizontal)) pt")
              .monospacedDigit()
              .frame(width: 38, alignment: .trailing)
          }
        }
        LabeledContent("Vertical padding") {
          HStack(spacing: 10) {
            Slider(value: $preferences.paddingVertical, in: 0...64, step: 1)
              .frame(width: 180)
            Text("\(Int(preferences.paddingVertical)) pt")
              .monospacedDigit()
              .frame(width: 38, alignment: .trailing)
          }
        }
        Picker("Content position", selection: $preferences.paddingBalance) {
          Text("Top Left").tag("Top Left")
          Text("Centered").tag("Centered")
        }
        Picker("Padding colour", selection: $preferences.paddingColor) {
          Text("Terminal Background").tag("Background")
          Text("Extend Edge Colours").tag("Extend")
          Text("Always Extend Edge Colours").tag("Always Extend")
        }
      }
      Section("History") {
        LabeledContent("Scrollback lines") {
          Stepper(value: $preferences.scrollbackSize, in: 0...1_000_000, step: 1_000) {
            Text(preferences.scrollbackSize.formatted())
              .monospacedDigit()
              .frame(minWidth: 64, alignment: .trailing)
          }
        }
      }
      Section("New window size") {
        LabeledContent("Columns") {
          Stepper(value: $preferences.initialColumns, in: 10...1_000) {
            Text(preferences.initialColumns.formatted())
              .monospacedDigit()
              .frame(minWidth: 44, alignment: .trailing)
          }
        }
        LabeledContent("Rows") {
          Stepper(value: $preferences.initialRows, in: 4...1_000) {
            Text(preferences.initialRows.formatted())
              .monospacedDigit()
              .frame(minWidth: 44, alignment: .trailing)
          }
        }
      }
      Section("Palette overrides") {
        PaletteEditor(preferences: preferences)
      }
      SettingsNote("Shell and window-size changes apply to new terminals. Other changes apply immediately.")
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
        SettingsNote("Terminal programs can replace the system clipboard when this is enabled.",
          symbol: "exclamationmark.shield.fill", colour: .orange)
      }
      Section("Shell integration") {
        LabeledContent("Output command") {
          TextField("", text: $preferences.pipeCommandOutput,
            prompt: Text("Copy to clipboard"))
            .frame(minWidth: 300)
        }
        SettingsNote("Zigonaut sends the latest command output to this command on standard input. Leave it empty to copy the output.")
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

private struct SettingsPaneHeader: View {
  let pane: SettingsPane

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: pane.symbol)
        .font(.system(size: 22, weight: .medium))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.tint)
        .frame(width: 40, height: 40)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 2) {
        Text(pane.title)
          .font(.title2.weight(.semibold))
        Text(pane.subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

private struct SettingsNote: View {
  let text: String
  let symbol: String?
  let colour: Color

  init(_ text: String, symbol: String? = nil, colour: Color = .secondary) {
    self.text = text
    self.symbol = symbol
    self.colour = colour
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      if let symbol {
        Image(systemName: symbol)
          .foregroundStyle(colour)
      }
      Text(text)
        .foregroundStyle(.secondary)
    }
    .font(.caption)
    .fixedSize(horizontal: false, vertical: true)
  }
}

private struct TerminalAppearancePreview: View {
  @ObservedObject var preferences: Preferences
  @Environment(\.colorScheme) private var systemColourScheme

  private var isDark: Bool {
    switch preferences.colourScheme {
    case "Light": false
    case "Dark": true
    default: systemColourScheme == .dark
    }
  }

  private var palette: TerminalPalette {
    preferences.terminalPalette(dark: isDark, seed: 0)
  }

  private func colour(_ value: UInt32) -> Color {
    Color(nsColor: NSColor(rgb: value))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 7) {
        Circle().fill(.red.opacity(0.85))
          .frame(width: 10, height: 10)
        Circle().fill(.yellow.opacity(0.85))
          .frame(width: 10, height: 10)
        Circle().fill(.green.opacity(0.85))
          .frame(width: 10, height: 10)
        Spacer()
        Text("Preview")
          .font(.caption.weight(.medium))
          .foregroundStyle(colour(palette.foreground).opacity(0.6))
        Spacer()
        Color.clear.frame(width: 35)
      }
      .frame(height: 30)
      .padding(.horizontal, 12)
      Divider().overlay(colour(palette.foreground).opacity(0.12))
      VStack(alignment: .leading, spacing: 5) {
        Text("Last login: today on ttys001")
          .foregroundStyle(colour(palette.foreground).opacity(0.65))
        HStack(spacing: 0) {
          Text("~/Projects/zigonaut ").foregroundStyle(colour(palette.ansi[4]))
          Text("git:").foregroundStyle(colour(palette.foreground).opacity(0.65))
          Text("main ").foregroundStyle(colour(palette.ansi[5]))
          Text("❯ ").foregroundStyle(colour(palette.ansi[2]))
          Text("zig build")
        }
        Text("Build completed successfully")
          .foregroundStyle(colour(palette.ansi[2]))
      }
      .font(Font(preferences.terminalFont(size: min(preferences.fontSize, 15))))
      .foregroundStyle(colour(palette.foreground))
      .padding(14)
      .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
    }
    .background(colour(palette.background).opacity(preferences.opacity))
    .clipShape(RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(.primary.opacity(0.14), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Terminal appearance preview")
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
