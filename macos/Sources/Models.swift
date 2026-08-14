import AppKit
import Combine
import SwiftUI
import ZigonautAccessibility
import ZigonautCore
import ZigonautPaneLayout
import ZigonautRestoration

extension NSColor {
  convenience init(rgb: UInt32) {
    self.init(calibratedRed: CGFloat((rgb >> 16) & 0xff) / 255,
      green: CGFloat((rgb >> 8) & 0xff) / 255,
      blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
  }
}

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
  var cellsByRow: [[TerminalRenderCell]] = []
  var images: [TerminalRenderImage] = []
  var rowHashes: [UInt64] = []
  var viewportOffset: UInt64 = 0
}

struct TerminalImageKey: Hashable {
  let id: UInt32
  let generation: UInt64
}

struct TerminalLink {
  let url: URL
  let row: Int
  let startColumn: Int
  let endColumn: Int
}

struct TerminalRenderImage {
  let image: NSImage
  let cgImage: CGImage
  let key: TerminalImageKey
  let source: NSRect
  let sourcePixels: CGRect
  let pixelWidth: CGFloat
  let pixelHeight: CGFloat
  let viewportColumn: Int
  let viewportRow: Int
  let xOffset: CGFloat
  let yOffset: CGFloat
}

struct TerminalProgress: Equatable {
  enum State: UInt8 {
    case normal = 0
    case error = 1
    case indeterminate = 2
    case paused = 3
  }

  let state: State
  let value: Int
  let generation: UInt64
  let updatedAt: Date
}

struct TerminalPalette: Equatable {
  var foreground: UInt32
  var background: UInt32
  var cursor: UInt32
  var ansi: [UInt32]

  static let rasmus = TerminalPalette(
    foreground: 0xd1d1d1, background: 0x1a1a19, cursor: 0xd1d1d1,
    ansi: [0x333332, 0xff968c, 0x61957f, 0xffc591, 0x8db4d4, 0xde9bc8, 0x7bb099, 0xd1d1d1,
      0x4c4c4b, 0xffafa5, 0x7aae98, 0xffdeaa, 0xa6cded, 0xf7b4e1, 0x94c9b2, 0xeaeaea])

  static func load(_ name: String) -> TerminalPalette {
    guard name != "rasmus",
      let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Themes"),
      let data = try? Data(contentsOf: url),
      let value = try? JSONDecoder().decode(ThemeFile.self, from: data),
      let foreground = rgb(value.foreground), let background = rgb(value.background),
      let cursor = rgb(value.cursor), value.ansi.count == 16
    else { return .rasmus }
    let ansi = value.ansi.compactMap(rgb)
    guard ansi.count == 16 else { return .rasmus }
    return TerminalPalette(foreground: foreground, background: background, cursor: cursor, ansi: ansi)
  }

  static func rgb(_ text: String) -> UInt32? {
    let value = text.hasPrefix("#") ? String(text.dropFirst()) : text
    guard value.count == 6 else { return nil }
    return UInt32(value, radix: 16)
  }

  static func hex(_ value: UInt32) -> String { String(format: "#%06X", value & 0xffffff) }

  private struct ThemeFile: Decodable {
    let foreground: String
    let background: String
    let cursor: String
    let ansi: [String]
  }
}

@MainActor final class Preferences: ObservableObject {
  static let defaultFontFamily = "System Monospaced"
  static let defaultFontSize = 14.0
  static let defaultPadding = 8.0
  static let themeNames = ["rasmus", "campbell", "campbell-light", "fluent-dark", "fluent-light", "solarized-dark"]
  static let fontWeights = ["Thin", "Ultra Light", "Light", "Regular", "Medium", "Semibold", "Bold", "Heavy", "Black"]
  static let monospacedFontFamilies = NSFontManager.shared.availableFontFamilies.filter { family in
    NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)?.isFixedPitch == true
  }.sorted()

  @AppStorage("fontFamily") var fontFamily = defaultFontFamily
  @AppStorage("fontSize") var fontSize = 14.0
  @AppStorage("paddingHorizontal") var paddingHorizontal = 8.0
  @AppStorage("paddingVertical") var paddingVertical = 8.0
  @AppStorage("paddingBalance") var paddingBalance = "Top Left"
  @AppStorage("paddingColor") var paddingColor = "Background"
  @AppStorage("colourScheme") var colourScheme = "System"
  @AppStorage("windowMaterial") var windowMaterial = "Window"
  @AppStorage("darkTerminalTheme") var darkTerminalTheme = "fluent-dark"
  @AppStorage("lightTerminalTheme") var lightTerminalTheme = "fluent-light"
  @AppStorage("paletteOverrides") var paletteOverrides = "{}"
  @AppStorage("randomizeTabBackground") var randomizeTabBackground = true
  @AppStorage("shellPath") var shellPath = "/bin/zsh"
  @AppStorage("opacity") var opacity = 1.0
  @AppStorage("fontWeight") var fontWeight = "Regular"
  @AppStorage("intenseFontWeight") var intenseFontWeight = "Bold"
  @AppStorage("scrollbackSize") var scrollbackSize = 10_000
  @AppStorage("initialColumns") var initialColumns = 80
  @AppStorage("initialRows") var initialRows = 24
  @AppStorage("terminalClipboardWrites") var terminalClipboardWrites = false
  @AppStorage("terminalClipboardMaxBytes") var terminalClipboardMaxBytes = 1_048_576
  @AppStorage("pipeCommandOutput") var pipeCommandOutput = ""

  var validShell: String {
    shellPath.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: shellPath)
      ? shellPath : "/bin/zsh"
  }

  func terminalFont(size: CGFloat, weightName: String? = nil) -> NSFont {
    let name = weightName ?? fontWeight
    let weight = Self.fontWeight(named: name)
    guard fontFamily != Self.defaultFontFamily,
      let selected = NSFontManager.shared.font(withFamily: fontFamily, traits: [],
        weight: Self.fontManagerWeight(named: name), size: size), selected.isFixedPitch
    else {
      return .monospacedSystemFont(ofSize: size, weight: weight)
    }
    return selected
  }

  func terminalPalette(dark: Bool, seed: UInt64) -> TerminalPalette {
    var palette = TerminalPalette.load(dark ? darkTerminalTheme : lightTerminalTheme)
    for (key, value) in overrideValues() {
      guard let rgb = TerminalPalette.rgb(value) else { continue }
      switch key {
      case "foreground": palette.foreground = rgb
      case "background": palette.background = rgb
      case "cursor": palette.cursor = rgb
      default:
        if key.hasPrefix("ansi"), let index = Int(key.dropFirst(4)), palette.ansi.indices.contains(index) {
          palette.ansi[index] = rgb
        }
      }
    }
    if randomizeTabBackground {
      let accent = Self.hue(seed)
      let background = palette.background
      let red = (((background >> 16) & 0xff) * 7 + accent.0 + 4) / 8
      let green = (((background >> 8) & 0xff) * 7 + accent.1 + 4) / 8
      let blue = ((background & 0xff) * 7 + accent.2 + 4) / 8
      palette.background = red << 16 | green << 8 | blue
    }
    return palette
  }

  func overrideColor(_ key: String, fallback: UInt32) -> Color {
    Color(nsColor: NSColor(rgb: TerminalPalette.rgb(overrideValues()[key] ?? "") ?? fallback))
  }

  func setOverrideColor(_ color: Color, for key: String) {
    guard let converted = NSColor(color).usingColorSpace(.deviceRGB) else { return }
    let rgb = UInt32((converted.redComponent * 255).rounded()) << 16
      | UInt32((converted.greenComponent * 255).rounded()) << 8
      | UInt32((converted.blueComponent * 255).rounded())
    var values = overrideValues()
    values[key] = TerminalPalette.hex(rgb)
    if let data = try? JSONEncoder().encode(values), let text = String(data: data, encoding: .utf8) {
      paletteOverrides = text
    }
  }

  func clearOverride(_ key: String) {
    var values = overrideValues()
    values.removeValue(forKey: key)
    if let data = try? JSONEncoder().encode(values), let text = String(data: data, encoding: .utf8) {
      paletteOverrides = text
    }
  }

  func hasOverride(_ key: String) -> Bool { overrideValues()[key] != nil }

  private func overrideValues() -> [String: String] {
    guard let data = paletteOverrides.data(using: .utf8),
      let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
    return values
  }

  private static func fontWeight(named name: String) -> NSFont.Weight {
    switch name {
    case "Thin": return .thin
    case "Ultra Light": return .ultraLight
    case "Light": return .light
    case "Medium": return .medium
    case "Semibold": return .semibold
    case "Bold": return .bold
    case "Heavy": return .heavy
    case "Black": return .black
    default: return .regular
    }
  }

  private static func fontManagerWeight(named name: String) -> Int {
    switch name {
    case "Thin": return 1
    case "Ultra Light": return 2
    case "Light": return 3
    case "Medium": return 7
    case "Semibold": return 9
    case "Bold": return 10
    case "Heavy": return 12
    case "Black": return 14
    default: return 5
    }
  }

  private static func hue(_ seed: UInt64) -> (UInt32, UInt32, UInt32) {
    let hue = UInt32(seed % 1536)
    let sector = hue / 256
    let offset = hue % 256
    let rising = 32 + offset * 223 / 255
    let falling = 255 - offset * 223 / 255
    switch sector {
    case 0: return (255, rising, 32)
    case 1: return (falling, 255, 32)
    case 2: return (32, 255, rising)
    case 3: return (32, falling, 255)
    case 4: return (rising, 32, 255)
    default: return (255, 32, falling)
    }
  }

  func restoreDefaults() {
    fontFamily = Self.defaultFontFamily
    fontSize = Self.defaultFontSize
    paddingHorizontal = Self.defaultPadding
    paddingVertical = Self.defaultPadding
    paddingBalance = "Top Left"
    paddingColor = "Background"
    colourScheme = "System"
    windowMaterial = "Window"
    darkTerminalTheme = "fluent-dark"
    lightTerminalTheme = "fluent-light"
    paletteOverrides = "{}"
    randomizeTabBackground = true
    shellPath = "/bin/zsh"
    opacity = 1
    fontWeight = "Regular"
    intenseFontWeight = "Bold"
    scrollbackSize = 10_000
    initialColumns = 80
    initialRows = 24
    terminalClipboardWrites = false
    terminalClipboardMaxBytes = 1_048_576
    pipeCommandOutput = ""
  }
}

@MainActor final class TerminalModel: ObservableObject, Identifiable, @unchecked Sendable {
  let id: UUID
  @Published private(set) var text = "Starting shell…"
  @Published private(set) var title: String
  @Published private(set) var renderSnapshot = TerminalRenderSnapshot()
  @Published private(set) var searchMatchCount = 0
  @Published private(set) var searchActiveIndex: Int?
  @Published private(set) var searchError = false
  @Published private(set) var progress: TerminalProgress?
  @Published private(set) var outputGeneration: UInt64 = 0
  nonisolated(unsafe) private var core: TerminalCoreHandle?
  nonisolated private let writer = DispatchQueue(label: "dev.zigonaut.pty-writer")
  nonisolated private let callbackBox: Unmanaged<TerminalCallbackBox>
  private var cellBuffer = [zigonaut_render_cell_v1](
    repeating: zigonaut_render_cell_v1(), count: 80 * 24)
  private var textBuffer = [UInt8](repeating: 0, count: 80 * 24 * 4)
  private var hashBuffer = [UInt64](repeating: 0, count: 24)
  private var retainedCellsByRow = [[TerminalRenderCell]]()
  private var imageBuffer = [zigonaut_render_image_v1](repeating: zigonaut_render_image_v1(), count: 4)
  private var imageData = [UInt8](repeating: 0, count: 1_048_576)
  private var imageCache: [TerminalImageKey: CGImage] = [:]
  private var currentColumns = 80
  private var currentRows = 24
  private var currentPixelWidth = 0
  private var currentPixelHeight = 0
  private var currentCellWidth = 0
  private var currentCellHeight = 0
  private var currentScale: CGFloat = 1
  private var progressGeneration: UInt64 = 0
  private let maximumCells = 500_000
  private let maximumTextBytes = 8_000_000
  private let maximumImages = 256
  private let maximumImageBytes = 64 * 1_024 * 1_024
  // Selection pasteboard writes are all-or-nothing and capped to bound memory use.
  private let maximumSelectionBytes = 4_194_304
  private let preferences: Preferences
  private let defaultTitle: String
  var themeSeed: UInt64 { id.uuidString.utf8.reduce(5381) { ($0 &* 33) &+ UInt64($1) } }

  init(id: UUID = UUID(), shell: String, workingDirectory: String? = nil, preferences: Preferences) {
    self.id = id
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
        if let workingDirectory {
          return workingDirectory.withCString { directory in
            zigonaut_core_create(helperPath, shellPath, directory, terminalWake, callbackBox.toOpaque())
          }
        }
        return zigonaut_core_create(helperPath, shellPath, nil, terminalWake, callbackBox.toOpaque())
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
    let generation = zigonaut_core_output_generation(core.pointer)
    if generation != outputGeneration { outputGeneration = generation }
    retrieveTitle(core: core.pointer)
    retrieveProgress(core: core.pointer)
    drainNotifications(core: core.pointer)
    drainClipboard(core: core.pointer)
  }

  private func retrieveProgress(core: OpaquePointer) {
    var result = zigonaut_progress_v1()
    zigonaut_core_progress(core, &result)
    guard result.generation != progressGeneration else { return }
    progressGeneration = result.generation
    guard result.active != 0, let state = TerminalProgress.State(rawValue: result.state) else {
      progress = nil
      return
    }
    progress = TerminalProgress(state: state, value: min(100, Int(result.value)),
      generation: result.generation, updatedAt: Date())
  }

  var hasForegroundJob: Bool {
    guard let core else { return false }
    return zigonaut_core_has_foreground_job(core.pointer)
  }

  func link(column: Int, row: Int) -> TerminalLink? {
    guard let core else { return nil }
    var bytes = [UInt8](repeating: 0, count: 2048)
    var startColumn: UInt16 = 0
    var endColumn: UInt16 = 0
    let required = zigonaut_core_link_at(core.pointer, UInt16(clamping: column),
      UInt16(clamping: row), &bytes, UInt32(bytes.count), &startColumn, &endColumn)
    guard required > 0, required <= bytes.count,
      let value = String(bytes: bytes.prefix(Int(required)), encoding: .utf8),
      let url = URL(string: value) else { return nil }
    return TerminalLink(url: url, row: row, startColumn: Int(startColumn), endColumn: Int(endColumn))
  }
  func applyClipboardSettings() {
    if let core {
      zigonaut_core_set_clipboard_write(core.pointer, preferences.terminalClipboardWrites,
        UInt32(clamping: preferences.terminalClipboardMaxBytes))
    }
  }
  func applyTerminalSettings(palette: TerminalPalette, scrollback: Int) {
    guard let core else { return }
    var value = zigonaut_terminal_theme_v1()
    value.version = 1
    value.size = UInt32(MemoryLayout<zigonaut_terminal_theme_v1>.size)
    value.foreground_rgb = palette.foreground
    value.background_rgb = palette.background
    value.cursor_rgb = palette.cursor
    withUnsafeMutableBytes(of: &value.ansi_rgb) { bytes in
      let destination = bytes.bindMemory(to: UInt32.self)
      for (index, color) in palette.ansi.prefix(destination.count).enumerated() {
        destination[index] = color
      }
    }
    _ = zigonaut_core_set_theme(core.pointer, &value)
    _ = zigonaut_core_set_scrollback(core.pointer, UInt32(clamping: scrollback))
    DispatchQueue.main.async { [weak self] in self?.refresh() }
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
    renderSnapshot.rowHashes.withUnsafeBufferPointer { previous in
      hashBuffer.withUnsafeMutableBufferPointer { hashes in
        cellBuffer.withUnsafeMutableBufferPointer { cells in
          textBuffer.withUnsafeMutableBufferPointer { bytes in
            zigonaut_core_render_snapshot(
              core,
              previous.baseAddress,
              UInt32(clamping: previous.count),
              &frame,
              cells.baseAddress,
              UInt32(clamping: cells.count),
              bytes.baseAddress,
              UInt32(clamping: bytes.count),
              hashes.baseAddress,
              UInt32(clamping: hashes.count),
              &result
            )
          }
        }
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
      let requiredRows = Int(result.required_rows)
      if requiredRows > hashBuffer.count {
        hashBuffer = [UInt64](repeating: 0, count: requiredRows)
      }
      if requiredCells <= maximumCells && requiredText <= maximumTextBytes
        && requiredRows <= currentRows
      {
        retrieveSnapshot(core: core, retry: false)
        return
      }
    }
    guard result.status == 0 else {
      return
    }
    let count = min(Int(result.written_cells), cellBuffer.count)
    let cells = cellBuffer.prefix(count).enumerated().map { index, cell in
      let start = min(Int(cell.text_offset), textBuffer.count)
      let end = min(start + Int(cell.text_length), textBuffer.count)
      return TerminalRenderCell(
        id: Int(cell.y) * max(currentColumns, 1) + Int(cell.x),
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
    let rowCount = Int(result.written_rows)
    let rowHashes = Array(hashBuffer.prefix(rowCount))
    if retainedCellsByRow.count != rowCount {
      retainedCellsByRow = [[TerminalRenderCell]](repeating: [], count: rowCount)
    }
    var dirtyCells = [[TerminalRenderCell]](repeating: [], count: rowCount)
    for cell in cells where dirtyCells.indices.contains(cell.y) {
      dirtyCells[cell.y].append(cell)
    }
    for row in rowHashes.indices
      where renderSnapshot.rowHashes.count != rowCount || renderSnapshot.rowHashes[row] != rowHashes[row]
    {
      retainedCellsByRow[row] = dirtyCells[row]
    }
    let images = retrieveImages(core: core)
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
      cells: retainedCellsByRow.flatMap { $0 },
      cellsByRow: retainedCellsByRow,
      images: images,
      rowHashes: rowHashes,
      viewportOffset: result.viewport_offset
    )
  }

  private func retrieveImages(core: OpaquePointer, retry: Bool = true) -> [TerminalRenderImage] {
    var result = zigonaut_render_images_result_v1()
    var knownGenerations = imageCache.keys.map {
      zigonaut_image_generation_v1(image_id: $0.id, reserved: 0, generation: $0.generation)
    }
    knownGenerations.withUnsafeMutableBufferPointer { known in
      imageBuffer.withUnsafeMutableBufferPointer { images in
        imageData.withUnsafeMutableBufferPointer { bytes in
          zigonaut_core_render_images(core, known.baseAddress, UInt32(clamping: known.count),
            images.baseAddress, UInt32(clamping: images.count), bytes.baseAddress,
            UInt32(clamping: bytes.count), &result)
        }
      }
    }
    if retry && result.status == 1 {
      let requiredImages = min(Int(result.required_images), maximumImages)
      let requiredBytes = min(Int(result.required_data_bytes), maximumImageBytes)
      if requiredImages > imageBuffer.count {
        imageBuffer = [zigonaut_render_image_v1](repeating: zigonaut_render_image_v1(), count: requiredImages)
      }
      if requiredBytes > imageData.count {
        imageData = [UInt8](repeating: 0, count: requiredBytes)
      }
      if requiredImages <= maximumImages && requiredBytes <= maximumImageBytes {
        return retrieveImages(core: core, retry: false)
      }
    }
    guard result.status == 0 else { return [] }
    var activeKeys = Set<TerminalImageKey>()
    let placements = imageBuffer.prefix(min(Int(result.written_images), imageBuffer.count))
    // Install every payload before resolving placements, so duplicate records
    // remain valid even if the payload-bearing record ordering changes.
    for placement in placements where placement.data_length > 0 {
      let key = TerminalImageKey(id: placement.image_id, generation: placement.generation)
      let start = Int(placement.data_offset)
      let end = start + Int(placement.data_length)
      guard start >= 0, end <= imageData.count, placement.width > 0, placement.height > 0,
        Int(placement.data_length) == Int(placement.width) * Int(placement.height) * 4 else { return [] }
      let data = Data(imageData[start..<end]) as CFData
      guard let provider = CGDataProvider(data: data),
        let value = CGImage(width: Int(placement.width), height: Int(placement.height),
          bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(placement.width) * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
          provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
      else { return [] }
      imageCache[key] = value
    }
    let rendered = placements.compactMap { placement -> TerminalRenderImage? in
      let key = TerminalImageKey(id: placement.image_id, generation: placement.generation)
      activeKeys.insert(key)
      guard let cgImage = imageCache[key] else { return nil }
      return TerminalRenderImage(
        image: NSImage(cgImage: cgImage,
          size: NSSize(width: Int(placement.width), height: Int(placement.height))),
        cgImage: cgImage,
        key: key,
        source: NSRect(x: Int(placement.source_x),
          y: Int(placement.height - placement.source_y - placement.source_height),
          width: Int(placement.source_width), height: Int(placement.source_height)),
        sourcePixels: CGRect(x: Int(placement.source_x), y: Int(placement.source_y),
          width: Int(placement.source_width), height: Int(placement.source_height)),
        pixelWidth: CGFloat(placement.pixel_width) / currentScale,
        pixelHeight: CGFloat(placement.pixel_height) / currentScale,
        viewportColumn: Int(placement.viewport_column), viewportRow: Int(placement.viewport_row),
        xOffset: CGFloat(placement.x_offset) / currentScale,
        yOffset: CGFloat(placement.y_offset) / currentScale)
    }
    guard rendered.count == placements.count else { return [] }
    imageCache = imageCache.filter { activeKeys.contains($0.key) }
    return rendered
  }

  func accessibilityLayout() -> TerminalAccessibilityLayout {
    let snapshot = renderSnapshot
    return TerminalAccessibilityLayout(
      columns: currentColumns,
      rows: currentRows,
      cells: snapshot.cells.map {
        AccessibilityCell(column: $0.x, row: $0.y, text: $0.text,
          columns: $0.occupancy == 1 ? 2 : 1, continuation: $0.occupancy == 2,
          selected: $0.selected)
      },
      cursorColumn: snapshot.frame.cursorX,
      cursorRow: snapshot.frame.cursorY
    )
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
  @discardableResult
  func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int, cellWidth: Int, cellHeight: Int,
    scale: CGFloat)
    -> Bool
  {
    let snapshotGeometryChanged = columns != currentColumns || rows != currentRows
      || cellWidth != currentCellWidth || cellHeight != currentCellHeight || scale != currentScale
    guard snapshotGeometryChanged || pixelWidth != currentPixelWidth || pixelHeight != currentPixelHeight
    else { return false }
    currentColumns = columns
    currentRows = rows
    currentPixelWidth = pixelWidth
    currentPixelHeight = pixelHeight
    currentCellWidth = cellWidth
    currentCellHeight = cellHeight
    currentScale = scale
    if let core {
      zigonaut_core_resize(core.pointer, UInt16(clamping: columns), UInt16(clamping: rows),
        UInt16(clamping: pixelWidth), UInt16(clamping: pixelHeight),
        UInt32(clamping: cellWidth), UInt32(clamping: cellHeight))
    }
    return snapshotGeometryChanged
  }
  func write(_ value: String) { enqueue(value, paste: false) }
  func paste(_ value: String) { enqueue(value, paste: true) }
  func sendKey(keyCode: UInt16, modifiers: UInt16, consumedModifiers: UInt16, action: UInt8,
    unshiftedCodepoint: UInt32, utf8: [UInt8])
  {
    guard let core else { return }
    writer.async {
      utf8.withUnsafeBufferPointer { buffer in
        var event = zigonaut_key_event_v1()
        event.version = 1
        event.size = UInt32(MemoryLayout<zigonaut_key_event_v1>.size)
        event.key_code = keyCode
        event.modifiers = modifiers
        event.consumed_modifiers = consumedModifiers
        event.utf8_length = UInt16(buffer.count)
        event.action = action
        event.unshifted_codepoint = unshiftedCodepoint
        event.utf8 = buffer.baseAddress
        _ = zigonaut_core_key(core.pointer, &event)
      }
    }
  }
  private func enqueue(_ value: String, paste: Bool) {
    guard let core else { return }
    let bytes = Array(value.utf8)
    if !paste && (value.contains("\r") || value.contains("\n")) {
      // The foreground process group changes shortly after the shell accepts
      // Enter. Refresh its fallback title without introducing an idle timer.
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
        guard let self, let core = self.core else { return }
        self.retrieveTitle(core: core.pointer)
      }
    }
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
  func restorationDirectory() -> String? {
    guard let core else { return nil }
    let required = Int(zigonaut_core_working_directory(core.pointer, nil, 0))
    guard required > 0, required <= 16_384 else { return nil }
    var bytes = [UInt8](repeating: 0, count: required)
    guard zigonaut_core_working_directory(core.pointer, &bytes, bytes.count) == required,
      let value = String(bytes: bytes, encoding: .utf8) else { return nil }
    let url = URL(string: value)
    let path = url?.isFileURL == true ? url!.path : value
    var isDirectory: ObjCBool = false
    guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue else { return nil }
    return path
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
    cellHeight: Int, paddingTop: Int, paddingBottom: Int, paddingLeft: Int, paddingRight: Int,
    modifiers: UInt16, pressed: Bool
  ) {
    guard let core else { return }
    writer.async {
      _ = zigonaut_core_mouse(
        core.pointer, action, button, Int32(clamping: x), Int32(clamping: y), UInt32(clamping: width),
        UInt32(clamping: height), UInt32(clamping: cellWidth), UInt32(clamping: cellHeight),
        UInt32(clamping: paddingTop), UInt32(clamping: paddingBottom), UInt32(clamping: paddingLeft),
        UInt32(clamping: paddingRight), modifiers, pressed)
    }
  }
  func selectionBegin(_ column: Int, _ row: Int, unit: UInt8, rectangle: Bool) {
    if let core {
      zigonaut_core_selection_begin(core.pointer, UInt16(clamping: column), UInt16(clamping: row), unit, rectangle)
    }
  }
  func selectionUpdate(_ column: Int, _ row: Int) {
    if let core {
      zigonaut_core_selection_update(core.pointer, UInt16(clamping: column), UInt16(clamping: row))
    }
    refresh()
  }
  func selectionEnd() { if let core { zigonaut_core_selection_end(core.pointer) } }
  func clearSelection() { if let core { zigonaut_core_selection_clear(core.pointer) } }
  var hasSelection: Bool { core.map { zigonaut_core_has_selection($0.pointer) } ?? false }
  var acceptsPaste: Bool { core != nil }
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

@MainActor indirect enum PaneNode {
  case leaf(TerminalModel)
  case split(UUID, Axis, Double, PaneNode, PaneNode)
  var id: UUID {
    switch self {
    case .leaf(let pane): pane.id
    case .split(let id, _, _, _, _): id
    }
  }
  func contains(_ id: UUID) -> Bool {
    switch self {
    case .leaf(let p): p.id == id
    case .split(_, _, _, let a, let b): a.contains(id) || b.contains(id)
    }
  }
  func replacing(_ target: UUID, with node: PaneNode) -> PaneNode {
    switch self {
    case .leaf(let p): return p.id == target ? node : self
    case .split(let id, let axis, let ratio, let a, let b):
      return .split(id, axis, ratio, a.replacing(target, with: node), b.replacing(target, with: node))
    }
  }
  func removing(_ target: UUID) -> PaneNode? {
    switch self {
    case .leaf(let p): return p.id == target ? nil : self
    case .split(let id, let axis, let ratio, let a, let b):
      let na = a.removing(target)
      let nb = b.removing(target)
      if na == nil { return nb }
      if nb == nil { return na }
      guard let na, let nb else { return nil }
      return .split(id, axis, ratio, na, nb)
    }
  }
  var leaves: [TerminalModel] {
    switch self {
    case .leaf(let p): [p]
    case .split(_, _, _, let a, let b): a.leaves + b.leaves
    }
  }
  func settingRatio(_ target: UUID, _ ratio: Double) -> PaneNode {
    switch self {
    case .leaf: self
    case .split(let id, let axis, let old, let first, let second):
      id == target ? .split(id, axis, ratio, first, second)
        : .split(id, axis, old, first.settingRatio(target, ratio), second.settingRatio(target, ratio))
    }
  }
  func node(_ target: UUID) -> PaneNode? {
    if id == target { return self }
    switch self {
    case .leaf: return nil
    case .split(_, _, _, let first, let second): return first.node(target) ?? second.node(target)
    }
  }
  func canResize(_ target: UUID, axis wanted: Axis) -> Bool {
    switch self {
    case .leaf: return false
    case .split(_, let axis, _, let first, let second):
      guard first.contains(target) || second.contains(target) else { return false }
      let child = first.contains(target) ? first : second
      return child.canResize(target, axis: wanted) || axis == wanted
    }
  }
  func resizing(_ target: UUID, direction: PaneFocusDirection, amount: Double) -> (PaneNode, Bool) {
    switch self {
    case .leaf: return (self, false)
    case .split(let id, let axis, let ratio, let first, let second):
      guard first.contains(target) || second.contains(target) else { return (self, false) }
      let wanted: Axis = direction == .left || direction == .right ? .horizontal : .vertical
      if first.contains(target) {
        if first.canResize(target, axis: wanted) {
          let (resized, changed) = first.resizing(target, direction: direction, amount: amount)
          return (.split(id, axis, ratio, resized, second), changed)
        }
      } else {
        if second.canResize(target, axis: wanted) {
          let (resized, changed) = second.resizing(target, direction: direction, amount: amount)
          return (.split(id, axis, ratio, first, resized), changed)
        }
      }
      guard axis == wanted else { return (self, false) }
      let delta = direction == .left || direction == .up ? -amount : amount
      let resized = min(max(ratio + delta, 0.1), 0.9)
      return (.split(id, axis, resized, first, second), resized != ratio)
    }
  }
  func axisWeight(_ wanted: Axis) -> Int {
    switch self {
    case .leaf: return 1
    case .split(_, let axis, _, let first, let second):
      return axis == wanted ? first.axisWeight(wanted) + second.axisWeight(wanted) : 1
    }
  }
  func equalized() -> PaneNode {
    switch self {
    case .leaf: return self
    case .split(let id, let axis, _, let first, let second):
      let firstWeight = first.axisWeight(axis)
      let secondWeight = second.axisWeight(axis)
      return .split(id, axis, Double(firstWeight) / Double(firstWeight + secondWeight),
        first.equalized(), second.equalized())
    }
  }
  var saved: SavedPaneNode {
    switch self {
    case .leaf(let pane): .leaf(SavedPane(id: pane.id, directory: pane.restorationDirectory()))
    case .split(let id, let axis, let ratio, let first, let second):
      .split(id, axis == .horizontal ? .horizontal : .vertical, ratio, first.saved, second.saved)
    }
  }
}

@MainActor final class WindowModel: ObservableObject {
  @Published var root: PaneNode
  @Published var focusedPane: UUID? {
    didSet {
      if zoomedPane != nil { zoomedPane = focusedPane }
      synchronizeTitleOwner()
      synchronizeFindOwner()
      stateChanged?()
    }
  }
  @Published private(set) var zoomedPane: UUID?
  @Published private(set) var title: String
  @Published private(set) var progress: TerminalProgress?
  @Published private(set) var outputGeneration: UInt64 = 0
  @Published var findVisible = false { didSet { synchronizeFindOwner() } }
  @Published var findQuery = ""
  @Published private(set) var findFocusRequest = 0
  private weak var searchOwner: TerminalModel?
  private var titleObservation: AnyCancellable?
  private var progressObservation: AnyCancellable?
  private var outputObservations: [UUID: AnyCancellable] = [:]
  private var paneFrames: [UUID: CGRect] = [:]
  let preferences: Preferences
  var stateChanged: (() -> Void)?
  init(preferences: Preferences) {
    self.preferences = preferences
    let pane = TerminalModel(shell: preferences.validShell, preferences: preferences)
    root = .leaf(pane)
    zoomedPane = nil
    focusedPane = pane.id
    title = pane.title
    synchronizeTitleOwner()
    synchronizeOutputOwners()
  }
  init(saved: SavedTab, preferences: Preferences) {
    self.preferences = preferences
    func restore(_ node: SavedPaneNode) -> PaneNode {
      switch node {
      case .leaf(let pane):
        return .leaf(TerminalModel(id: pane.id, shell: preferences.validShell,
          workingDirectory: pane.directory, preferences: preferences))
      case .split(let id, let axis, let ratio, let first, let second):
        return .split(id, axis == .horizontal ? .horizontal : .vertical, ratio,
          restore(first), restore(second))
      }
    }
    let restored = restore(saved.root)
    root = restored
    zoomedPane = nil
    focusedPane = restored.contains(saved.focusedPane) ? saved.focusedPane : restored.leaves[0].id
    title = restored.leaves.first?.title ?? "Terminal"
    synchronizeTitleOwner()
    synchronizeOutputOwners()
  }
  var saved: SavedTab { SavedTab(root: root.saved, focusedPane: focusedPane ?? root.leaves[0].id) }
  var focused: TerminalModel? { root.leaves.first { $0.id == focusedPane } }
  var panes: [TerminalModel] { root.leaves }
  var visibleRoot: PaneNode { zoomedPane.flatMap { root.node($0) } ?? root }
  var foregroundJobCount: Int { panes.filter(\.hasForegroundJob).count }
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
    progress = owner?.progress
    titleObservation = owner?.$title.sink { [weak self] value in self?.title = value }
    progressObservation = owner?.$progress.sink { [weak self] value in self?.progress = value }
  }
  private func synchronizeOutputOwners() {
    let active = Set(panes.map(\.id))
    outputObservations = outputObservations.filter { active.contains($0.key) }
    for pane in panes where outputObservations[pane.id] == nil {
      outputObservations[pane.id] = pane.$outputGeneration.dropFirst().sink { [weak self] _ in
        self?.outputGeneration &+= 1
      }
    }
  }
  func split(_ axis: Axis) {
    guard let focus = focusedPane,
      let existing = root.leaves.first(where: { $0.id == focus })
    else { return }
    let pane = TerminalModel(shell: preferences.validShell, preferences: preferences)
    root = root.replacing(focus, with: .split(UUID(), axis, 0.5, .leaf(existing), .leaf(pane)))
    synchronizeOutputOwners()
    zoomedPane = nil
    focusedPane = pane.id
    stateChanged?()
  }
  func setRatio(_ id: UUID, _ ratio: Double) {
    root = root.settingRatio(id, min(max(ratio, 0.1), 0.9))
    stateChanged?()
  }
  /// Returns false when the native window tab itself should be closed.
  func closeFocused() -> Bool {
    guard let focus = focusedPane else { return false }
    return closePane(focus)
  }
  /// Returns false when removing this pane means closing the native tab.
  func closePane(_ pane: UUID) -> Bool {
    guard root.contains(pane), let remaining = root.removing(pane) else { return false }
    root = remaining
    synchronizeOutputOwners()
    if zoomedPane == pane { zoomedPane = nil }
    focusedPane = remaining.leaves.first?.id
    stateChanged?()
    return true
  }
  func updatePaneFrames(_ frames: [UUID: CGRect]) {
    let visible = Set(visibleRoot.leaves.map(\.id))
    paneFrames = frames.filter { visible.contains($0.key) }
  }
  func focus(_ direction: PaneFocusDirection) {
    guard let focusedPane,
      let destination = DirectionalPaneFocus.destination(from: focusedPane, direction: direction,
        frames: paneFrames, stableOrder: root.leaves.map(\.id)) else { return }
    self.focusedPane = destination
  }
  func focusCycle(forward: Bool) {
    let leaves = root.leaves
    guard leaves.count > 1, let focusedPane,
      let index = leaves.firstIndex(where: { $0.id == focusedPane }) else { return }
    let destination = forward ? (index + 1) % leaves.count : (index + leaves.count - 1) % leaves.count
    self.focusedPane = leaves[destination].id
  }
  func canResize(_ direction: PaneFocusDirection) -> Bool {
    guard let focusedPane else { return false }
    let axis: Axis = direction == .left || direction == .right ? .horizontal : .vertical
    return root.canResize(focusedPane, axis: axis)
  }
  func resize(_ direction: PaneFocusDirection) {
    guard let focusedPane else { return }
    let (resized, changed) = root.resizing(focusedPane, direction: direction, amount: 0.05)
    guard changed else { return }
    root = resized
    zoomedPane = nil
    stateChanged?()
  }
  func equalizePanes() {
    guard panes.count > 1 else { return }
    root = root.equalized()
    stateChanged?()
  }
  func togglePaneZoom() {
    guard panes.count > 1 else { return }
    zoomedPane = zoomedPane == nil ? focusedPane : nil
    stateChanged?()
  }
  func canFocus(_ direction: PaneFocusDirection) -> Bool {
    guard let focusedPane else { return false }
    return DirectionalPaneFocus.destination(from: focusedPane, direction: direction,
      frames: paneFrames, stableOrder: root.leaves.map(\.id)) != nil
  }
}
