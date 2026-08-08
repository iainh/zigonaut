import AppKit
import CoreText
import SwiftUI

final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient {
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
  private var lastAccessibilityValue = ""
  private var voiceOverObservation: NSKeyValueObservation?
  private var colorCache: [ColorKey: NSColor] = [:]
  private var appliedPalette: TerminalPalette?
  private var appliedScrollback = -1

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
    let value = String(model.accessibilityText().prefix(100_000))
    guard value != lastAccessibilityValue else { return }
    lastAccessibilityValue = value
    setAccessibilityValue(value)
    NSAccessibility.post(element: self, notification: .valueChanged)
  }

  override func accessibilityValue() -> Any? {
    if NSWorkspace.shared.isVoiceOverEnabled { return lastAccessibilityValue }
    return String(model.accessibilityText().prefix(100_000))
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
        self?.model.refresh()
        self?.updateAccessibilityValue()
      }
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateTerminalSettings()
    needsDisplay = true
  }

  override func becomeFirstResponder() -> Bool {
    needsDisplay = true
    return true
  }

  override func resignFirstResponder() -> Bool {
    needsDisplay = true
    return true
  }

  func resizeTerminal() {
    let columns = gridColumns
    let rows = gridRows
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    model.resize(columns: columns, rows: rows,
      pixelWidth: Int(bounds.width * scale), pixelHeight: Int(bounds.height * scale),
      cellWidth: Int(cellWidth * scale), cellHeight: Int(lineHeight * scale), scale: scale)
  }

  override func setFrameSize(_ size: NSSize) {
    super.setFrameSize(size)
    resizeTerminal()
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
    if wantsKeyboardFocus {
      window?.makeFirstResponder(self)
    }
  }

  override func keyDown(with event: NSEvent) {
    if !event.modifierFlags.contains(.command),
      event.modifierFlags.contains(.control),
      let characters = event.characters,
      !characters.isEmpty
    {
      model.write(characters)
      return
    }
    if let sequence = sequence(event) {
      model.write(sequence)
    } else {
      interpretKeyEvents([event])
    }
  }

  func insertText(_ value: Any, replacementRange: NSRange) {
    let string = (value as? NSAttributedString)?.string ?? (value as? String) ?? ""
    markedText = NSMutableAttributedString()
    markedSelection = NSRange(location: NSNotFound, length: 0)
    if !string.isEmpty { model.write(string) }
    needsDisplay = true
  }

  func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
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
    let close = menu.addItem(withTitle: "Close Pane or Tab", action: #selector(Delegate.closePane(_:)), keyEquivalent: "")
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
      model.scroll(rows)
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

  private func sequence(_ event: NSEvent) -> String? {
    let final: String
    switch event.keyCode {
    case 36, 76: return "\r"
    case 48: return "\t"
    case 51: return "\u{7f}"
    case 53: return "\u{1b}"
    case 123: final = "D"
    case 124: final = "C"
    case 125: final = "B"
    case 126: final = "A"
    default: return nil
    }
    var modifier = 1
    if event.modifierFlags.contains(.shift) { modifier += 1 }
    if event.modifierFlags.contains(.option) { modifier += 2 }
    if event.modifierFlags.contains(.control) { modifier += 4 }
    return modifier == 1 ? "\u{1b}[\(final)" : "\u{1b}[1;\(modifier)\(final)"
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
    if focused {
      NSColor.keyboardFocusIndicatorColor.setStroke()
      let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
      path.lineWidth = 3
      path.stroke()
    }
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
        style: current.style, batched: true)
      run = nil
    }
    for cell in cells {
      guard cell.occupancy == 0, let byte = asciiByte(cell.text) else {
        flush()
        if !cell.text.isEmpty && cell.occupancy != 2 {
          drawText(cell.text, x: cell.x, y: cell.y, style: textStyle(cell), batched: false)
        }
        continue
      }
      let style = textStyle(cell)
      if var current = run, current.y == cell.y, current.nextX == cell.x, current.style == style {
        current.bytes.append(byte)
        current.nextX += 1
        run = current
      } else {
        flush()
        run = TextRun(x: cell.x, y: cell.y, nextX: cell.x + 1, style: style, bytes: [byte])
      }
    }
    flush()
  }

  private func asciiByte(_ text: String) -> UInt8? {
    if text.isEmpty { return 0x20 }
    let bytes = text.utf8
    guard bytes.count == 1, let byte = bytes.first, byte < 0x80 else { return nil }
    return byte
  }

  private func textStyle(_ cell: TerminalRenderCell) -> TextStyle {
    TextStyle(
      rgb: cell.selected ? cell.background : cell.foreground,
      bold: cell.bold,
      italic: cell.italic,
      faint: cell.faint)
  }

  private func drawText(_ text: String, x: Int, y: Int, style: TextStyle, batched: Bool) {
    var traits: NSFontTraitMask = []
    if style.bold { traits.insert(.boldFontMask) }
    if style.italic { traits.insert(.italicFontMask) }
    let styledFont = styledFont(traits: traits)
    let foreground = color(style.rgb, alpha: style.faint ? 0.55 : 1)
    var attributes: [NSAttributedString.Key: Any] = [
      .font: styledFont,
      .foregroundColor: foreground,
    ]
    if batched {
      attributes[.ligature] = 0
      attributes[.kern] = cellWidth - styledAdvance(traits: traits, font: styledFont)
    }
    let origin = NSPoint(
      x: originX + CGFloat(x) * cellWidth,
      y: originY + CGFloat(y) * lineHeight + font.ascender - styledFont.ascender)
    (text as NSString).draw(at: origin, withAttributes: attributes)
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
    if cell.underlineStyle != 0 {
      strokeLine(y: rect.maxY - 1.5, rect: rect, width: cell.underlineStyle == 2 ? 2 : 1)
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
