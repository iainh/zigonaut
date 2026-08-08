import AppKit
import Combine
import SwiftUI
import ZigonautCore

extension Notification.Name {
  static let terminalDesktopNotification = Notification.Name("TerminalDesktopNotification")
}

private final class TerminalCallbackBox: @unchecked Sendable {
  weak var model: TerminalModel?
  private let lock = NSLock()
  private var scheduled = false
  private var dirty = false

  func wake() {
    lock.lock()
    dirty = true
    guard !scheduled else { lock.unlock(); return }
    scheduled = true
    lock.unlock()
    DispatchQueue.main.async { [weak self] in self?.drain() }
  }

  @MainActor private func drain() {
    lock.lock()
    dirty = false
    lock.unlock()
    model?.refresh()
    lock.lock()
    if dirty {
      lock.unlock()
      // Cap sustained output near the fastest common display cadence and yield
      // to keyboard/window events instead of rendering once per PTY read.
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
        self?.drain()
      }
    } else {
      scheduled = false
      lock.unlock()
    }
  }
}

private func terminalWake(_ context: UnsafeMutableRawPointer?) {
  guard let context else {
    return
  }
  Unmanaged<TerminalCallbackBox>.fromOpaque(context).takeUnretainedValue().wake()
}

/// The core serializes its mutable state internally and remains valid until
/// TerminalModel drains the writer queue and destroys it during teardown.
private final class TerminalCoreHandle: @unchecked Sendable {
  let pointer: OpaquePointer

  init(_ pointer: OpaquePointer) {
    self.pointer = pointer
  }
}

struct TerminalRenderFrame {
  var foreground: UInt32 = 0
  var background: UInt32 = 0
  var cursor: UInt32 = 0
  var cursorX: Int = 0
  var cursorY: Int = 0
  var cursorColumns: Int = 1
  var cursorStyle: UInt8 = 1
  var cursorVisible = false
}

struct TerminalRenderCell: Identifiable {
  let id: Int
  let x: Int
  let y: Int
  let text: String
  let foreground: UInt32
  let background: UInt32
  let underlineColor: UInt32
  let occupancy: UInt8
  let underlineStyle: UInt8
  let bold: Bool
  let italic: Bool
  let faint: Bool
  let strikethrough: Bool
  let overline: Bool
  let selected: Bool
  let backgroundIsDefault: Bool
  let searchHighlight: UInt8
}

struct TerminalRenderSnapshot {
  var frame = TerminalRenderFrame()
  var cells: [TerminalRenderCell] = []
}

@MainActor final class Preferences: ObservableObject {
  static let defaultFontFamily = "System Monospaced"
  static let defaultFontSize = 14.0
  static let defaultPadding = 8.0
  static let monospacedFontFamilies = NSFontManager.shared.availableFontFamilies.filter { family in
    NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)?.isFixedPitch == true
  }.sorted()

  @AppStorage("fontFamily") var fontFamily = defaultFontFamily
  @AppStorage("fontSize") var fontSize = 14.0
  @AppStorage("padding") var padding = 8.0
  @AppStorage("colourScheme") var colourScheme = "System"
  @AppStorage("shellPath") var shellPath = "/bin/zsh"
  @AppStorage("opacity") var opacity = 1.0
  @AppStorage("terminalClipboardWrites") var terminalClipboardWrites = false
  @AppStorage("terminalClipboardMaxBytes") var terminalClipboardMaxBytes = 1_048_576
  @AppStorage("pipeCommandOutput") var pipeCommandOutput = ""

  var validShell: String {
    shellPath.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: shellPath)
      ? shellPath : "/bin/zsh"
  }

  func terminalFont(size: CGFloat) -> NSFont {
    guard fontFamily != Self.defaultFontFamily,
      let selected = NSFontManager.shared.font(
        withFamily: fontFamily, traits: [], weight: 5, size: size), selected.isFixedPitch
    else {
      return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
    return selected
  }

  func restoreDefaults() {
    fontFamily = Self.defaultFontFamily
    fontSize = Self.defaultFontSize
    padding = Self.defaultPadding
    colourScheme = "System"
    shellPath = "/bin/zsh"
    opacity = 1
    terminalClipboardWrites = false
    terminalClipboardMaxBytes = 1_048_576
    pipeCommandOutput = ""
  }
}

@MainActor final class TerminalModel: ObservableObject, Identifiable, @unchecked Sendable {
  let id = UUID()
  @Published private(set) var text = "Starting shell…"
  @Published private(set) var title: String
  @Published private(set) var renderSnapshot = TerminalRenderSnapshot()
  @Published private(set) var searchMatchCount = 0
  @Published private(set) var searchActiveIndex: Int?
  @Published private(set) var searchError = false
  nonisolated(unsafe) private var core: TerminalCoreHandle?
  nonisolated private let writer = DispatchQueue(label: "dev.zigonaut.pty-writer")
  nonisolated private let callbackBox: Unmanaged<TerminalCallbackBox>
  private var cellBuffer = [zigonaut_render_cell_v1](
    repeating: zigonaut_render_cell_v1(), count: 80 * 24)
  private var textBuffer = [UInt8](repeating: 0, count: 80 * 24 * 4)
  private var currentColumns = 80
  private var currentRows = 24
  private let maximumCells = 500_000
  private let maximumTextBytes = 8_000_000
  // Selection pasteboard writes are all-or-nothing and capped to bound memory use.
  private let maximumSelectionBytes = 4_194_304
  private let preferences: Preferences
  private let defaultTitle: String

  init(shell: String, preferences: Preferences) {
    self.preferences = preferences
    defaultTitle = URL(fileURLWithPath: shell).lastPathComponent
    title = defaultTitle
    let box = TerminalCallbackBox()
    callbackBox = .passRetained(box)
    guard
      let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(
        "zigonaut-pty-helper"),
      FileManager.default.isExecutableFile(atPath: helper.path)
    else {
      text = "Bundled PTY helper is missing."
      callbackBox.release()
      return
    }
    box.model = self
    core = helper.path.withCString { helperPath in
      shell.withCString { shellPath in
        zigonaut_core_create(helperPath, shellPath, terminalWake, callbackBox.toOpaque())
      }
    }.map(TerminalCoreHandle.init)
    if core == nil {
      box.model = nil
      callbackBox.release()
    }
    applyClipboardSettings()
    refresh()
  }

  func refresh() {
    guard let core else {
      return
    }
    let desiredCells = min(maximumCells, max(currentColumns * currentRows, 1))
    if cellBuffer.count < desiredCells {
      cellBuffer = [zigonaut_render_cell_v1](
        repeating: zigonaut_render_cell_v1(), count: desiredCells)
    }
    retrieveSnapshot(core: core.pointer, retry: true)
    retrieveTitle(core: core.pointer)
    drainNotifications(core: core.pointer)
    drainClipboard(core: core.pointer)
  }

  func link(column: Int, row: Int) -> URL? {
    guard let core else { return nil }
    var bytes = [UInt8](repeating: 0, count: 2048)
    let required = zigonaut_core_link_at(core.pointer, UInt16(clamping: column), UInt16(clamping: row), &bytes, UInt32(bytes.count))
    guard required > 0, required <= bytes.count,
      let value = String(bytes: bytes.prefix(Int(required)), encoding: .utf8) else { return nil }
    return URL(string: value)
  }
  func applyClipboardSettings() {
    if let core {
      zigonaut_core_set_clipboard_write(core.pointer, preferences.terminalClipboardWrites,
        UInt32(clamping: preferences.terminalClipboardMaxBytes))
    }
  }
  private func drainNotifications(core: OpaquePointer) {
    while true {
      var title = [UInt8](repeating: 0, count: 4096)
      var body = [UInt8](repeating: 0, count: 4096)
      var result = zigonaut_notification_result_v1()
      zigonaut_core_take_notification(core, &title, UInt32(title.count), &body, UInt32(body.count), &result)
      guard result.status == 0 else { return }
      guard let titleValue = String(bytes: title.prefix(Int(result.written_title)), encoding: .utf8),
        let bodyValue = String(bytes: body.prefix(Int(result.written_body)), encoding: .utf8) else { continue }
      NotificationCenter.default.post(name: .terminalDesktopNotification, object: self,
        userInfo: ["title": titleValue, "body": bodyValue])
    }
  }
  private func drainClipboard(core: OpaquePointer) {
    while true {
      var result = zigonaut_clipboard_result_v1()
      zigonaut_core_take_clipboard_write(core, nil, 0, &result)
      guard result.status == 3 else { return }
      let required = Int(result.required_bytes)
      guard required <= 4_194_304 else { return }
      var bytes = [UInt8](repeating: 0, count: max(required, 1_024))
      zigonaut_core_take_clipboard_write(core, &bytes, UInt32(bytes.count), &result)
      guard result.status == 0, result.written_bytes == result.required_bytes else { return }
      if result.clear != 0 {
        NSPasteboard.general.clearContents()
      } else if let value = String(bytes: bytes.prefix(required), encoding: .utf8) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
      }
    }
  }

  private func retrieveSnapshot(core: OpaquePointer, retry: Bool) {
    var frame = zigonaut_render_frame_v1()
    var result = zigonaut_render_snapshot_result_v1()
    cellBuffer.withUnsafeMutableBufferPointer { cells in
      textBuffer.withUnsafeMutableBufferPointer { bytes in
        zigonaut_core_render_snapshot(
          core,
          &frame,
          cells.baseAddress,
          UInt32(clamping: cells.count),
          bytes.baseAddress,
          UInt32(clamping: bytes.count),
          &result
        )
      }
    }
    if retry && result.status == 1 {
      let requiredCells = min(Int(result.required_cells), maximumCells)
      let requiredText = min(Int(result.required_text_bytes), maximumTextBytes)
      if requiredCells > cellBuffer.count {
        cellBuffer = [zigonaut_render_cell_v1](
          repeating: zigonaut_render_cell_v1(), count: requiredCells)
      }
      if requiredText > textBuffer.count {
        textBuffer = [UInt8](repeating: 0, count: requiredText)
      }
      if requiredCells <= maximumCells && requiredText <= maximumTextBytes {
        retrieveSnapshot(core: core, retry: false)
        return
      }
    }
    guard result.status != 2 else {
      return
    }
    let count = min(Int(result.written_cells), cellBuffer.count)
    let cells = cellBuffer.prefix(count).enumerated().map { index, cell in
      let start = min(Int(cell.text_offset), textBuffer.count)
      let end = min(start + Int(cell.text_length), textBuffer.count)
      return TerminalRenderCell(
        id: index,
        x: Int(cell.x),
        y: Int(cell.y),
        text: String(decoding: textBuffer[start..<end], as: UTF8.self),
        foreground: cell.foreground_rgb,
        background: cell.background_rgb,
        underlineColor: cell.underline_rgb,
        occupancy: cell.occupancy,
        underlineStyle: cell.underline_style,
        bold: cell.bold != 0,
        italic: cell.italic != 0,
        faint: cell.faint != 0,
        strikethrough: cell.strikethrough != 0,
        overline: cell.overline != 0,
        selected: cell.selected != 0,
        backgroundIsDefault: cell.background_is_default != 0 && cell.background_rgb == frame.background_rgb,
        searchHighlight: cell.search_highlight
      )
    }
    renderSnapshot = TerminalRenderSnapshot(
      frame: TerminalRenderFrame(
        foreground: frame.foreground_rgb,
        background: frame.background_rgb,
        cursor: frame.cursor_rgb,
        cursorX: Int(frame.cursor_x),
        cursorY: Int(frame.cursor_y),
        cursorColumns: Int(frame.cursor_columns),
        cursorStyle: frame.cursor_style,
        cursorVisible: frame.cursor_visible != 0 && frame.cursor_has_position != 0
      ),
      cells: cells
    )
  }

  func accessibilityText() -> String {
    let cells = renderSnapshot.cells
    guard !cells.isEmpty else { return text }
    var rows = [Int: [(Int, String)]]()
    for cell in cells where cell.occupancy != 2 {
      rows[cell.y, default: []].append((cell.x, cell.text.isEmpty ? " " : cell.text))
    }
    return rows.keys.sorted().map { row in
      var value = ""
      var column = 0
      for (x, cellText) in (rows[row] ?? []).sorted(by: { $0.0 < $1.0 }) {
        if x > column {
          value += String(repeating: " ", count: x - column)
        }
        value += cellText
        column = x + 1
      }
      return value
    }.joined(separator: "\n")
  }

  private func retrieveTitle(core: OpaquePointer) {
    var bytes = [UInt8](repeating: 0, count: 256)
    var required = zigonaut_core_title(core, &bytes, UInt32(bytes.count))
    if required > bytes.count && required <= 4096 {
      bytes = [UInt8](repeating: 0, count: Int(required))
      required = zigonaut_core_title(core, &bytes, UInt32(bytes.count))
    }
    let count = min(Int(required), bytes.count)
    let value = String(decoding: bytes[0..<count], as: UTF8.self)
    let newTitle = value.isEmpty ? defaultTitle : value
    guard title != newTitle else { return }
    title = newTitle
  }
  func resize(columns: Int, rows: Int) {
    guard columns != currentColumns || rows != currentRows else { return }
    currentColumns = columns
    currentRows = rows
    if let core {
      zigonaut_core_resize(core.pointer, UInt16(clamping: columns), UInt16(clamping: rows))
    }
  }
  func write(_ value: String) { enqueue(value, paste: false) }
  func paste(_ value: String) { enqueue(value, paste: true) }
  private func enqueue(_ value: String, paste: Bool) {
    guard let core else { return }
    let bytes = Array(value.utf8)
    writer.async {
      bytes.withUnsafeBufferPointer {
        if let pointer = $0.baseAddress {
          paste
            ? zigonaut_core_paste(core.pointer, pointer, $0.count)
            : zigonaut_core_write(core.pointer, pointer, $0.count)
        }
      }
    }
  }
  func scroll(_ rows: Int) {
    if let core { zigonaut_core_scroll(core.pointer, rows) }
    refresh()
  }
  func setSearch(_ query: String) {
    guard let core else { return }
    let bytes = Array(query.utf8)
    writer.async { [weak self] in
      var status = zigonaut_search_status_v1()
      bytes.withUnsafeBufferPointer { buffer in
        zigonaut_core_search_set(core.pointer, buffer.baseAddress, buffer.count, &status)
      }
      DispatchQueue.main.async {
        self?.applySearch(status)
        self?.refresh()
      }
    }
  }
  func navigateSearch(forward: Bool) {
    guard let core else { return }
    writer.async { [weak self] in
      var status = zigonaut_search_status_v1()
      zigonaut_core_search_navigate(core.pointer, forward, &status)
      DispatchQueue.main.async {
        self?.applySearch(status)
        self?.refresh()
      }
    }
  }
  func navigatePrompt(forward: Bool) {
    guard let core else { return }
    writer.async { [weak self] in
      guard zigonaut_core_navigate_prompt(core.pointer, forward) else { return }
      DispatchQueue.main.async { self?.refresh() }
    }
  }
  func copyLastCommandOutput() {
    guard let core else { return }
    let command = preferences.pipeCommandOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    writer.async {
      let required = Int(zigonaut_core_last_command_output(core.pointer, nil, 0))
      guard required > 0, required <= 4_194_304 else { return }
      var output = [UInt8](repeating: 0, count: required)
      guard zigonaut_core_last_command_output(core.pointer, &output, output.count) == required else { return }
      if command.isEmpty {
        guard let value = String(bytes: output, encoding: .utf8) else { return }
        DispatchQueue.main.async {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(value, forType: .string)
        }
        return
      }

      let directoryRequired = Int(zigonaut_core_working_directory(core.pointer, nil, 0))
      var directory: String?
      if directoryRequired > 0, directoryRequired <= 16_384 {
        var bytes = [UInt8](repeating: 0, count: directoryRequired)
        if zigonaut_core_working_directory(core.pointer, &bytes, bytes.count) == directoryRequired {
          directory = String(bytes: bytes, encoding: .utf8)
        }
      }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = ["-lc", command]
      if let directory {
        let url = URL(string: directory)
        let path = url?.isFileURL == true ? url!.path : directory
        if FileManager.default.fileExists(atPath: path) {
          process.currentDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
      }
      let input = Pipe()
      process.standardInput = input
      do {
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(output))
        try input.fileHandleForWriting.close()
      } catch {
        try? input.fileHandleForWriting.close()
        NSSound.beep()
      }
    }
  }
  func clearSearch() {
    guard let core else { return }
    writer.async { [weak self] in
      zigonaut_core_search_clear(core.pointer)
      DispatchQueue.main.async {
        self?.searchMatchCount = 0
        self?.searchActiveIndex = nil
        self?.searchError = false
        self?.refresh()
      }
    }
  }
  private func applySearch(_ status: zigonaut_search_status_v1) {
    searchMatchCount = Int(status.matches)
    searchActiveIndex = status.active >= 0 ? Int(status.active) : nil
    searchError = status.status != 0
  }
  var mouseTracking: Bool {
    core.map { zigonaut_core_mouse_tracking($0.pointer) } ?? false
  }
  func sendMouse(
    action: UInt8, button: UInt8, x: Int, y: Int, width: Int, height: Int, cellWidth: Int,
    cellHeight: Int, padding: Int, modifiers: UInt16, pressed: Bool
  ) {
    guard let core else { return }
    writer.async {
      _ = zigonaut_core_mouse(
        core.pointer, action, button, Int32(clamping: x), Int32(clamping: y), UInt32(clamping: width),
        UInt32(clamping: height), UInt32(clamping: cellWidth), UInt32(clamping: cellHeight),
        UInt32(clamping: padding), modifiers, pressed)
    }
  }
  func selectionBegin(_ column: Int, _ row: Int) {
    if let core {
      zigonaut_core_selection_begin(core.pointer, UInt16(clamping: column), UInt16(clamping: row))
    }
  }
  func selectionUpdate(_ column: Int, _ row: Int) {
    if let core {
      zigonaut_core_selection_update(core.pointer, UInt16(clamping: column), UInt16(clamping: row))
    }
    refresh()
  }
  func selectionEnd() { if let core { zigonaut_core_selection_end(core.pointer) } }
  func copy() {
    guard let core else { return }
    let required = zigonaut_core_copy_selection(core.pointer, nil, 0)
    guard required > 0, required <= maximumSelectionBytes else { return }
    var bytes = [UInt8](repeating: 0, count: required)
    let count = zigonaut_core_copy_selection(core.pointer, &bytes, bytes.count)
    guard count == required, let value = String(bytes: bytes, encoding: .utf8) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
  deinit {
    guard let core else { return }
    zigonaut_core_request_stop(core.pointer)
    writer.sync {}
    zigonaut_core_destroy(core.pointer)
    callbackBox.takeRetainedValue().model = nil
  }
}

indirect enum PaneNode: Identifiable {
  case leaf(TerminalModel)
  case split(UUID, Axis, PaneNode, PaneNode)
  var id: UUID {
    switch self {
    case .leaf(let pane): pane.id
    case .split(let id, _, _, _): id
    }
  }
  func contains(_ id: UUID) -> Bool {
    switch self {
    case .leaf(let p): p.id == id
    case .split(_, _, let a, let b): a.contains(id) || b.contains(id)
    }
  }
  func replacing(_ target: UUID, with node: PaneNode) -> PaneNode {
    switch self {
    case .leaf(let p): return p.id == target ? node : self
    case .split(let id, let axis, let a, let b):
      return .split(id, axis, a.replacing(target, with: node), b.replacing(target, with: node))
    }
  }
  func removing(_ target: UUID) -> PaneNode? {
    switch self {
    case .leaf(let p): return p.id == target ? nil : self
    case .split(let id, let axis, let a, let b):
      let na = a.removing(target)
      let nb = b.removing(target)
      if na == nil { return nb }
      if nb == nil { return na }
      guard let na, let nb else { return nil }
      return .split(id, axis, na, nb)
    }
  }
  var leaves: [TerminalModel] {
    switch self {
    case .leaf(let p): [p]
    case .split(_, _, let a, let b): a.leaves + b.leaves
    }
  }
}

@MainActor final class WindowModel: ObservableObject {
  @Published var root: PaneNode
  @Published var focusedPane: UUID? {
    didSet {
      synchronizeTitleOwner()
      synchronizeFindOwner()
    }
  }
  @Published private(set) var title: String
  @Published var findVisible = false { didSet { synchronizeFindOwner() } }
  @Published var findQuery = ""
  @Published private(set) var findFocusRequest = 0
  private weak var searchOwner: TerminalModel?
  private var titleObservation: AnyCancellable?
  let preferences: Preferences
  init(preferences: Preferences) {
    self.preferences = preferences
    let pane = TerminalModel(shell: preferences.validShell, preferences: preferences)
    root = .leaf(pane)
    focusedPane = pane.id
    title = pane.title
    synchronizeTitleOwner()
  }
  var focused: TerminalModel? { root.leaves.first { $0.id == focusedPane } }
  func updateFindQuery(_ query: String) {
    findQuery = query
    synchronizeFindOwner()
    searchOwner?.setSearch(query)
  }
  func showFind() {
    findVisible = true
    findFocusRequest &+= 1
  }
  func navigateSearch(forward: Bool) {
    guard findVisible else { return }
    focused?.navigateSearch(forward: forward)
  }
  private func synchronizeFindOwner() {
    let newOwner = findVisible ? focused : nil
    guard searchOwner !== newOwner else { return }
    searchOwner?.clearSearch()
    searchOwner = newOwner
    if let newOwner { newOwner.setSearch(findQuery) }
  }
  private func synchronizeTitleOwner() {
    let owner = focused
    title = owner?.title ?? "Terminal"
    titleObservation = owner?.$title.sink { [weak self] value in self?.title = value }
  }
  func split(_ axis: Axis) {
    guard let focus = focusedPane,
      let existing = root.leaves.first(where: { $0.id == focus })
    else { return }
    let pane = TerminalModel(shell: preferences.validShell, preferences: preferences)
    root = root.replacing(focus, with: .split(UUID(), axis, .leaf(existing), .leaf(pane)))
    focusedPane = pane.id
  }
  /// Returns false when the native window tab itself should be closed.
  func closeFocused() -> Bool {
    guard let focus = focusedPane, let remaining = root.removing(focus) else { return false }
    root = remaining
    focusedPane = remaining.leaves.first?.id
    return true
  }
  func focus(_ delta: Int) {
    let leaves = root.leaves
    guard let p = leaves.firstIndex(where: { $0.id == focusedPane }) else { return }
    focusedPane = leaves[(p + delta + leaves.count) % leaves.count].id
  }
}
