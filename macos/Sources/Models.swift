import AppKit
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
    while true {
      lock.lock()
      dirty = false
      lock.unlock()
      model?.refresh()
      lock.lock()
      guard dirty else { scheduled = false; lock.unlock(); return }
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
  let searchHighlight: UInt8
}

struct TerminalRenderSnapshot {
  var frame = TerminalRenderFrame()
  var cells: [TerminalRenderCell] = []
}

@MainActor final class Preferences: ObservableObject {
  @AppStorage("fontSize") var fontSize = 14.0
  @AppStorage("padding") var padding = 8.0
  @AppStorage("colourScheme") var colourScheme = "System"
  @AppStorage("shellPath") var shellPath = "/bin/zsh"
  @AppStorage("opacity") var opacity = 1.0
  @AppStorage("terminalClipboardWrites") var terminalClipboardWrites = false
  @AppStorage("terminalClipboardMaxBytes") var terminalClipboardMaxBytes = 1_048_576

  var validShell: String {
    shellPath.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: shellPath)
      ? shellPath : "/bin/zsh"
  }
}

@MainActor final class TerminalModel: ObservableObject, Identifiable, @unchecked Sendable {
  let id = UUID()
  @Published private(set) var text = "Starting shell…"
  @Published private(set) var title = "Terminal"
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

  init(shell: String, preferences: Preferences) {
    self.preferences = preferences
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
    applyClipboardSettings()
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
    var rows = [Int: [(Int, String)]]()
    for cell in cells where cell.occupancy != 2 {
      rows[cell.y, default: []].append((cell.x, cell.text.isEmpty ? " " : cell.text))
    }
    text = rows.keys.sorted().map { row in
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
    title = value.isEmpty ? "Terminal" : value
  }
  func resize(columns: Int, rows: Int) {
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

struct TerminalTab: Identifiable {
  let id = UUID()
  var root: PaneNode
}

@MainActor final class WindowModel: ObservableObject {
  @Published var tabs: [TerminalTab] = []
  @Published var selectedTab: UUID? { didSet { synchronizeFindOwner() } }
  @Published var focusedPane: UUID? { didSet { synchronizeFindOwner() } }
  @Published var findVisible = false { didSet { synchronizeFindOwner() } }
  @Published var findQuery = ""
  private weak var searchOwner: TerminalModel?
  let preferences: Preferences
  init(preferences: Preferences) {
    self.preferences = preferences
    newTab()
  }
  var tabIndex: Int? { tabs.firstIndex { $0.id == selectedTab } }
  var focused: TerminalModel? {
    guard let i = tabIndex else { return nil }
    return tabs[i].root.leaves.first { $0.id == focusedPane }
  }
  func updateFindQuery(_ query: String) {
    findQuery = query
    synchronizeFindOwner()
    searchOwner?.setSearch(query)
  }
  private func synchronizeFindOwner() {
    let newOwner = findVisible ? focused : nil
    guard searchOwner !== newOwner else { return }
    searchOwner?.clearSearch()
    searchOwner = newOwner
    if let newOwner { newOwner.setSearch(findQuery) }
  }
  func newTab() {
    let pane = TerminalModel(shell: preferences.validShell, preferences: preferences)
    let tab = TerminalTab(root: .leaf(pane))
    tabs.append(tab)
    selectedTab = tab.id
    focusedPane = pane.id
  }
  func split(_ axis: Axis) {
    guard let i = tabIndex, let focus = focusedPane,
      let existing = tabs[i].root.leaves.first(where: { $0.id == focus })
    else { return }
    let pane = TerminalModel(shell: preferences.validShell, preferences: preferences)
    tabs[i].root = tabs[i].root.replacing(
      focus, with: .split(UUID(), axis, .leaf(existing), .leaf(pane)))
    focusedPane = pane.id
  }
  func closeFocused() {
    guard let i = tabIndex, let focus = focusedPane else { return }
    if let root = tabs[i].root.removing(focus) {
      tabs[i].root = root
      focusedPane = root.leaves.first?.id
    } else {
      tabs.remove(at: i)
      if tabs.isEmpty {
        newTab()
      } else {
        selectedTab = tabs[min(i, tabs.count - 1)].id
        focusedPane = tabs[min(i, tabs.count - 1)].root.leaves.first?.id
      }
    }
  }
  func selectTab(_ delta: Int) {
    guard !tabs.isEmpty, let i = tabIndex else { return }
    let n = (i + delta + tabs.count) % tabs.count
    selectedTab = tabs[n].id
    focusedPane = tabs[n].root.leaves.first?.id
  }
  func focus(_ delta: Int) {
    guard let i = tabIndex else { return }
    let leaves = tabs[i].root.leaves
    guard let p = leaves.firstIndex(where: { $0.id == focusedPane }) else { return }
    focusedPane = leaves[(p + delta + leaves.count) % leaves.count].id
  }
}
