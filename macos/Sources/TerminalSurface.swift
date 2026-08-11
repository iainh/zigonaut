import AppKit
import Carbon.HIToolbox
import CoreText
import Metal
import QuartzCore
import SwiftUI
import ZigonautAccessibility
import ZigonautCore

final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
  private struct TextStyle: Equatable {
    let rgb: UInt32
    let bold: Bool
    let italic: Bool
    let faint: Bool
  }

  private struct TextRun {
    let x: Int
    let y: Int
    var nextX: Int
    let style: TextStyle
    var bytes: [UInt8]
  }

  private struct ColorKey: Hashable {
    let rgb: UInt32
    let alpha: UInt64
  }

  private struct PseudographicsKey: Hashable {
    let codepoint: UInt32
    let width: Int
    let height: Int
    let thickness: Int
  }

  let model: TerminalModel
  var preferences: Preferences
  var focused = false
  var wantsKeyboardFocus = false
  var onFocus: () -> Void
  private var scrollRemainder: CGFloat = 0
  private var markedText = NSMutableAttributedString()
  private var markedSelection = NSRange(location: NSNotFound, length: 0)
  private var reportingButton: UInt8 = 0
  private var selecting = false
  private var selectionShouldCopy = false
  private var trackingArea: NSTrackingArea?
  private var lastMousePoint: NSPoint?
  private var cachedFontFamily = ""
  private var cachedFontSize = 0.0
  private var cachedFontWeight = ""
  private var cachedIntenseFontWeight = ""
  private var cachedFonts: [UInt: NSFont] = [:]
  private var cachedCellWidth: CGFloat = 1
  private var cachedLineHeight: CGFloat = 1
  private var cachedFontAdvances: [UInt: CGFloat] = [:]
  private var clipboardEnabled: Bool?
  private var clipboardMaximumBytes = 0
  private var accessibilityLayout = TerminalAccessibilityLayout(
    columns: 0, rows: 0, cells: [], cursorColumn: 0, cursorRow: 0)
  private var voiceOverObservation: NSKeyValueObservation?
  private var colorCache: [ColorKey: NSColor] = [:]
  private var pseudographicsCache: [PseudographicsKey: CGImage] = [:]
  private var pseudographicsMetrics: (cellWidth: Int, height: Int, thickness: Int)?
  private var appliedPalette: TerminalPalette?
  private var appliedScrollback = -1
  private var metalLayer: CAMetalLayer?
  private var metalQueue: MTLCommandQueue?
  private var metalPipeline: MTLRenderPipelineState?
  private var retainedTexture: MTLTexture?
  private var retainedBitmap: CGContext?
  private var retainedRowHashes: [UInt64] = []
  private var retainedAppearance = ""
  private var retainedPixelSize = CGSize.zero
  private var encodedKeys = Set<UInt16>()
  private var pressedModifiers = Set<UInt16>()
  private var pendingKeyEvent: NSEvent?
  private var pendingKeyUsedMarkedText = false

  private var font: NSFont {
    styledFont(traits: [])
  }

  func updateFont() {
    guard cachedFontFamily != preferences.fontFamily || cachedFontSize != preferences.fontSize
      || cachedFontWeight != preferences.fontWeight
      || cachedIntenseFontWeight != preferences.intenseFontWeight else {
      return
    }
    cachedFontFamily = preferences.fontFamily
    cachedFontSize = preferences.fontSize
    cachedFontWeight = preferences.fontWeight
    cachedIntenseFontWeight = preferences.intenseFontWeight
    cachedFonts.removeAll(keepingCapacity: true)
    cachedFontAdvances.removeAll(keepingCapacity: true)
    pseudographicsCache.removeAll(keepingCapacity: true)
    pseudographicsMetrics = nil
    let base = preferences.terminalFont(size: preferences.fontSize)
    cachedFonts[0] = base
    cachedCellWidth = ceil(("M" as NSString).size(withAttributes: [.font: base]).width)
    cachedLineHeight = ceil(base.ascender - base.descender + base.leading)
  }

  private func styledFont(traits: NSFontTraitMask) -> NSFont {
    let traitKey = traits.rawValue
    if let cached = cachedFonts[traitKey] { return cached }
    var remainingTraits = traits
    let weight = traits.contains(.boldFontMask) ? preferences.intenseFontWeight : preferences.fontWeight
    remainingTraits.remove(.boldFontMask)
    let base = preferences.terminalFont(size: preferences.fontSize, weightName: weight)
    if traits.isEmpty { cachedFonts[0] = base }
    let result = remainingTraits.isEmpty ? base : NSFontManager.shared.convert(base, toHaveTrait: remainingTraits)
    cachedFonts[traitKey] = result
    return result
  }

  private func styledAdvance(traits: NSFontTraitMask, font: NSFont) -> CGFloat {
    let traitKey = traits.rawValue
    if let cached = cachedFontAdvances[traitKey] { return cached }
    let advance = ("M" as NSString).size(withAttributes: [.font: font, .ligature: 0]).width
    cachedFontAdvances[traitKey] = advance
    return advance
  }

  func updateClipboardSettings() {
    let enabled = preferences.terminalClipboardWrites
    let maximumBytes = preferences.terminalClipboardMaxBytes
    guard clipboardEnabled != enabled || clipboardMaximumBytes != maximumBytes else { return }
    clipboardEnabled = enabled
    clipboardMaximumBytes = maximumBytes
    model.applyClipboardSettings()
  }

  func updateAccessibilityValue() {
    guard NSWorkspace.shared.isVoiceOverEnabled else { return }
    let previous = accessibilityLayout
    let next = model.accessibilityLayout()
    accessibilityLayout = next
    if next.string != previous.string {
      NSAccessibility.post(element: self, notification: .valueChanged)
    }
    if next.selectedRanges != previous.selectedRanges {
      NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }
  }

  override func accessibilityValue() -> Any? {
    accessibilityLayout.string
  }

  override func accessibilityVisibleCharacterRange() -> NSRange { accessibilityLayout.fullRange }
  override func accessibilityNumberOfCharacters() -> Int { accessibilityLayout.fullRange.length }
  override func accessibilitySelectedText() -> String? {
    accessibilityLayout.selectedRanges.isEmpty ? nil : accessibilityLayout.string(for: accessibilityLayout.selectedRange)
  }
  override func accessibilitySelectedTextRange() -> NSRange { accessibilityLayout.selectedRange }
  override func accessibilitySelectedTextRanges() -> [NSValue]? {
    accessibilityLayout.selectedRanges.map(NSValue.init(range:))
  }
  override func accessibilityInsertionPointLineNumber() -> Int {
    accessibilityLayout.line(for: accessibilityLayout.cursorRange.location)
  }
  override func accessibilityString(for range: NSRange) -> String? { accessibilityLayout.string(for: range) }
  override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
    accessibilityLayout.string(for: range).map(NSAttributedString.init(string:))
  }
  override func accessibilityRange(forLine line: Int) -> NSRange { accessibilityLayout.range(forLine: line) }
  override func accessibilityLine(for index: Int) -> Int { accessibilityLayout.line(for: index) }
  override func accessibilityFrame(for range: NSRange) -> NSRect {
    let grid = accessibilityLayout.gridRect(for: range)
    guard !grid.isEmpty else { return .zero }
    let local = NSRect(x: originX + grid.minX * cellWidth, y: originY + grid.minY * lineHeight,
      width: grid.width * cellWidth, height: grid.height * lineHeight)
    return window?.convertToScreen(convert(local, to: nil)) ?? convert(local, to: nil)
  }

  private var cellWidth: CGFloat {
    cachedCellWidth
  }

  private var lineHeight: CGFloat {
    cachedLineHeight
  }

  private var gridColumns: Int {
    max(2, Int((bounds.width - 2 * preferences.paddingHorizontal) / cellWidth))
  }

  private var gridRows: Int {
    max(2, Int((bounds.height - 2 * preferences.paddingVertical) / lineHeight))
  }

  private var originX: CGFloat {
    preferences.paddingBalance == "Centered"
      ? max(0, (bounds.width - CGFloat(gridColumns) * cellWidth) / 2)
      : preferences.paddingHorizontal
  }

  private var originY: CGFloat {
    preferences.paddingBalance == "Centered"
      ? max(0, (bounds.height - CGFloat(gridRows) * lineHeight) / 2)
      : preferences.paddingVertical
  }

  private var isDarkAppearance: Bool {
    effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  func updateTerminalSettings() {
    let palette = preferences.terminalPalette(dark: isDarkAppearance, seed: model.themeSeed)
    guard palette != appliedPalette || preferences.scrollbackSize != appliedScrollback else { return }
    appliedPalette = palette
    appliedScrollback = preferences.scrollbackSize
    colorCache.removeAll(keepingCapacity: true)
    model.applyTerminalSettings(palette: palette, scrollback: preferences.scrollbackSize)
  }

  init(model: TerminalModel, preferences: Preferences, onFocus: @escaping () -> Void) {
    self.model = model
    self.preferences = preferences
    self.onFocus = onFocus
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .duringViewResize
    configureMetal()
    registerForDraggedTypes([.fileURL])
    setAccessibilityElement(true)
    setAccessibilityRole(.textArea)
    setAccessibilityLabel("Terminal")
    updateFont()
    voiceOverObservation = NSWorkspace.shared.observe(
      \.isVoiceOverEnabled, options: [.initial, .new]
    ) { [weak self] _, change in
      guard change.newValue == true else { return }
      DispatchQueue.main.async { [weak self] in
        self?.updateAccessibilityValue()
      }
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  private func configureMetal() {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let source = """
      #include <metal_stdlib>
      using namespace metal;
      struct VertexOut { float4 position [[position]]; float2 uv; };
      vertex VertexOut terminal_vertex(uint id [[vertex_id]]) {
        const float2 positions[] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
        const float2 coordinates[] = { {0,1}, {1,1}, {0,0}, {1,0} };
        return { float4(positions[id], 0, 1), coordinates[id] };
      }
      fragment float4 terminal_fragment(VertexOut in [[stage_in]],
          texture2d<float> image [[texture(0)]]) {
        constexpr sampler nearest(coord::normalized, address::clamp_to_edge, filter::nearest);
        return image.sample(nearest, in.uv);
      }
      """
    guard let library = try? device.makeLibrary(source: source, options: nil),
      let vertex = library.makeFunction(name: "terminal_vertex"),
      let fragment = library.makeFunction(name: "terminal_fragment") else { return }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertex
    descriptor.fragmentFunction = fragment
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return }
    let presentation = CAMetalLayer()
    presentation.device = device
    presentation.pixelFormat = .bgra8Unorm
    presentation.framebufferOnly = true
    presentation.contentsGravity = .topLeft
    presentation.anchorPoint = .zero
    layer?.addSublayer(presentation)
    metalLayer = presentation
    metalQueue = queue
    metalPipeline = pipeline
  }

  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateTerminalSettings()
    retainedAppearance = ""
    needsDisplay = true
  }

  override func becomeFirstResponder() -> Bool {
    needsDisplay = true
    return true
  }

  override func resignFirstResponder() -> Bool {
    clearEncodedKeys()
    needsDisplay = true
    return true
  }

  @discardableResult
  func resizeTerminal() -> Bool {
    let columns = gridColumns
    let rows = gridRows
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    return model.resize(columns: columns, rows: rows,
      pixelWidth: Int(bounds.width * scale), pixelHeight: Int(bounds.height * scale),
      cellWidth: Int(cellWidth * scale), cellHeight: Int(lineHeight * scale), scale: scale)
  }

  private func updateMetalGeometry() -> (scale: CGFloat, width: Int, height: Int)? {
    guard let presentation = metalLayer else { return nil }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    let width = max(1, Int((bounds.width * scale).rounded(.up)))
    let height = max(1, Int((bounds.height * scale).rounded(.up)))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    presentation.frame = bounds
    presentation.contentsScale = scale
    presentation.drawableSize = CGSize(width: width, height: height)
    CATransaction.commit()
    return (scale, width, height)
  }

  override func setFrameSize(_ size: NSSize) {
    super.setFrameSize(size)
    _ = updateMetalGeometry()
    if resizeTerminal() { model.refresh() }
    needsDisplay = true
  }

  override func updateTrackingAreas() {
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
    super.updateTrackingAreas()
  }

  override func mouseMoved(with event: NSEvent) {
    lastMousePoint = convert(event.locationInWindow, from: nil)
    updateLinkCursor(event.modifierFlags)
  }

  override func flagsChanged(with event: NSEvent) {
    updateLinkCursor(event.modifierFlags)
    let code = event.keyCode
    guard Self.modifierKeyCodes.contains(code) else { return }
    let releasing = pressedModifiers.contains(code)
    if releasing { pressedModifiers.remove(code) } else { pressedModifiers.insert(code) }
    sendKey(event, action: releasing ? 2 : 0, text: "")
  }

  private func updateLinkCursor(_ flags: NSEvent.ModifierFlags) {
    guard flags.contains(.command), let point = lastMousePoint else {
      NSCursor.arrow.set()
      return
    }
    let column = max(0, Int((point.x - originX) / cellWidth))
    let row = max(0, Int((point.y - originY) / lineHeight))
    (model.link(column: column, row: row) == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    clearEncodedKeys()
    resizeTerminal()
    model.refresh()
    needsDisplay = true
    if wantsKeyboardFocus {
      window?.makeFirstResponder(self)
    }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    resizeTerminal()
    model.refresh()
    retainedPixelSize = .zero
    needsDisplay = true
  }

  override func keyDown(with event: NSEvent) {
    // Command equivalents belong to menus and the responder chain. Text input
    // stays with NSTextInputClient unless it is a physical key we can describe
    // without pre-empting IME/dead-key composition.
    if event.modifierFlags.contains(.command) {
      super.keyDown(with: event)
      return
    }
    guard Self.supportedKeyCodes.contains(event.keyCode) else {
      interpretKeyEvents([event])
      return
    }
    if Self.nonTextKeyCodes.contains(event.keyCode) {
      sendKey(event, action: event.isARepeat ? 1 : 0, text: event.characters ?? "")
      encodedKeys.insert(event.keyCode)
      return
    }
    // AppKit calls insertText synchronously for simple committed text. Keeping
    // this pending only across interpretation lets IME own composition while
    // still associating ordinary printable commits with their physical key.
    pendingKeyEvent = event
    pendingKeyUsedMarkedText = hasMarkedText()
    interpretKeyEvents([event])
    pendingKeyEvent = nil
    pendingKeyUsedMarkedText = false
  }

  override func keyUp(with event: NSEvent) {
    guard encodedKeys.remove(event.keyCode) != nil else { return }
    sendKey(event, action: 2, text: "")
  }

  private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62]
  private static let nonTextKeyCodes: Set<UInt16> = Set(
    [36, 48, 51, 53, 71, 76, 114, 115, 116, 117, 119, 121, 123, 124, 125, 126]
      + Array(96...113) + Array(118...122) + Array(131...134))
  private static let supportedKeyCodes: Set<UInt16> = Set(0...62).subtracting([52])
    .union([65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92,
      93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 109, 111, 113,
      114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 131, 132, 133, 134])

  private func sendKey(_ event: NSEvent, action: UInt8, text: String) {
    var modifiers: UInt16 = 0
    if event.modifierFlags.contains(.shift) { modifiers |= 1 }
    if event.modifierFlags.contains(.control) { modifiers |= 2 }
    if event.modifierFlags.contains(.option) { modifiers |= 4 }
    if event.modifierFlags.contains(.command) { modifiers |= 8 }
    let unshifted = Self.unshiftedCodepoint(event.keyCode)
    let bytes = Array(text.utf8.prefix(64))
    var consumed: UInt16 = 0
    if let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1, unshifted != 0,
      scalar.value != unshifted
    {
      if event.modifierFlags.contains(.shift) { consumed |= 1 }
      if event.modifierFlags.contains(.option) { consumed |= 4 }
    }
    model.sendKey(keyCode: event.keyCode, modifiers: modifiers, consumedModifiers: consumed,
      action: action, unshiftedCodepoint: unshifted, utf8: bytes)
  }

  private static func unshiftedCodepoint(_ keyCode: UInt16) -> UInt32 {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return 0 }
    let data = unsafeBitCast(raw, to: CFData.self)
    guard let bytes = CFDataGetBytePtr(data) else { return 0 }
    let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
    var deadKey: UInt32 = 0
    var length = 0
    var characters = [UniChar](repeating: 0, count: 4)
    let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0,
      UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKey,
      characters.count, &length, &characters)
    guard status == noErr, length == 1 else { return 0 }
    let scalar = UnicodeScalar(characters[0])
    return scalar.map(\.value) ?? 0
  }

  func insertText(_ value: Any, replacementRange: NSRange) {
    let string = (value as? NSAttributedString)?.string ?? (value as? String) ?? ""
    let wasMarked = hasMarkedText() || pendingKeyUsedMarkedText
    markedText = NSMutableAttributedString()
    markedSelection = NSRange(location: NSNotFound, length: 0)
    if !string.isEmpty, let event = pendingKeyEvent, !wasMarked {
      let text = event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.option)
        ? (event.charactersIgnoringModifiers ?? string) : string
      sendKey(event, action: event.isARepeat ? 1 : 0, text: text)
      encodedKeys.insert(event.keyCode)
    } else if !string.isEmpty {
      model.write(string)
    }
    needsDisplay = true
  }

  func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
    if pendingKeyEvent != nil { pendingKeyUsedMarkedText = true }
    if let attributed = value as? NSAttributedString {
      markedText = NSMutableAttributedString(attributedString: attributed)
    } else {
      markedText = NSMutableAttributedString(string: value as? String ?? "")
    }
    markedSelection = selectedRange
    needsDisplay = true
  }

  func unmarkText() {
    markedText = NSMutableAttributedString()
    markedSelection = NSRange(location: NSNotFound, length: 0)
    needsDisplay = true
  }

  private func clearEncodedKeys() {
    encodedKeys.removeAll()
    pressedModifiers.removeAll()
    pendingKeyEvent = nil
    pendingKeyUsedMarkedText = false
  }

  func hasMarkedText() -> Bool { markedText.length > 0 }
  func markedRange() -> NSRange {
    hasMarkedText()
      ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
  }
  func selectedRange() -> NSRange { markedSelection }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    [.underlineStyle, .foregroundColor, .backgroundColor]
  }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    let intersection = NSIntersectionRange(range, NSRange(location: 0, length: markedText.length))
    guard intersection.length > 0 else { return nil }
    actualRange?.pointee = intersection
    return markedText.attributedSubstring(from: intersection)
  }
  func characterIndex(for point: NSPoint) -> Int { 0 }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    actualRange?.pointee = markedRange()
    let cursor = model.renderSnapshot.frame
    let local = NSRect(
      x: originX + CGFloat(cursor.cursorX) * cellWidth,
      y: originY + CGFloat(cursor.cursorY) * lineHeight,
      width: max(cellWidth, CGFloat(markedText.length) * cellWidth), height: lineHeight)
    return window?.convertToScreen(convert(local, to: nil)) ?? local
  }

  @objc func paste(_ sender: Any?) {
    if let string = NSPasteboard.general.string(forType: .string) {
      model.paste(string)
    }
  }

  @objc func copy(_ sender: Any?) {
    model.copy()
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(copy(_:)):
      return model.hasSelection
    case #selector(paste(_:)):
      return model.acceptsPaste && !(NSPasteboard.general.string(forType: .string)?.isEmpty ?? true)
    default:
      return true
    }
  }

  private func cell(_ event: NSEvent) -> (Int, Int) {
    let point = convert(event.locationInWindow, from: nil)
    let column = min(gridColumns - 1, max(0, Int((point.x - originX) / cellWidth)))
    let row = min(gridRows - 1, max(0, Int((point.y - originY) / lineHeight)))
    return (column, row)
  }

  override func mouseDown(with event: NSEvent) {
    handleMouseDown(event)
  }
  override func rightMouseDown(with event: NSEvent) {
    if shouldReport(event) {
      handleMouseDown(event)
    } else {
      onFocus()
      window?.makeFirstResponder(self)
      NSMenu.popUpContextMenu(terminalMenu(), with: event, for: self)
    }
  }
  override func otherMouseDown(with event: NSEvent) { handleMouseDown(event) }

  private func handleMouseDown(_ event: NSEvent) {
    onFocus()
    window?.makeFirstResponder(self)
    let point = cell(event)
    if event.modifierFlags.contains(.command), let url = model.link(column: point.0, row: point.1) {
      NSWorkspace.shared.open(url)
      return
    }
    if shouldReport(event) {
      reportingButton = mouseButton(event)
      sendMouse(event, action: 0, button: reportingButton, pressed: true)
      return
    }
    selecting = true
    selectionShouldCopy = event.clickCount >= 2
    let unit: UInt8 = event.clickCount >= 3 ? 2 : event.clickCount == 2 ? 1 : 0
    model.selectionBegin(point.0, point.1, unit: unit,
      rectangle: unit == 0 && event.modifierFlags.contains(.option))
    model.refresh()
  }

  override func mouseDragged(with event: NSEvent) {
    handleMouseDragged(event)
  }
  override func rightMouseDragged(with event: NSEvent) { handleMouseDragged(event) }
  override func otherMouseDragged(with event: NSEvent) { handleMouseDragged(event) }

  private func handleMouseDragged(_ event: NSEvent) {
    if reportingButton != 0 {
      sendMouse(event, action: 2, button: reportingButton, pressed: true)
      return
    }
    guard selecting else { return }
    selectionShouldCopy = true
    let location = convert(event.locationInWindow, from: nil)
    if location.y < originY {
      model.scroll(1)
    } else if location.y > originY + CGFloat(gridRows) * lineHeight {
      model.scroll(-1)
    }
    _ = autoscroll(with: event)
    let point = cell(event)
    model.selectionUpdate(point.0, point.1)
  }

  override func mouseUp(with event: NSEvent) {
    handleMouseUp(event)
  }
  override func rightMouseUp(with event: NSEvent) { handleMouseUp(event) }
  override func otherMouseUp(with event: NSEvent) { handleMouseUp(event) }

  private func handleMouseUp(_ event: NSEvent) {
    if reportingButton != 0 {
      sendMouse(event, action: 1, button: reportingButton, pressed: false)
      reportingButton = 0
      return
    }
    guard selecting else { return }
    selecting = false
    model.selectionEnd()
    if selectionShouldCopy {
      model.copy()
    } else {
      model.clearSelection()
    }
    model.refresh()
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    droppedFileURLs(sender).isEmpty ? [] : .copy
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let urls = droppedFileURLs(sender)
    guard !urls.isEmpty else { return false }
    let command = urls.map { shellQuote($0.path) }.joined(separator: " ")
    model.paste(command)
    return true
  }

  private func droppedFileURLs(_ sender: any NSDraggingInfo) -> [URL] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
  }

  private func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func terminalMenu() -> NSMenu {
    let menu = NSMenu(title: "Terminal")
    let copyItem = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
    copyItem.target = self
    let pasteItem = menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
    pasteItem.target = self
    menu.addItem(.separator())
    let findItem = menu.addItem(withTitle: "Find…", action: #selector(Delegate.find(_:)), keyEquivalent: "")
    findItem.target = NSApp.delegate
    menu.addItem(.separator())
    let splitRight = menu.addItem(withTitle: "Split Right", action: #selector(Delegate.splitRight(_:)), keyEquivalent: "")
    splitRight.target = NSApp.delegate
    let splitDown = menu.addItem(withTitle: "Split Down", action: #selector(Delegate.splitDown(_:)), keyEquivalent: "")
    splitDown.target = NSApp.delegate
    let close = menu.addItem(withTitle: "Close", action: #selector(Delegate.closePane(_:)), keyEquivalent: "")
    close.target = NSApp.delegate
    return menu
  }

  override func scrollWheel(with event: NSEvent) {
    if shouldReport(event) {
      let count = max(1, Int(abs(event.scrollingDeltaY) / max(1, lineHeight)))
      let button: UInt8 = event.scrollingDeltaY > 0 ? 4 : 5
      for _ in 0..<count { sendMouse(event, action: 0, button: button, pressed: false) }
      return
    }
    scrollRemainder += event.scrollingDeltaY / max(1, lineHeight)
    let rows = Int(scrollRemainder)
    if rows != 0 {
      scrollRemainder -= CGFloat(rows)
      model.scroll(-rows)
    }
  }

  private func shouldReport(_ event: NSEvent) -> Bool {
    model.mouseTracking && !event.modifierFlags.contains(.shift)
  }

  private func mouseButton(_ event: NSEvent) -> UInt8 {
    switch event.buttonNumber {
    case 1: return 2
    case 2: return 3
    default: return 1
    }
  }

  private func sendMouse(_ event: NSEvent, action: UInt8, button: UInt8, pressed: Bool) {
    let point = convert(event.locationInWindow, from: nil)
    var modifiers: UInt16 = 0
    if event.modifierFlags.contains(.shift) { modifiers |= 1 }
    if event.modifierFlags.contains(.control) { modifiers |= 2 }
    if event.modifierFlags.contains(.option) { modifiers |= 4 }
    model.sendMouse(
      action: action, button: button, x: Int(point.x), y: Int(point.y), width: Int(bounds.width),
      height: Int(bounds.height), cellWidth: Int(cellWidth), cellHeight: Int(lineHeight),
      paddingTop: Int(originY),
      paddingBottom: Int(max(0, bounds.height - originY - CGFloat(gridRows) * lineHeight)),
      paddingLeft: Int(originX),
      paddingRight: Int(max(0, bounds.width - originX - CGFloat(gridColumns) * cellWidth)),
      modifiers: modifiers, pressed: pressed)
  }

  private func color(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
    let key = ColorKey(rgb: rgb, alpha: Double(alpha).bitPattern)
    if let cached = colorCache[key] { return cached }
    let result = NSColor(
      calibratedRed: CGFloat((rgb >> 16) & 0xff) / 255,
      green: CGFloat((rgb >> 8) & 0xff) / 255,
      blue: CGFloat(rgb & 0xff) / 255,
      alpha: alpha
    )
    colorCache[key] = result
    return result
  }

  override func draw(_ dirtyRect: NSRect) {
    if renderMetal() { return }
    let snapshot = model.renderSnapshot
    color(snapshot.frame.background, alpha: preferences.opacity).setFill()
    bounds.fill()
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(rect: bounds).addClip()
    drawEdgeColors(snapshot.cells)
    for cell in snapshot.cells {
      drawBackground(cell)
    }
    drawText(snapshot.cells)
    for cell in snapshot.cells where !cell.text.isEmpty && cell.occupancy != 2 {
      drawDecorations(cell, rect: cellRect(cell))
    }
    drawImages(snapshot.images)
    drawCursor(snapshot.frame)
    drawMarkedText(snapshot.frame)
    NSGraphicsContext.current?.restoreGraphicsState()
  }

  private func renderMetal() -> Bool {
    guard let presentation = metalLayer, let queue = metalQueue, let pipeline = metalPipeline,
      let device = presentation.device, let geometry = updateMetalGeometry() else { return false }
    let scale = geometry.scale
    let pixelWidth = geometry.width
    let pixelHeight = geometry.height
    let pixelSize = CGSize(width: pixelWidth, height: pixelHeight)
    if retainedBitmap == nil || retainedPixelSize != pixelSize {
      let colorSpace = CGColorSpaceCreateDeviceRGB()
      retainedBitmap = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
        bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
      retainedBitmap?.translateBy(x: 0, y: CGFloat(pixelHeight))
      retainedBitmap?.scaleBy(x: scale, y: -scale)
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
        width: pixelWidth, height: pixelHeight, mipmapped: false)
      descriptor.usage = [.shaderRead]
      descriptor.storageMode = .shared
      retainedTexture = device.makeTexture(descriptor: descriptor)
      retainedPixelSize = pixelSize
      retainedRowHashes = []
    }
    guard let bitmap = retainedBitmap, let texture = retainedTexture,
      let data = bitmap.data else { return disableMetal() }
    let snapshot = model.renderSnapshot
    let appearance = [
      preferences.fontFamily, String(preferences.fontSize), preferences.fontWeight,
      preferences.intenseFontWeight, String(preferences.paddingHorizontal),
      String(preferences.paddingVertical), preferences.paddingBalance, preferences.paddingColor,
      String(preferences.opacity), markedText.string,
      snapshot.images.map(\.signature).joined(separator: ","),
    ].joined(separator: "|")
    let forceAll = retainedAppearance != appearance
      || retainedRowHashes.count != snapshot.rowHashes.count || snapshot.rowHashes.isEmpty
    let rowCount = snapshot.rowHashes.isEmpty ? gridRows : snapshot.rowHashes.count
    let dirtyRows = forceAll ? [] : snapshot.rowHashes.indices.filter {
      retainedRowHashes[$0] != snapshot.rowHashes[$0]
    }
    if forceAll || !dirtyRows.isEmpty {
      rasterize(snapshot: snapshot, rowCount: rowCount, rows: forceAll ? nil : dirtyRows, in: bitmap)
      if forceAll {
        texture.replace(region: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight), mipmapLevel: 0,
          withBytes: data, bytesPerRow: bitmap.bytesPerRow)
      } else {
        for row in dirtyRows {
          let visualMin = row == 0 ? 0
            : max(0, Int(floor((originY + CGFloat(row) * lineHeight) * scale)))
          let visualMax = row == rowCount - 1 ? pixelHeight
            : min(pixelHeight, Int(ceil((originY + CGFloat(row + 1) * lineHeight) * scale)))
          let physicalY = visualMin
          let height = max(0, visualMax - visualMin)
          guard height > 0 else { continue }
          texture.replace(region: MTLRegionMake2D(0, physicalY, pixelWidth, height), mipmapLevel: 0,
            withBytes: data.advanced(by: physicalY * bitmap.bytesPerRow),
            bytesPerRow: bitmap.bytesPerRow)
        }
      }
      retainedRowHashes = snapshot.rowHashes
      retainedAppearance = appearance
    }
    guard let drawable = presentation.nextDrawable() else { return disableMetal() }
    guard let command = queue.makeCommandBuffer() else { return disableMetal() }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return disableMetal() }
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentTexture(texture, index: 0)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()
    command.present(drawable)
    command.commit()
    presentation.isHidden = false
    return true
  }

  private func disableMetal() -> Bool {
    metalLayer?.isHidden = true
    return false
  }

  private func rasterize(snapshot: TerminalRenderSnapshot, rowCount: Int, rows: [Int]?,
    in bitmap: CGContext)
  {
    let context = NSGraphicsContext(cgContext: bitmap, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    func drawRow(_ row: Int) {
      bitmap.saveGState()
      var rowRect = NSRect(x: 0, y: originY + CGFloat(row) * lineHeight,
        width: bounds.width, height: lineHeight)
      if row == 0 { rowRect.origin.y = 0; rowRect.size.height += originY }
      if row == rowCount - 1 { rowRect.size.height = bounds.maxY - rowRect.minY }
      NSBezierPath(rect: rowRect).addClip()
      color(snapshot.frame.background, alpha: preferences.opacity).setFill()
      rowRect.fill()
      let cells = snapshot.cellsByRow.indices.contains(row) ? snapshot.cellsByRow[row] : []
      drawEdgeColors(cells)
      for cell in cells { drawBackground(cell) }
      drawText(cells)
      for cell in cells where !cell.text.isEmpty && cell.occupancy != 2 {
        drawDecorations(cell, rect: cellRect(cell))
      }
      let images = snapshot.imagesByRow.indices.contains(row) ? snapshot.imagesByRow[row] : []
      drawImages(images)
      drawCursor(snapshot.frame)
      drawMarkedText(snapshot.frame)
      bitmap.restoreGState()
    }
    if let rows {
      for row in rows { drawRow(row) }
    } else {
      for row in 0..<rowCount { drawRow(row) }
    }
    NSGraphicsContext.restoreGraphicsState()
  }

  private func drawEdgeColors(_ cells: [TerminalRenderCell]) {
    guard preferences.paddingColor != "Background" else { return }
    let always = preferences.paddingColor == "Always Extend"
    let gridRight = originX + CGFloat(gridColumns) * cellWidth
    let gridBottom = originY + CGFloat(gridRows) * lineHeight
    for cell in cells where always || !cell.backgroundIsDefault {
      color(cell.background, alpha: preferences.opacity).setFill()
      if cell.y == 0 {
        NSRect(x: originX + CGFloat(cell.x) * cellWidth, y: 0,
          width: cell.occupancy == 1 ? cellWidth * 2 : cellWidth, height: originY).fill()
      }
      if cell.y == gridRows - 1 {
        NSRect(x: originX + CGFloat(cell.x) * cellWidth, y: gridBottom,
          width: cell.occupancy == 1 ? cellWidth * 2 : cellWidth,
          height: max(0, bounds.height - gridBottom)).fill()
      }
      if cell.x == 0 {
        NSRect(x: 0, y: originY + CGFloat(cell.y) * lineHeight,
          width: originX, height: lineHeight).fill()
      }
      if cell.x == gridColumns - 1 {
        NSRect(x: gridRight, y: originY + CGFloat(cell.y) * lineHeight,
          width: max(0, bounds.width - gridRight), height: lineHeight).fill()
      }
    }
  }

  private func drawImages(_ images: [TerminalRenderImage]) {
    guard !images.isEmpty else { return }
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(rect: NSRect(x: originX, y: originY,
      width: CGFloat(gridColumns) * cellWidth, height: CGFloat(gridRows) * lineHeight)).addClip()
    for placement in images {
      let destination = NSRect(
        x: originX + CGFloat(placement.viewportColumn) * cellWidth + placement.xOffset,
        y: originY + CGFloat(placement.viewportRow) * lineHeight + placement.yOffset,
        width: placement.pixelWidth, height: placement.pixelHeight)
      placement.image.draw(in: destination, from: placement.source, operation: .sourceOver,
        fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
    NSGraphicsContext.current?.restoreGraphicsState()
  }

  private func cellRect(_ cell: TerminalRenderCell) -> NSRect {
    let width = cell.occupancy == 1 ? cellWidth * 2 : cellWidth
    return NSRect(
      x: originX + CGFloat(cell.x) * cellWidth,
      y: originY + CGFloat(cell.y) * lineHeight,
      width: width,
      height: lineHeight
    )
  }

  private func drawBackground(_ cell: TerminalRenderCell) {
    let highlightBackground: NSColor? =
      cell.searchHighlight == 2 ? .systemOrange : cell.searchHighlight == 1 ? .systemYellow : nil
    if highlightBackground == nil && !cell.selected && cell.backgroundIsDefault { return }
    (highlightBackground ?? color(cell.selected ? cell.foreground : cell.background,
      alpha: preferences.opacity)).setFill()
    cellRect(cell).fill()
  }

  private func drawText(_ cells: [TerminalRenderCell]) {
    var run: TextRun?
    func flush() {
      guard let current = run else { return }
      drawText(String(decoding: current.bytes, as: UTF8.self), x: current.x, y: current.y,
        columns: current.nextX - current.x, style: current.style, batched: true)
      run = nil
    }
    for cell in cells {
      let columns = cell.occupancy == 1 ? 2 : 1
      if let scalar = proceduralScalar(cell.text),
        let mask = pseudographicsMask(codepoint: scalar, columns: columns)
      {
        flush()
        drawPseudographics(mask, cell: cell)
        continue
      }
      guard cell.occupancy == 0 else {
        flush()
        if !cell.text.isEmpty && cell.occupancy != 2 {
          drawText(cell.text, x: cell.x, y: cell.y, columns: columns,
            style: textStyle(cell), batched: false)
        }
        continue
      }
      let bytes = Array((cell.text.isEmpty ? " " : cell.text).utf8)
      let style = textStyle(cell)
      if var current = run, current.y == cell.y, current.nextX == cell.x, current.style == style {
        current.bytes.append(contentsOf: bytes)
        current.nextX += 1
        run = current
      } else {
        flush()
        run = TextRun(x: cell.x, y: cell.y, nextX: cell.x + 1, style: style, bytes: bytes)
      }
    }
    flush()
  }

  private func proceduralScalar(_ text: String) -> UInt32? {
    guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return nil }
    return zigonaut_pseudographics_covers(scalar.value) ? scalar.value : nil
  }

  private func pseudographicsMask(codepoint: UInt32, columns: Int) -> CGImage? {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    let baseWidth = max(1, Int((cellWidth * scale).rounded()))
    let width = max(1, Int((cellWidth * CGFloat(columns) * scale).rounded()))
    let height = max(1, Int((lineHeight * scale).rounded()))
    let underline = font.underlineThickness
    let underlineThickness = underline > 0 ? Int((underline * scale).rounded()) : 0
    let thickness = max(1, max(underlineThickness, (height + 8) / 16))
    let metrics = (baseWidth, height, thickness)
    if let previous = pseudographicsMetrics,
      previous.cellWidth != baseWidth || previous.height != height || previous.thickness != thickness
    {
      pseudographicsCache.removeAll(keepingCapacity: true)
    }
    pseudographicsMetrics = metrics
    let key = PseudographicsKey(codepoint: codepoint, width: width, height: height,
      thickness: thickness)
    if let image = pseudographicsCache[key] { return image }
    var bytes = Data(count: width * height)
    var result = zigonaut_pseudographics_result_v1()
    result.version = 1
    result.size = UInt16(MemoryLayout<zigonaut_pseudographics_result_v1>.size)
    let status = bytes.withUnsafeMutableBytes { storage in
      zigonaut_pseudographics_render(codepoint, UInt32(width), UInt32(height), UInt32(thickness),
        UInt32(width), storage.bindMemory(to: UInt8.self).baseAddress, storage.count, &result)
    }
    guard status == 0, result.status == 0, result.written_bytes == bytes.count else { return nil }
    // The shared A8 contract is top-down. Core Graphics maps a raw mask using
    // image coordinates even in this view's flipped AppKit context, so store
    // the cached image bottom-up to keep asymmetric blocks and diagonals upright.
    bytes.withUnsafeMutableBytes { storage in
      let pixels = storage.bindMemory(to: UInt8.self)
      for y in 0..<(height / 2) {
        let opposite = height - 1 - y
        for x in 0..<width {
          pixels.swapAt(y * width + x, opposite * width + x)
        }
      }
    }
    guard
      let provider = CGDataProvider(data: bytes as CFData),
      let image = CGImage(maskWidth: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
        bytesPerRow: width, provider: provider, decode: nil, shouldInterpolate: false)
    else { return nil }
    pseudographicsCache[key] = image
    return image
  }

  private func drawPseudographics(_ mask: CGImage, cell: TerminalRenderCell) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let rect = cellRect(cell)
    let style = textStyle(cell)
    context.saveGState()
    context.interpolationQuality = .none
    context.clip(to: rect, mask: mask)
    context.setFillColor(color(style.rgb, alpha: style.faint ? 0.55 : 1).cgColor)
    context.fill(rect)
    context.restoreGState()
  }

  private func textStyle(_ cell: TerminalRenderCell) -> TextStyle {
    TextStyle(
      rgb: cell.selected ? cell.background : cell.foreground,
      bold: cell.bold,
      italic: cell.italic,
      faint: cell.faint)
  }

  private func drawText(_ text: String, x: Int, y: Int, columns: Int, style: TextStyle, batched: Bool) {
    var traits: NSFontTraitMask = []
    if style.bold { traits.insert(.boldFontMask) }
    if style.italic { traits.insert(.italicFontMask) }
    let styledFont = styledFont(traits: traits)
    let foreground = color(style.rgb, alpha: style.faint ? 0.55 : 1)
    var attributes: [NSAttributedString.Key: Any] = [
      .font: styledFont,
      .foregroundColor: foreground,
    ]
    if batched && text.unicodeScalars.allSatisfy(\.isASCII) {
      attributes[.ligature] = 0
      attributes[.kern] = cellWidth - styledAdvance(traits: traits, font: styledFont)
    }
    let origin = NSPoint(
      x: originX + CGFloat(x) * cellWidth,
      y: originY + CGFloat(y) * lineHeight + font.ascender - styledFont.ascender)
    let target = NSRect(x: origin.x, y: origin.y, width: CGFloat(columns) * cellWidth,
      height: max(lineHeight, styledFont.ascender - styledFont.descender + styledFont.leading))
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(rect: target).addClip()
    NSAttributedString(string: text, attributes: attributes).draw(at: origin)
    NSGraphicsContext.current?.restoreGraphicsState()
  }

  private func drawMarkedText(_ frame: TerminalRenderFrame) {
    guard markedText.length > 0 else { return }
    let point = NSPoint(
      x: originX + CGFloat(frame.cursorX) * cellWidth,
      y: originY + CGFloat(frame.cursorY) * lineHeight)
    markedText.addAttributes(
      [
        .font: font, .foregroundColor: NSColor.textColor,
        .backgroundColor: NSColor.selectedTextBackgroundColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ],
      range: NSRange(location: 0, length: markedText.length))
    markedText.draw(at: point)
  }

  private func drawDecorations(_ cell: TerminalRenderCell, rect: NSRect) {
    guard cell.underlineStyle != 0 || cell.strikethrough || cell.overline else { return }
    color(cell.underlineColor).setStroke()
    switch cell.underlineStyle {
    case 1:
      strokeLine(y: rect.maxY - 1.5, rect: rect, width: 1)
    case 2:
      strokeLine(y: rect.maxY - 1, rect: rect, width: 1)
      strokeLine(y: rect.maxY - 3, rect: rect, width: 1)
    case 3:
      strokeWavyLine(y: rect.maxY - 2, rect: rect)
    case 4:
      strokePattern(y: rect.maxY - 1.5, rect: rect, pattern: [1, 2], rounded: true)
    case 5:
      strokePattern(y: rect.maxY - 1.5, rect: rect, pattern: [4, 2], rounded: false)
    default:
      if cell.underlineStyle != 0 { strokeLine(y: rect.maxY - 1.5, rect: rect, width: 1) }
    }
    if cell.strikethrough {
      strokeLine(y: rect.midY, rect: rect, width: 1)
    }
    if cell.overline {
      strokeLine(y: rect.minY + 1, rect: rect, width: 1)
    }
  }

  private func strokeLine(y: CGFloat, rect: NSRect, width: CGFloat) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX, y: y))
    path.line(to: NSPoint(x: rect.maxX, y: y))
    path.lineWidth = width
    path.stroke()
  }

  private func strokePattern(y: CGFloat, rect: NSRect, pattern: [CGFloat], rounded: Bool) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX, y: y))
    path.line(to: NSPoint(x: rect.maxX, y: y))
    path.lineWidth = 1
    path.setLineDash(pattern, count: pattern.count, phase: 0)
    path.lineCapStyle = rounded ? .round : .butt
    path.stroke()
  }

  private func strokeWavyLine(y: CGFloat, rect: NSRect) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX, y: y))
    var x = rect.minX + 1
    while x <= rect.maxX {
      let offset = sin((x - rect.minX) * .pi / 2)
      path.line(to: NSPoint(x: x, y: y + offset))
      x += 1
    }
    path.lineWidth = 1
    path.stroke()
  }

  private func drawCursor(_ frame: TerminalRenderFrame) {
    guard frame.cursorVisible else { return }
    let rect = NSRect(
      x: originX + CGFloat(frame.cursorX) * cellWidth,
      y: originY + CGFloat(frame.cursorY) * lineHeight,
      width: cellWidth * CGFloat(max(frame.cursorColumns, 1)),
      height: lineHeight
    )
    color(frame.cursor).setFill()
    switch frame.cursorStyle {
    case 0:
      NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height).fill()
    case 2:
      NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2).fill()
    case 3:
      color(frame.cursor).setStroke()
      let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
      path.stroke()
    default:
      rect.fill(using: .difference)
    }
  }
}

struct TerminalSurface: NSViewRepresentable {
  @ObservedObject var model: TerminalModel
  @ObservedObject var preferences: Preferences
  let focused: Bool
  let wantsKeyboardFocus: Bool
  let onFocus: () -> Void

  func makeNSView(context: Context) -> TerminalSurfaceView {
    TerminalSurfaceView(model: model, preferences: preferences, onFocus: onFocus)
  }

  func updateNSView(_ view: TerminalSurfaceView, context: Context) {
    view.preferences = preferences
    view.updateFont()
    view.onFocus = onFocus
    view.focused = focused
    let shouldClaimKeyboardFocus = wantsKeyboardFocus && !view.wantsKeyboardFocus
    view.wantsKeyboardFocus = wantsKeyboardFocus
    view.updateClipboardSettings()
    view.updateTerminalSettings()
    view.resizeTerminal()
    view.needsDisplay = true
    view.updateAccessibilityValue()
    view.setAccessibilityFocused(focused)
    if shouldClaimKeyboardFocus {
      view.window?.makeFirstResponder(view)
    }
  }
}
