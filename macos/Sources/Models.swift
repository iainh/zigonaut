import AppKit
import Combine
import OSLog
import SwiftUI
import ZigonautAccessibility
import ZigonautCore
import ZigonautPaneLayout
import ZigonautRenderSupport
import ZigonautRestoration

enum TerminalLatencyTrace {
  static let signposter = OSSignposter(
    subsystem: Bundle.main.bundleIdentifier ?? "com.zigonaut.terminal",
    category: "InputLatency")
}

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
  var mouseShape: UInt8 = 8
  var viewportRows: Int = 0
  var scrollOffset: CGFloat = 0
}

struct TerminalRenderSnapshot {
  var frame = TerminalRenderFrame()
  var cells = TerminalRenderCells()
  var cellsByRow: [PackedRenderRow] { cells.rows }
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

struct TerminalHint {
  let url: URL
  let label: zigonaut_hint_label_v1
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

  var isDark: Bool {
    let red = Double((background >> 16) & 0xff) / 255
    let green = Double((background >> 8) & 0xff) / 255
    let blue = Double(background & 0xff) / 255
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.5
  }

  static let rasmus = TerminalPalette(
    foreground: 0xd1d1d1, background: 0x1a1a19, cursor: 0xd1d1d1,
    ansi: [0x333332, 0xff968c, 0x61957f, 0xffc591, 0x8db4d4, 0xde9bc8, 0x7bb099, 0xd1d1d1,
      0x4c4c4b, 0xffafa5, 0x7aae98, 0xffdeaa, 0xa6cded, 0xf7b4e1, 0x94c9b2, 0xeaeaea])

  @MainActor private static var bundledPalettes: [String: TerminalPalette] = [:]

  @MainActor static func load(_ name: String) -> TerminalPalette {
    if let cached = bundledPalettes[name] { return cached }
    guard name != "rasmus",
      let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Themes"),
      let data = try? Data(contentsOf: url),
      let value = try? JSONDecoder().decode(ThemeFile.self, from: data),
      let foreground = rgb(value.foreground), let background = rgb(value.background),
      let cursor = rgb(value.cursor), value.ansi.count == 16
    else { return .rasmus }
    let ansi = value.ansi.compactMap(rgb)
    guard ansi.count == 16 else { return .rasmus }
    let palette = TerminalPalette(foreground: foreground, background: background, cursor: cursor, ansi: ansi)
    // Only bundled, valid themes enter this process-lifetime cache.
    bundledPalettes[name] = palette
    return palette
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
  static let themeNames: [String] = {
    let featured = [
      "merino-light", "alpine-milk", "buttercream-diner", "coastal-linen",
      "nocturne-rose", "oxblood-library", "petrol-lagoon", "phosphor-archive", "polar-aurora",
    ]
    let available = Set(
      ["rasmus"] + (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Themes") ?? [])
        .map { $0.deletingPathExtension().lastPathComponent }
    )
    return featured.filter(available.contains) + available.subtracting(featured).sorted()
  }()
  static let fontWeights = ["Thin", "Ultra Light", "Light", "Regular", "Medium", "Semibold", "Bold", "Heavy", "Black"]
  static let monospacedFontFamilies = NSFontManager.shared.availableFontFamilies.filter { family in
    NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)?.isFixedPitch == true
  }.sorted()

  @AppStorage("fontFamily") var fontFamily = defaultFontFamily
  @AppStorage("fontSize") var fontSize = 14.0
  @AppStorage("lineHeightPercent") var lineHeightPercent = 100.0
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
  @AppStorage("automaticShellIntegration") var automaticShellIntegration = true
  @AppStorage("commandCompletionNotifications") var commandCompletionNotifications = false
  @AppStorage("opacity") var opacity = 1.0
  @AppStorage("fontWeight") var fontWeight = "Regular"
  @AppStorage("intenseFontWeight") var intenseFontWeight = "Bold"
  @AppStorage("intenseTextStyle") var intenseTextStyle = "all"
  @AppStorage("scrollbackSize") var scrollbackSize = 10_000
  @AppStorage("initialColumns") var initialColumns = 80
  @AppStorage("initialRows") var initialRows = 24
  @AppStorage("terminalClipboardWrites") var terminalClipboardWrites = false
  @AppStorage("terminalClipboardMaxBytes") var terminalClipboardMaxBytes = 1_048_576
  @AppStorage("pipeCommandOutput") var pipeCommandOutput = ""

  private var resolvedPalettes: [Bool: (theme: String, overrides: String, palette: TerminalPalette)] = [:]

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

  func terminalPalette(dark: Bool, seed: UInt64? = nil) -> TerminalPalette {
    let theme = dark ? darkTerminalTheme : lightTerminalTheme
    let overrides = paletteOverrides
    var palette: TerminalPalette
    if let cached = resolvedPalettes[dark], cached.theme == theme, cached.overrides == overrides {
      palette = cached.palette
    } else {
      palette = TerminalPalette.load(theme)
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
      resolvedPalettes[dark] = (theme, overrides, palette)
    }
    if randomizeTabBackground, let seed {
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
    lineHeightPercent = 100
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
    automaticShellIntegration = true
    commandCompletionNotifications = false
    opacity = 1
    fontWeight = "Regular"
    intenseFontWeight = "Bold"
    intenseTextStyle = "all"
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
  @Published private(set) var programStatus = ""
  @Published private(set) var programStatusState: UInt8 = 0
  @Published private(set) var outputGeneration: UInt64 = 0
  @Published private(set) var exited = false
  nonisolated(unsafe) private var core: TerminalCoreHandle?
  nonisolated private let writer = DispatchQueue(label: "dev.zigonaut.pty-writer")
  nonisolated private let callbackBox: Unmanaged<TerminalCallbackBox>
  private var cellBuffer = [zigonaut_render_cell_v1](
    repeating: zigonaut_render_cell_v1(), count: 80 * 24)
  private var textBuffer = [UInt8](repeating: 0, count: 80 * 24 * 4)
  private var hashBuffer = [UInt64](repeating: 0, count: 24)
  private var retainedCellsByRow = [PackedRenderRow]()
  private var imageBuffer = [zigonaut_render_image_v1](repeating: zigonaut_render_image_v1(), count: 4)
  private var imageData = [UInt8](repeating: 0, count: 1_048_576)
  private var imageCache: [TerminalImageKey: CGImage] = [:]
  private var imagesNeedRefresh = true
  private var linkRevision: UInt64 = 0
  private var cachedLink: TerminalLink?
  private var latencySignpostID: OSSignpostID?
  private var currentColumns = 80
  private var currentRows = 24
  private var currentPixelWidth = 0
  private var currentPixelHeight = 0
  private var currentCellWidth = 0
  private var currentCellHeight = 0
  private var currentScale: CGFloat = 1
  private var progressGeneration: UInt64 = 0
  private var searchRequestGeneration: UInt64 = 0
  private var compressionRequestGeneration: UInt64 = 0
  private let maximumCells = 500_000
  private let maximumTextBytes = 8_000_000
  private let maximumImages = 256
  private let maximumImageBytes = 64 * 1_024 * 1_024
  // Selection pasteboard writes are all-or-nothing and capped to bound memory use.
  private let maximumSelectionBytes = 4_194_304
  private var clipboardBuffer = [UInt8](repeating: 0, count: 1_024)
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
    let integrationPath = Bundle.main.resourceURL?.appendingPathComponent(
      "ShellIntegration", isDirectory: true).path
    core = helper.path.withCString { helperPath in
      shell.withCString { shellPath in
        let create: (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> OpaquePointer? = {
          directory, integration in
          zigonaut_core_create(helperPath, shellPath, directory,
            self.preferences.automaticShellIntegration, integration, terminalWake, self.callbackBox.toOpaque())
        }
        return integrationPath?.withCString { integration in
          if let workingDirectory {
            return workingDirectory.withCString { directory in create(directory, integration) }
          }
          return create(nil, integration)
        } ?? {
          if let workingDirectory {
            return workingDirectory.withCString { directory in create(directory, nil) }
          }
          return create(nil, nil)
        }()
      }
    }.map(TerminalCoreHandle.init)
    if core == nil {
      box.model = nil
      callbackBox.release()
    }
    applyClipboardSettings()
    applyCommandNotificationSettings()
    refresh()
  }

  func refresh() {
    guard let core else {
      return
    }
    let desiredCells = min(maximumCells, max(currentColumns * (currentRows + 1), 1))
    if cellBuffer.count < desiredCells {
      cellBuffer = [zigonaut_render_cell_v1](
        repeating: zigonaut_render_cell_v1(), count: desiredCells)
    }
    if let id = latencySignpostID {
      TerminalLatencyTrace.signposter.emitEvent("ParserCompleted", id: id)
    }
    retrieveSnapshot(core: core.pointer, retry: true)
    if let id = latencySignpostID {
      TerminalLatencyTrace.signposter.emitEvent("SnapshotCompleted", id: id)
    }
    let generation = zigonaut_core_output_generation(core.pointer)
    if generation != outputGeneration { outputGeneration = generation }
    if !exited, zigonaut_core_exited(core.pointer) { exited = true }
    retrieveTitle(core: core.pointer)
    retrieveProgress(core: core.pointer)
    var statusBytes = [UInt8](repeating: 0, count: 768)
    var statusState: UInt8 = 0
    let statusLength = zigonaut_core_program_status(core.pointer, &statusBytes,
      UInt32(statusBytes.count), &statusState)
    let status = String(decoding: statusBytes.prefix(Int(statusLength)), as: UTF8.self)
    if status != programStatus { programStatus = status }
    if statusState != programStatusState { programStatusState = statusState }
    drainNotifications(core: core.pointer)
    drainClipboard(core: core.pointer)
    scheduleCompression()
  }

  private func scheduleCompression(after delay: UInt32 = 0) {
    // Fresh snapshots supersede delayed work. Only the current request may
    // continue, and completion leaves no recurring timer or display wakeup.
    compressionRequestGeneration &+= 1
    let request = compressionRequestGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delay))) { [weak self] in
      guard let self, self.compressionRequestGeneration == request, let core = self.core else { return }
      self.writer.async { [weak self] in
        let nextDelay = zigonaut_core_compress(core.pointer)
        DispatchQueue.main.async { [weak self] in
          guard let self, self.compressionRequestGeneration == request, nextDelay != 0 else { return }
          self.scheduleCompression(after: nextDelay)
        }
      }
    }
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
    var length = 0
    var revision: UInt64 = 0
    var startColumn: UInt16 = 0
    var endColumn: UInt16 = 0
    let bytes = zigonaut_core_link_cached(core.pointer, UInt16(clamping: column),
      UInt16(clamping: row), &length, &revision, &startColumn, &endColumn)
    if revision == linkRevision { return cachedLink }
    linkRevision = revision
    cachedLink = nil
    guard let bytes, length > 0,
      let value = String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8),
      let url = URL(string: value) else { return nil }
    cachedLink = TerminalLink(url: url, row: row, startColumn: Int(startColumn), endColumn: Int(endColumn))
    return cachedLink
  }
  func linkHints() -> [TerminalHint] {
    guard let core else { return [] }
    var result = zigonaut_hint_result_v1()
    zigonaut_core_hint_snapshot(core.pointer, nil, 0, nil, 0, &result)
    guard result.status == 1, result.required_hints <= 4096, result.required_bytes <= 1_048_576 else {
      return []
    }
    var records = [zigonaut_hint_v1](repeating: zigonaut_hint_v1(), count: Int(result.required_hints))
    var bytes = [UInt8](repeating: 0, count: Int(result.required_bytes))
    zigonaut_core_hint_snapshot(core.pointer, &records, UInt32(records.count), &bytes,
      UInt32(bytes.count), &result)
    guard result.status == 0 else { return [] }
    return records.prefix(Int(result.written_hints)).compactMap { record in
      let start = Int(record.target_offset)
      let end = start + Int(record.target_length)
      guard start >= 0, end <= bytes.count,
        let url = URL(string: String(decoding: bytes[start..<end], as: UTF8.self)) else { return nil }
      var label = zigonaut_hint_label_v1()
      label.bytes = record.label
      label.length = record.label_length
      return TerminalHint(url: url, label: label, row: Int(record.row),
        startColumn: Int(record.start_column), endColumn: Int(record.end_column))
    }
  }
  func applyCommandNotificationSettings() {
    if let core {
      zigonaut_core_set_command_notifications(core.pointer, preferences.commandCompletionNotifications)
    }
  }
  func applyClipboardSettings() {
    if let core {
      zigonaut_core_set_clipboard_write(core.pointer, preferences.terminalClipboardWrites,
        UInt32(clamping: preferences.terminalClipboardMaxBytes))
    }
  }
  func applyTerminalSettings(palette: TerminalPalette, scrollback: Int, intenseTextStyle: String) {
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
    let style: UInt8 = intenseTextStyle == "bold" ? 0 : intenseTextStyle == "bright" ? 2 : 1
    _ = zigonaut_core_set_intense_text_style(core.pointer, style)
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
      if clipboardBuffer.count < required {
        clipboardBuffer = [UInt8](repeating: 0, count: required)
      }
      zigonaut_core_take_clipboard_write(core, &clipboardBuffer, UInt32(clipboardBuffer.count), &result)
      guard result.status == 0, result.written_bytes == result.required_bytes else { return }
      if result.clear != 0 {
        NSPasteboard.general.clearContents()
      } else if let value = String(bytes: clipboardBuffer.prefix(Int(result.written_bytes)), encoding: .utf8) {
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
    imagesNeedRefresh = imagesNeedRefresh || result.images_changed != 0
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
        && requiredRows <= currentRows + 1
      {
        retrieveSnapshot(core: core, retry: false)
        return
      }
    }
    guard result.status == 0 else {
      return
    }
    let count = min(Int(result.written_cells), cellBuffer.count)
    let rowCount = Int(result.written_rows)
    let rowHashes = Array(hashBuffer.prefix(rowCount))
    let emptyRow = PackedRenderRow(cells: [], text: [], background: frame.background_rgb)
    if retainedCellsByRow.count != rowCount {
      retainedCellsByRow = [PackedRenderRow](repeating: emptyRow, count: rowCount)
    }
    // The Zig collector emits complete dirty rows in row/column order. Copy
    // each row's packed records and arena once; never decode or flatten cells.
    var start = 0
    while start < count {
      let row = Int(cellBuffer[start].y)
      var end = start + 1
      while end < count && cellBuffer[end].y == cellBuffer[start].y { end += 1 }
      retainedCellsByRow[row] = PackedRenderRow(cells: cellBuffer[start..<end],
        text: textBuffer, background: frame.background_rgb)
      start = end
    }
    let images = imagesNeedRefresh ? retrieveImages(core: core) : renderSnapshot.images
    imagesNeedRefresh = false
    renderSnapshot = TerminalRenderSnapshot(
      frame: TerminalRenderFrame(
        foreground: frame.foreground_rgb,
        background: frame.background_rgb,
        cursor: frame.cursor_rgb,
        cursorX: Int(frame.cursor_x),
        cursorY: Int(frame.cursor_y),
        cursorColumns: Int(frame.cursor_columns),
        cursorStyle: frame.cursor_style,
        cursorVisible: frame.cursor_visible != 0 && frame.cursor_has_position != 0,
        mouseShape: frame.mouse_shape,
        viewportRows: Int(frame.viewport_rows),
        scrollOffset: CGFloat(frame.scroll_offset)
      ),
      cells: TerminalRenderCells(rows: retainedCellsByRow, columns: currentColumns),
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
    guard let core else { return TerminalAccessibilityLayout() }
    return TerminalAccessibilityLayout(owning: zigonaut_core_accessibility_snapshot(
      core.pointer, UInt16(clamping: currentColumns), UInt16(clamping: currentRows), 100_000))
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
  func setFocused(_ focused: Bool) {
    guard let core else { return }
    writer.async { zigonaut_core_set_focused(core.pointer, focused) }
  }
  func paste(_ value: String) { enqueue(value, paste: true) }
  func sendKey(keyCode: UInt16, modifiers: UInt16, consumedModifiers: UInt16, action: UInt8,
    unshiftedCodepoint: UInt32, utf8: [UInt8])
  {
    guard let core else { return }
    if action == 0, TerminalLatencyTrace.signposter.isEnabled {
      let id = TerminalLatencyTrace.signposter.makeSignpostID()
      latencySignpostID = id
      TerminalLatencyTrace.signposter.emitEvent("KeyReceived", id: id)
    }
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
  func takeLatencyTrace() -> OSSignpostID? {
    guard let id = latencySignpostID else { return nil }
    latencySignpostID = nil
    return id
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
  func scrollFractional(_ rows: Double) {
    guard let core, zigonaut_core_scroll_fractional(core.pointer, rows) else { return }
    refresh()
  }
  func setSearch(_ query: String) {
    guard let core else { return }
    searchRequestGeneration &+= 1
    let request = searchRequestGeneration
    let bytes = Array(query.utf8)
    writer.async { [weak self] in
      var status = zigonaut_search_status_v1()
      bytes.withUnsafeBufferPointer { buffer in
        zigonaut_core_search_set(core.pointer, buffer.baseAddress, buffer.count, &status)
      }
      DispatchQueue.main.async {
        guard self?.searchRequestGeneration == request else { return }
        self?.applySearch(status)
        self?.refresh()
        if status.scanning != 0 { self?.continueSearch(core: core, request: request) }
      }
    }
  }
  private func continueSearch(core: TerminalCoreHandle, request: UInt64) {
    writer.async { [weak self] in
      var status = zigonaut_search_status_v1()
      zigonaut_core_search_tick(core.pointer, 2_000_000, &status)
      DispatchQueue.main.async {
        guard self?.searchRequestGeneration == request else { return }
        self?.applySearch(status)
        self?.refresh()
        if status.scanning != 0 { self?.continueSearch(core: core, request: request) }
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
    searchRequestGeneration &+= 1
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
  @discardableResult
  func copy() -> Bool {
    guard let core else { return false }
    let required = zigonaut_core_copy_selection(core.pointer, nil, 0)
    guard required > 0, required <= maximumSelectionBytes else { return false }
    var bytes = [UInt8](repeating: 0, count: required)
    let count = zigonaut_core_copy_selection(core.pointer, &bytes, bytes.count)
    guard count == required, let value = String(bytes: bytes, encoding: .utf8) else { return false }
    NSPasteboard.general.clearContents()
    return NSPasteboard.general.setString(value, forType: .string)
  }
  deinit {
    guard let core else { return }
    zigonaut_core_request_stop(core.pointer)
    writer.sync {}
    zigonaut_core_destroy(core.pointer)
    callbackBox.takeRetainedValue().model = nil
  }
}

/// A presentation handle into Zig's retained preorder buffer, not a second tree.
@MainActor struct PaneNode {
  let window: WindowModel
  let id: UUID
  enum Content {
    case leaf(TerminalModel)
    case split(UUID, Axis, Double, PaneNode, PaneNode)
  }
  var content: Content? {
    let tree = window.paneTree
    // SwiftUI may evaluate an outgoing child after its node was collapsed.
    guard let index = tree.index(of: id) else { return nil }
    let node = tree.node(at: index)
    guard node.split else { return window.terminalModels[id].map(Content.leaf) }
    let second = index + 1 + Int(tree.node(at: index + 1).subtree_size)
    return .split(id, node.vertical ? .vertical : .horizontal, Double(node.ratio) / 65535,
      PaneNode(window: window, id: tree.id(at: index + 1)), PaneNode(window: window, id: tree.id(at: second)))
  }
}

@MainActor final class WindowModel: ObservableObject {
  let paneTree: SharedPaneTree
  private(set) var terminalModels: [UUID: TerminalModel]
  private(set) var panes: [TerminalModel]
  @Published private var layoutRevision: UInt64 = 0
  @Published var draggingPane: UUID?
  var focusedPane: UUID? {
    get { paneTree.focused }
    set {
      guard let newValue, paneTree.focus(newValue) else { return }
      focusChanged()
    }
  }
  var zoomedPane: UUID? { paneTree.zoomed }
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
  private var exitObservations: [UUID: AnyCancellable] = [:]
  private var paneFrames: [UUID: CGRect] = [:]
  let preferences: Preferences
  var stateChanged: (() -> Void)?
  var paneExited: ((UUID) -> Void)?
  init(preferences: Preferences) {
    self.preferences = preferences
    let pane = TerminalModel(shell: preferences.validShell, preferences: preferences)
    paneTree = SharedPaneTree(saved: .leaf(SavedPane(id: pane.id, directory: nil)))!
    terminalModels = [pane.id: pane]
    panes = [pane]
    title = pane.title
    synchronizeTitleOwner()
    synchronizeOutputOwners()
  }
  init(saved: SavedTab, preferences: Preferences) {
    self.preferences = preferences
    paneTree = SharedPaneTree(saved: saved.root)!
    var terminals: [UUID: TerminalModel] = [:]
    func restore(_ node: SavedPaneNode) {
      switch node {
      case .leaf(let pane):
        terminals[pane.id] = TerminalModel(id: pane.id, shell: preferences.validShell,
          workingDirectory: pane.directory, preferences: preferences)
      case .split(_, _, _, let first, let second):
        restore(first)
        restore(second)
      }
    }
    restore(saved.root)
    terminalModels = terminals
    panes = paneTree.leafIDs.compactMap { terminals[$0] }
    paneTree.focus(saved.focusedPane)
    title = panes.first?.title ?? "Terminal"
    synchronizeTitleOwner()
    synchronizeOutputOwners()
  }
  var saved: SavedTab {
    SavedTab(root: paneTree.saved { terminalModels[$0]?.restorationDirectory() },
      focusedPane: focusedPane ?? paneTree.leafIDs[0])
  }
  var focused: TerminalModel? { focusedPane.flatMap { terminalModels[$0] } }
  var visibleRoot: PaneNode { PaneNode(window: self, id: zoomedPane ?? paneTree.id(at: 0)) }
  var foregroundJobCount: Int { panes.filter(\.hasForegroundJob).count }
  private func focusChanged() {
    layoutRevision &+= 1
    synchronizeTitleOwner()
    synchronizeFindOwner()
    stateChanged?()
  }
  private func topologyChanged() {
    panes = paneTree.leafIDs.compactMap { terminalModels[$0] }
    synchronizeOutputOwners()
    focusChanged()
  }
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
    exitObservations = exitObservations.filter { active.contains($0.key) }
    for pane in panes where outputObservations[pane.id] == nil {
      outputObservations[pane.id] = pane.$outputGeneration.dropFirst().sink { [weak self] _ in
        self?.outputGeneration &+= 1
      }
      exitObservations[pane.id] = pane.$exited.filter { $0 }.sink { [weak self] _ in
        self?.paneExited?(pane.id)
      }
    }
  }
  func split(_ axis: Axis) {
    guard let focus = focusedPane, panes.count < 64 else { return }
    let pane = TerminalModel(shell: preferences.validShell, preferences: preferences)
    guard paneTree.split(target: focus, pane: pane.id, vertical: axis == .vertical) else { return }
    terminalModels[pane.id] = pane
    topologyChanged()
  }
  func movePane(_ source: UUID, onto target: UUID, edge: PaneDropEdge) -> Bool {
    guard paneTree.move(source, onto: target, edge: edge) else { return false }
    topologyChanged()
    return true
  }
  func setRatio(_ id: UUID, _ ratio: Double) {
    guard paneTree.setRatio(id, ratio) else { return }
    layoutRevision &+= 1
    stateChanged?()
  }
  /// Returns false when the native window tab itself should be closed.
  func closeFocused() -> Bool {
    guard let focus = focusedPane else { return false }
    return closePane(focus)
  }
  /// Returns false when removing this pane means closing the native tab.
  func closePane(_ pane: UUID) -> Bool {
    guard paneTree.close(pane) else { return false }
    terminalModels.removeValue(forKey: pane)
    topologyChanged()
    return true
  }
  func updatePaneFrames(_ frames: [UUID: CGRect]) {
    let zoomed = zoomedPane
    paneFrames = frames.filter { terminalModels[$0.key] != nil && (zoomed == nil || zoomed == $0.key) }
  }
  func focus(_ direction: PaneFocusDirection) {
    guard let focusedPane,
      let destination = DirectionalPaneFocus.destination(from: focusedPane, direction: direction,
        frames: paneFrames, stableOrder: paneTree.leafIDs) else { return }
    self.focusedPane = destination
  }
  func focusCycle(forward: Bool) {
    if paneTree.cycle(forward: forward) { focusChanged() }
  }
  func canResize(_ direction: PaneFocusDirection) -> Bool {
    paneTree.canResize(direction)
  }
  func resize(_ direction: PaneFocusDirection) {
    guard paneTree.resize(direction) else { return }
    layoutRevision &+= 1
    stateChanged?()
  }
  func equalizePanes() {
    guard paneTree.equalize() else { return }
    layoutRevision &+= 1
    stateChanged?()
  }
  func togglePaneZoom() {
    guard paneTree.toggleZoom() else { return }
    layoutRevision &+= 1
    stateChanged?()
  }
  func canFocus(_ direction: PaneFocusDirection) -> Bool {
    guard let focusedPane else { return false }
    return DirectionalPaneFocus.destination(from: focusedPane, direction: direction,
      frames: paneFrames, stableOrder: paneTree.leafIDs) != nil
  }
}
