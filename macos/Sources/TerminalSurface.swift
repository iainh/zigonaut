import AppKit
import CoreText
import SwiftUI

final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient {
  let model: TerminalModel
  var preferences: Preferences
  var focused = false
  var wantsKeyboardFocus = false
  var onFocus: () -> Void
  private var scrollRemainder: CGFloat = 0
  private var markedText = NSMutableAttributedString()
  private var markedSelection = NSRange(location: NSNotFound, length: 0)
  private var reportingButton: UInt8 = 0
  private var trackingArea: NSTrackingArea?
  private var lastMousePoint: NSPoint?

  private var font: NSFont {
    preferences.terminalFont(size: preferences.fontSize)
  }

  private var cellWidth: CGFloat {
    ceil(("M" as NSString).size(withAttributes: [.font: font]).width)
  }

  private var lineHeight: CGFloat {
    ceil(font.ascender - font.descender + font.leading)
  }

  init(model: TerminalModel, preferences: Preferences, onFocus: @escaping () -> Void) {
    self.model = model
    self.preferences = preferences
    self.onFocus = onFocus
    super.init(frame: .zero)
    wantsLayer = true
    setAccessibilityElement(true)
    setAccessibilityRole(.textArea)
    setAccessibilityLabel("Terminal")
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }

  override func becomeFirstResponder() -> Bool {
    needsDisplay = true
    return true
  }

  override func resignFirstResponder() -> Bool {
    needsDisplay = true
    return true
  }

  func resizeTerminal() {
    let columns = max(2, Int((bounds.width - 2 * preferences.padding) / cellWidth))
    let rows = max(2, Int((bounds.height - 2 * preferences.padding) / lineHeight))
    model.resize(columns: columns, rows: rows)
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
    let column = max(0, Int((point.x - preferences.padding) / cellWidth))
    let row = max(0, Int((point.y - preferences.padding) / lineHeight))
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
      x: preferences.padding + CGFloat(cursor.cursorX) * cellWidth,
      y: preferences.padding + CGFloat(cursor.cursorY) * lineHeight,
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
    let column = max(0, Int((point.x - preferences.padding) / cellWidth))
    let row = max(0, Int((point.y - preferences.padding) / lineHeight))
    return (column, row)
  }

  override func mouseDown(with event: NSEvent) {
    handleMouseDown(event)
  }
  override func rightMouseDown(with event: NSEvent) { handleMouseDown(event) }
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
    model.selectionBegin(point.0, point.1)
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
    model.selectionEnd()
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
      padding: Int(preferences.padding), modifiers: modifiers, pressed: pressed)
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
    NSColor(
      calibratedRed: CGFloat((rgb >> 16) & 0xff) / 255,
      green: CGFloat((rgb >> 8) & 0xff) / 255,
      blue: CGFloat(rgb & 0xff) / 255,
      alpha: alpha
    )
  }

  override func draw(_ dirtyRect: NSRect) {
    let snapshot = model.renderSnapshot
    color(snapshot.frame.background, alpha: preferences.opacity).setFill()
    bounds.fill()
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(rect: bounds).addClip()
    for cell in snapshot.cells {
      draw(cell)
    }
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

  private func draw(_ cell: TerminalRenderCell) {
    let width = cell.occupancy == 1 ? cellWidth * 2 : cellWidth
    let rect = NSRect(
      x: preferences.padding + CGFloat(cell.x) * cellWidth,
      y: preferences.padding + CGFloat(cell.y) * lineHeight,
      width: width,
      height: lineHeight
    )
    let highlightBackground: NSColor? =
      cell.searchHighlight == 2 ? .systemOrange : cell.searchHighlight == 1 ? .systemYellow : nil
    (highlightBackground ?? color(cell.selected ? cell.foreground : cell.background,
      alpha: preferences.opacity)).setFill()
    rect.fill()
    guard !cell.text.isEmpty, cell.occupancy != 2 else { return }
    var traits: NSFontTraitMask = []
    if cell.bold { traits.insert(.boldFontMask) }
    if cell.italic { traits.insert(.italicFontMask) }
    let styledFont = NSFontManager.shared.convert(font, toHaveTrait: traits)
    let foreground = color(
      cell.selected ? cell.background : cell.foreground, alpha: cell.faint ? 0.55 : 1)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: styledFont,
      .foregroundColor: foreground,
    ]
    let baseline = rect.minY + font.ascender
    (cell.text as NSString).draw(
      at: NSPoint(x: rect.minX, y: baseline - styledFont.ascender), withAttributes: attributes)
    drawDecorations(cell, rect: rect)
  }

  private func drawMarkedText(_ frame: TerminalRenderFrame) {
    guard markedText.length > 0 else { return }
    let point = NSPoint(
      x: preferences.padding + CGFloat(frame.cursorX) * cellWidth,
      y: preferences.padding + CGFloat(frame.cursorY) * lineHeight)
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
      x: preferences.padding + CGFloat(frame.cursorX) * cellWidth,
      y: preferences.padding + CGFloat(frame.cursorY) * lineHeight,
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
    view.onFocus = onFocus
    view.focused = focused
    let shouldClaimKeyboardFocus = wantsKeyboardFocus && !view.wantsKeyboardFocus
    view.wantsKeyboardFocus = wantsKeyboardFocus
    model.applyClipboardSettings()
    view.resizeTerminal()
    view.needsDisplay = true
    view.setAccessibilityValue(String(model.text.prefix(100_000)))
    view.setAccessibilityFocused(focused)
    NSAccessibility.post(element: view, notification: .valueChanged)
    if shouldClaimKeyboardFocus {
      view.window?.makeFirstResponder(view)
    }
  }
}
