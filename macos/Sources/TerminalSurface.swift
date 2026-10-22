import AppKit
import Carbon.HIToolbox
import CoreText
import Metal
import MetalKit
import QuartzCore
import SwiftUI
import ZigonautAccessibility
import ZigonautCore
import ZigonautRenderSupport

final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
  private struct TextStyle: Hashable {
    let rgb: UInt32
    let bold: Bool
    let italic: Bool
    let faint: Bool
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

  private struct GlyphKey: Hashable {
    let text: String
    let style: TextStyle
    let columns: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let batched: Bool
  }

  private struct CachedGlyph {
    let texture: MTLTexture
    let byteCount: Int
    var lastUsed: UInt64
  }

  private struct MetalTextPlacement {
    let text: String
    let x: Int
    let y: Int
    let columns: Int
    let style: TextStyle
    let batched: Bool
  }

  private struct HoveredLink: Equatable {
    let row: Int
    let startColumn: Int
    let endColumn: Int
  }

  let model: TerminalModel
  var preferences: Preferences
  var focused = false {
    didSet { updateFocus() }
  }
  var wantsKeyboardFocus = false
  var onFocus: () -> Void
  private var scrollRemainder: CGFloat = 0
  private let selectionPathBuffer = SelectionPathBuffer()
  private var wavyPaths: [CGFloat: NSBezierPath] = [:]
  private var markedText = NSMutableAttributedString()
  private var markedSelection = NSRange(location: NSNotFound, length: 0)
  private var reportingButton: UInt8 = 0
  private var selecting = false
  private var selectionShouldCopy = false
  private var copyFlash = false
  private var copyFlashTimer: Timer?
  private var trackingArea: NSTrackingArea?
  private var lastMousePoint: NSPoint?
  private var hoveredLink: HoveredLink?
  private var appliedMouseShape: UInt8?
  private var cachedFontFamily = ""
  private var cachedFontSize = 0.0
  private var cachedLineHeightPercent = 0.0
  private var cachedFontWeight = ""
  private var cachedIntenseFontWeight = ""
  private var cachedFonts: [UInt: NSFont] = [:]
  private var cachedCellWidth: CGFloat = 1
  private var cachedLineHeight: CGFloat = 1
  private var textOffsetY: CGFloat = 0
  private var cachedFontAdvances: [UInt: CGFloat] = [:]
  private var clipboardEnabled: Bool?
  private var clipboardMaximumBytes = 0
  private var accessibilityLayout = TerminalAccessibilityLayout()
  private var voiceOverObservation: NSKeyValueObservation?
  private var colorCache: [ColorKey: NSColor] = [:]
  private var pseudographicsCache: [PseudographicsKey: CGImage] = [:]
  private var pseudographicsMetrics: (cellWidth: Int, height: Int, thickness: Int)?
  private var appliedPalette: TerminalPalette?
  private var appliedScrollback = -1
  private var appliedIntenseTextStyle = ""
  private var metalLayer: CAMetalLayer?
  private var metalQueue: MTLCommandQueue?
  private var metalPipeline: MTLRenderPipelineState?
  private var metalImagePipeline: MTLRenderPipelineState?
  private var metalGlyphPipeline: MTLRenderPipelineState?
  private var metalOverlayPipeline: MTLRenderPipelineState?
  private var metalCursorPipeline: MTLRenderPipelineState?
  private var retainedTexture: MTLTexture?
  private var retainedScrollTexture: MTLTexture?
  private var retainedBitmap: CGContext?
  private var overlayTexture: MTLTexture?
  private var overlayBitmap: CGContext?
  private var decorationTexture: MTLTexture?
  private var decorationBitmap: CGContext?
  private var metalImageTextures: [TerminalImageKey: MTLTexture] = [:]
  private var metalGlyphTextures: [GlyphKey: CachedGlyph] = [:]
  private var metalGlyphUse: UInt64 = 0
  private var retainedRowHashes: [UInt64] = []
  private var retainedViewportOffset: UInt64?
  private var retainedAppearance = ""
  private var retainedPixelSize = CGSize.zero
  private var drawingRetainedScene = false
  private var cachedTextPlacements: [MetalTextPlacement] = []
  private var textRunBytes: [UInt8] = []
  private struct OverlayState: Equatable {
    let markedText: String
    let selection: NSRange
    let hints: UInt64
    let cursorX: Int
    let cursorY: Int
  }
  private struct DecorationState: Equatable {
    let hoveredLink: HoveredLink?
    let hints: UInt64
  }
  private var decorationSignature: DecorationState?
  private var overlaySignature: OverlayState?
  private var encodedKeys = Set<UInt16>()
  private var pressedModifiers = Set<UInt16>()
  private var pendingKeyEvent: NSEvent?
  private var pendingKeyUsedMarkedText = false
  private var linkHints: [TerminalHint] = []
  private var hintLabels: [zigonaut_hint_label_v1] = []
  private var hintInteraction = zigonaut_hint_interaction_v1()
  private var hintGeneration: UInt64 = 0
  private var hintCopies = false

  private var font: NSFont {
    styledFont(traits: [])
  }

  func updateFont() {
    guard cachedFontFamily != preferences.fontFamily || cachedFontSize != preferences.fontSize
      || cachedLineHeightPercent != preferences.lineHeightPercent
      || cachedFontWeight != preferences.fontWeight
      || cachedIntenseFontWeight != preferences.intenseFontWeight else {
      return
    }
    cachedFontFamily = preferences.fontFamily
    cachedFontSize = preferences.fontSize
    cachedLineHeightPercent = preferences.lineHeightPercent
    cachedFontWeight = preferences.fontWeight
    cachedIntenseFontWeight = preferences.intenseFontWeight
    cachedFonts.removeAll(keepingCapacity: true)
    cachedFontAdvances.removeAll(keepingCapacity: true)
    pseudographicsCache.removeAll(keepingCapacity: true)
    metalGlyphTextures.removeAll(keepingCapacity: true)
    pseudographicsMetrics = nil
    let base = preferences.terminalFont(size: preferences.fontSize)
    cachedFonts[0] = base
    cachedCellWidth = ceil(("M" as NSString).size(withAttributes: [.font: base]).width)
    let metrics = LineHeight(naturalHeight: base.ascender - base.descender + base.leading,
      percent: preferences.lineHeightPercent)
    cachedLineHeight = metrics.height
    textOffsetY = metrics.textOffset
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

  private var unscrolledOriginY: CGFloat {
    preferences.paddingBalance == "Centered"
      ? max(0, (bounds.height - CGFloat(gridRows) * lineHeight) / 2)
      : preferences.paddingVertical
  }

  private var scrollTranslation: CGFloat {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    return (model.renderSnapshot.frame.scrollOffset * lineHeight * scale).rounded() / scale
  }
  private var originY: CGFloat {
    unscrolledOriginY - (drawingRetainedScene ? 0 : scrollTranslation)
  }
  private var viewportRect: NSRect {
    NSRect(x: originX, y: unscrolledOriginY,
      width: CGFloat(gridColumns) * cellWidth, height: CGFloat(gridRows) * lineHeight)
  }

  private var isDarkAppearance: Bool {
    effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  func updateTerminalSettings() {
    let palette = preferences.terminalPalette(dark: isDarkAppearance, seed: model.themeSeed)
    guard palette != appliedPalette || preferences.scrollbackSize != appliedScrollback
      || preferences.intenseTextStyle != appliedIntenseTextStyle else { return }
    appliedPalette = palette
    appliedScrollback = preferences.scrollbackSize
    appliedIntenseTextStyle = preferences.intenseTextStyle
    colorCache.removeAll(keepingCapacity: true)
    model.applyTerminalSettings(palette: palette, scrollback: preferences.scrollbackSize,
      intenseTextStyle: preferences.intenseTextStyle)
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
      vertex VertexOut terminal_vertex(uint id [[vertex_id]], constant float2 &sampling [[buffer(1)]]) {
        const float2 positions[] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
        const float2 coordinates[] = { {0,1}, {1,1}, {0,0}, {1,0} };
        float2 uv = coordinates[id];
        uv.y = uv.y * sampling.x + sampling.y;
        return { float4(positions[id], 0, 1), uv };
      }
      vertex VertexOut placement_vertex(const device float4 *vertices [[buffer(0)]], uint id [[vertex_id]]) {
        return { float4(vertices[id].xy, 0, 1), vertices[id].zw };
      }
      fragment float4 terminal_fragment(VertexOut in [[stage_in]],
          texture2d<float> image [[texture(0)]]) {
        constexpr sampler nearest(coord::normalized, address::clamp_to_edge, filter::nearest);
        return image.sample(nearest, in.uv);
      }
      fragment float4 image_fragment(VertexOut in [[stage_in]],
          texture2d<float> image [[texture(0)]]) {
        constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
        return image.sample(linear, in.uv);
      }
      fragment float4 cursor_fragment(VertexOut in [[stage_in]], float4 current [[color(0)]],
          constant uint &difference [[buffer(0)]], constant float4 &cursor [[buffer(1)]]) {
        return difference != 0 ? float4(abs(current.rgb - cursor.rgb), current.a) : cursor;
      }
      """
    guard let library = try? device.makeLibrary(source: source, options: nil),
      let vertex = library.makeFunction(name: "terminal_vertex"),
      let placementVertex = library.makeFunction(name: "placement_vertex"),
      let fragment = library.makeFunction(name: "terminal_fragment"),
      let imageFragment = library.makeFunction(name: "image_fragment"),
      let cursorFragment = library.makeFunction(name: "cursor_fragment") else { return }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertex
    descriptor.fragmentFunction = fragment
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return }
    descriptor.vertexFunction = placementVertex
    descriptor.fragmentFunction = imageFragment
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    guard let imagePipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return }
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
    guard let glyphPipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return }
    descriptor.vertexFunction = vertex
    guard let overlayPipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return }
    descriptor.vertexFunction = placementVertex
    descriptor.fragmentFunction = cursorFragment
    descriptor.colorAttachments[0].isBlendingEnabled = false
    guard let cursorPipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return }
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
    metalImagePipeline = imagePipeline
    metalGlyphPipeline = glyphPipeline
    metalOverlayPipeline = overlayPipeline
    metalCursorPipeline = cursorPipeline
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
    model.setFocused(focused && window?.isKeyWindow == true)
    needsDisplay = true
    return true
  }

  func updateFocus() {
    model.setFocused(focused && window?.isKeyWindow == true && window?.firstResponder === self)
  }

  override func resignFirstResponder() -> Bool {
    model.setFocused(false)
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
    let area = NSTrackingArea(rect: bounds,
      options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
    super.updateTrackingAreas()
  }

  override func mouseMoved(with event: NSEvent) {
    lastMousePoint = convert(event.locationInWindow, from: nil)
    updateLinkCursor(event.modifierFlags)
  }

  override func mouseEntered(with event: NSEvent) {
    mouseMoved(with: event)
  }

  override func cursorUpdate(with event: NSEvent) {
    mouseMoved(with: event)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: Self.mouseCursor(model.renderSnapshot.frame.mouseShape))
  }

  // Use public AppKit pointers only. Shapes without a native equivalent use arrow.
  // Numeric values are the public GhosttyMouseShape ABI, not the text cursor style.
  static func mouseCursor(_ shape: UInt8) -> NSCursor {
    switch shape {
    case 1: return .contextualMenu
    case 3: return .pointingHand
    case 6, 7: return .crosshair
    case 8: return .iBeam
    case 9: return .iBeamCursorForVerticalLayout
    case 10: return .dragLink
    case 11: return .dragCopy
    case 13, 14: return .operationNotAllowed
    case 15: return .openHand
    case 12, 16, 17: return .closedHand
    case 18, 28: return .columnResize
    case 19, 29: return .rowResize
    case 20: return .resizeUp
    case 21: return .resizeRight
    case 22: return .resizeDown
    case 23: return .resizeLeft
    case 24, 27, 30: return .frameResize(position: .topRight, directions: .all)
    case 25, 26, 31: return .frameResize(position: .topLeft, directions: .all)
    case 32: return .zoomIn
    case 33: return .zoomOut
    default: return .arrow
    }
  }

  func updateMouseCursor(_ flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
    let shape = model.renderSnapshot.frame.mouseShape
    if appliedMouseShape != shape {
      appliedMouseShape = shape
      window?.invalidateCursorRects(for: self)
    }
    // Output can change the pointer without a mouse event. Never set the global
    // cursor from a background pane or while a divider/overlay owns the hit.
    guard let window, window.isKeyWindow, let content = window.contentView else { return }
    let location = window.mouseLocationOutsideOfEventStream
    guard content.hitTest(content.convert(location, from: nil)) === self else { return }
    lastMousePoint = convert(location, from: nil)
    updateLinkCursor(flags)
  }

  override func mouseExited(with event: NSEvent) {
    lastMousePoint = nil
    setHoveredLink(nil)
  }

  override func flagsChanged(with event: NSEvent) {
    updateMouseCursor(event.modifierFlags)
    let code = event.keyCode
    guard Self.modifierKeyCodes.contains(code) else { return }
    let releasing = pressedModifiers.contains(code)
    if releasing { pressedModifiers.remove(code) } else { pressedModifiers.insert(code) }
    sendKey(event, action: releasing ? 2 : 0, text: "")
  }

  private func updateLinkCursor(_ flags: NSEvent.ModifierFlags) {
    guard let point = lastMousePoint else { return }
    let requested = Self.mouseCursor(model.renderSnapshot.frame.mouseShape)
    guard flags.contains(.command) else {
      setHoveredLink(nil)
      requested.set()
      return
    }
    let grid = viewportRect
    guard grid.contains(point) else {
      setHoveredLink(nil)
      requested.set()
      return
    }
    let column = max(0, Int((point.x - originX) / cellWidth))
    let row = max(0, Int((point.y - originY) / lineHeight))
    guard let link = model.link(column: column, row: row) else {
      setHoveredLink(nil)
      requested.set()
      return
    }
    setHoveredLink(HoveredLink(
      row: link.row, startColumn: link.startColumn, endColumn: link.endColumn))
    NSCursor.pointingHand.set()
  }

  private func setHoveredLink(_ value: HoveredLink?) {
    guard hoveredLink != value else { return }
    hoveredLink = value
    needsDisplay = true
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
    metalGlyphTextures.removeAll(keepingCapacity: true)
    retainedPixelSize = .zero
    needsDisplay = true
  }

  override func keyDown(with event: NSEvent) {
    if !linkHints.isEmpty {
      handleHintKey(event)
      return
    }
    if event.keyCode == 32, event.modifierFlags.contains([.command, .shift]) {
      linkHints = model.linkHints()
      hintLabels = linkHints.map(\.label)
      hintInteraction = zigonaut_hint_interaction_v1()
      hintGeneration &+= 1
      hintCopies = event.modifierFlags.contains(.option)
      needsDisplay = true
      return
    }
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
      // AppKit represents arrows and other function keys as private-use
      // Unicode characters. Only forward the physical key so the terminal
      // encoder emits the corresponding escape sequence instead of that text.
      sendKey(event, action: event.isARepeat ? 1 : 0, text: "")
      encodedKeys.insert(event.keyCode)
      return
    }
    if event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.option) {
      // AppKit maps control characters such as Ctrl-D to editing commands, so
      // interpretKeyEvents may never commit text for the terminal to encode.
      sendKey(event, action: event.isARepeat ? 1 : 0,
        text: event.charactersIgnoringModifiers ?? "")
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

  private func handleHintKey(_ event: NSEvent) {
    let key: UInt8
    switch event.keyCode {
    case 53: key = 27
    case 51: key = 8
    default:
      guard let value = event.charactersIgnoringModifiers?.lowercased(), value.count == 1,
        let ascii = value.utf8.first, value.utf8.count == 1 else { return }
      key = ascii
    }
    let result = hintLabels.withUnsafeBufferPointer {
      zigonaut_hint_key(&hintInteraction, $0.baseAddress, UInt32($0.count), key)
    }
    switch result {
    case -1: return
    case -2:
      hintGeneration &+= 1
      needsDisplay = true
    case -3, -4:
      if result == -4 { NSSound.beep() }
      cancelHints()
    default:
      let match = linkHints[Int(result)]
      if hintCopies {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(match.url.absoluteString, forType: .string)
      } else {
        NSWorkspace.shared.open(match.url)
      }
      cancelHints()
    }
  }

  private func cancelHints() {
    linkHints = []
    hintLabels = []
    hintInteraction = zigonaut_hint_interaction_v1()
    hintGeneration &+= 1
    needsDisplay = true
  }

  private func hintSuffix(_ hint: TerminalHint) -> zigonaut_hint_suffix_v1? {
    var label = hint.label
    var suffix = zigonaut_hint_suffix_v1()
    return zigonaut_hint_suffix(&hintInteraction, &label, &suffix) ? suffix : nil
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
      sendKey(event, action: event.isARepeat ? 1 : 0, text: string)
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
    copySelection()
  }

  private func copySelection() {
    guard model.copy() else { return }
    copyFlashTimer?.invalidate()
    copyFlash = true
    needsDisplay = true
    copyFlashTimer = Timer.scheduledTimer(
      timeInterval: 0.15, target: self, selector: #selector(endCopyFlash(_:)),
      userInfo: nil, repeats: false)
  }

  @objc private func endCopyFlash(_ timer: Timer) {
    copyFlashTimer = nil
    copyFlash = false
    needsDisplay = true
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
    let lastRow = gridRows - (model.renderSnapshot.frame.scrollOffset > 0 ? 0 : 1)
    let row = min(lastRow, max(0, Int(floor((point.y - originY) / lineHeight))))
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
    if event.modifierFlags.contains(.command), let link = model.link(column: point.0, row: point.1) {
      NSWorkspace.shared.open(link.url)
      return
    }
    if shouldReport(event) {
      reportingButton = mouseButton(event)
      sendMouse(event, action: 0, button: reportingButton, pressed: true)
      return
    }
    selecting = true
    selectionShouldCopy = event.clickCount >= 2
    let unit: UInt8 = event.clickCount >= 4 ? 5
      : event.clickCount == 3 ? 4
      : event.clickCount == 2 && event.modifierFlags.contains(.shift) ? 3
      : event.clickCount == 2 ? 1 : 0
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
    if location.y < unscrolledOriginY {
      model.scroll(1)
    } else if location.y > unscrolledOriginY + CGFloat(gridRows) * lineHeight {
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
      // Finish the synchronous snapshot work before starting the short flash.
      model.refresh()
      copySelection()
    } else {
      model.clearSelection()
      model.refresh()
    }
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
    guard event.scrollingDeltaY != 0 else { return }
    if shouldReport(event) {
      scrollRemainder = 0
      let count = max(1, Int(abs(event.scrollingDeltaY) / max(1, lineHeight)))
      let button: UInt8 = event.scrollingDeltaY > 0 ? 4 : 5
      for _ in 0..<count { sendMouse(event, action: 0, button: button, pressed: false) }
      return
    }
    if event.hasPreciseScrollingDeltas {
      scrollRemainder = 0
      model.scrollFractional(-Double(event.scrollingDeltaY / max(1, lineHeight)))
      return
    }
    // Discrete wheels report ticks rather than point distances.
    scrollRemainder += event.scrollingDeltaY * 3
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
      paddingTop: Int(unscrolledOriginY),
      paddingBottom: Int(max(0, bounds.height - unscrolledOriginY - CGFloat(gridRows) * lineHeight)),
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
    drawingRetainedScene = true
    drawEdgeColors(snapshot.cells)
    drawingRetainedScene = false
    NSBezierPath(rect: viewportRect).addClip()
    drawBackgrounds(snapshot.cells, selectionPath: roundedSelectionPath(snapshot.cellsByRow))
    drawText(snapshot.cells)
    for cell in snapshot.cells where !cell.textBytes.isEmpty && cell.occupancy != 2 {
      drawDecorations(cell, rect: cellRect(cell), forceUnderline: isHoveredLinkCell(cell))
    }
    drawImages(snapshot.images)
    drawCursor(snapshot.frame)
    drawMarkedText(snapshot.frame)
    drawHintLabels()
    NSGraphicsContext.current?.restoreGraphicsState()
  }

  private func renderMetal() -> Bool {
    guard let presentation = metalLayer, let queue = metalQueue, let pipeline = metalPipeline,
      let imagePipeline = metalImagePipeline, let overlayPipeline = metalOverlayPipeline,
      let glyphPipeline = metalGlyphPipeline, let cursorPipeline = metalCursorPipeline,
      let device = presentation.device,
      let geometry = updateMetalGeometry() else { return false }
    let scale = geometry.scale
    let pixelWidth = geometry.width
    // Keep a full, stationary overscan row in the retained backing stores.
    let pixelHeight = geometry.height + Int(ceil(lineHeight * scale))
    let pixelSize = CGSize(width: pixelWidth, height: pixelHeight)
    if retainedBitmap == nil || retainedPixelSize != pixelSize {
      let colorSpace = CGColorSpaceCreateDeviceRGB()
      retainedBitmap = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
        bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
      overlayBitmap = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
        bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
      decorationBitmap = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
        bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
      retainedBitmap?.translateBy(x: 0, y: CGFloat(pixelHeight))
      retainedBitmap?.scaleBy(x: scale, y: -scale)
      overlayBitmap?.translateBy(x: 0, y: CGFloat(pixelHeight))
      overlayBitmap?.scaleBy(x: scale, y: -scale)
      decorationBitmap?.translateBy(x: 0, y: CGFloat(pixelHeight))
      decorationBitmap?.scaleBy(x: scale, y: -scale)
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
        width: pixelWidth, height: pixelHeight, mipmapped: false)
      descriptor.usage = [.shaderRead]
      descriptor.storageMode = .shared
      retainedTexture = device.makeTexture(descriptor: descriptor)
      retainedScrollTexture = device.makeTexture(descriptor: descriptor)
      overlayTexture = device.makeTexture(descriptor: descriptor)
      decorationTexture = device.makeTexture(descriptor: descriptor)
      retainedPixelSize = pixelSize
      retainedRowHashes = []
      retainedViewportOffset = nil
      decorationSignature = nil
      overlaySignature = nil
    }
    guard let bitmap = retainedBitmap, let texture = retainedTexture,
      let overlayBitmap, let overlayTexture, let decorationBitmap, let decorationTexture,
      let data = bitmap.data else { return disableMetal() }
    let snapshot = model.renderSnapshot
    let appearance = [
      preferences.fontFamily, String(preferences.fontSize), preferences.fontWeight,
      String(preferences.lineHeightPercent),
      preferences.intenseFontWeight, preferences.intenseTextStyle, String(preferences.paddingHorizontal),
      String(preferences.paddingVertical), preferences.paddingBalance, preferences.paddingColor,
      String(preferences.opacity), String(copyFlash),
    ].joined(separator: "|")
    var forceAll = retainedAppearance != appearance
      || retainedRowHashes.count != snapshot.rowHashes.count || snapshot.rowHashes.isEmpty
    let rowCount = snapshot.rowHashes.isEmpty ? gridRows : snapshot.rowHashes.count
    drawingRetainedScene = true
    var scrollDelta: Int?
    if !forceAll, let previousOffset = retainedViewportOffset,
      previousOffset != snapshot.viewportOffset
    {
      scrollDelta = RetainedScroll.rowDelta(
        previousOffset: previousOffset, currentOffset: snapshot.viewportOffset, rowCount: rowCount)
      if let delta = scrollDelta {
        if !shiftRetainedScene(delta: delta, rowCount: rowCount, scale: scale,
          pixelWidth: pixelWidth, pixelHeight: pixelHeight, bitmap: bitmap)
        {
          scrollDelta = nil
          forceAll = true
        }
      } else {
        forceAll = true
      }
    }
    let dirtyRows = forceAll ? [] : snapshot.rowHashes.indices.filter { row in
      guard let delta = scrollDelta else {
        return retainedRowHashes[row] != snapshot.rowHashes[row]
      }
      guard let source = RetainedScroll.sourceRow(
        for: row, delta: delta, rowCount: rowCount) else { return true }
      return retainedRowHashes[source] != snapshot.rowHashes[row]
    }
    let sceneChanged = forceAll || !dirtyRows.isEmpty
    if sceneChanged {
      let refreshPadding = forceAll || scrollDelta != nil || dirtyRows.contains(gridRows - 1)
      rasterize(snapshot: snapshot, rowCount: rowCount, rows: forceAll ? nil : dirtyRows,
        refreshPadding: refreshPadding, in: bitmap)
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
        let paddingY = min(pixelHeight, max(0,
          Int(floor((unscrolledOriginY + CGFloat(gridRows + 1) * lineHeight) * scale))))
        if refreshPadding && paddingY < pixelHeight {
          texture.replace(region: MTLRegionMake2D(0, paddingY, pixelWidth, pixelHeight - paddingY),
            mipmapLevel: 0, withBytes: data.advanced(by: paddingY * bitmap.bytesPerRow),
            bytesPerRow: bitmap.bytesPerRow)
        }
      }
      retainedRowHashes = snapshot.rowHashes
      retainedAppearance = appearance
    }
    retainedViewportOffset = snapshot.viewportOffset
    drawingRetainedScene = false
    // Glyph placements/resources are independent of the subrow translation.
    if sceneChanged {
      cachedTextPlacements = metalTextPlacements(snapshot.cells)
    }
    let hasOverlay = markedText.length > 0 || !linkHints.isEmpty
    if !hasOverlay { overlaySignature = nil }
    let nextOverlaySignature = OverlayState(markedText: markedText.string,
      selection: markedSelection, hints: hintGeneration,
      cursorX: snapshot.frame.cursorX, cursorY: snapshot.frame.cursorY)
    if hasOverlay && (sceneChanged || overlaySignature != nextOverlaySignature) {
      drawingRetainedScene = true
      rasterizeOverlay(frame: snapshot.frame, in: overlayBitmap)
      drawingRetainedScene = false
      overlaySignature = nextOverlaySignature
      guard let overlayData = overlayBitmap.data else { return disableMetal() }
      overlayTexture.replace(region: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight), mipmapLevel: 0,
        withBytes: overlayData, bytesPerRow: overlayBitmap.bytesPerRow)
    }
    let textPlacements = cachedTextPlacements
    if sceneChanged && !prepareMetalGlyphs(textPlacements, device: device, scale: scale) {
      return disableMetal()
    }
    let hasDecorations = snapshot.cells.contains {
      !$0.textBytes.isEmpty && $0.occupancy != 2
        && ($0.underlineStyle != 0 || $0.strikethrough || $0.overline)
    } || hoveredLink != nil || !linkHints.isEmpty
    if !hasDecorations { decorationSignature = nil }
    let nextDecorationSignature = DecorationState(hoveredLink: hoveredLink, hints: hintGeneration)
    if hasDecorations && (sceneChanged || nextDecorationSignature != decorationSignature) {
      drawingRetainedScene = true
      rasterizeDecorations(snapshot.cells, in: decorationBitmap)
      drawingRetainedScene = false
      decorationSignature = nextDecorationSignature
      guard let decorationData = decorationBitmap.data else { return disableMetal() }
      decorationTexture.replace(region: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight), mipmapLevel: 0,
        withBytes: decorationData, bytesPerRow: decorationBitmap.bytesPerRow)
    }
    guard let drawable = presentation.nextDrawable() else { return disableMetal() }
    guard let command = queue.makeCommandBuffer() else { return disableMetal() }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return disableMetal() }
    // Paint stationary padding first, then translate only the clipped grid.
    var sampling = SIMD2<Float>(Float(geometry.height) / Float(pixelHeight), 0)
    encoder.setVertexBytes(&sampling, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentTexture(texture, index: 0)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    // Bottom padding is stored after overscan, not underneath its cells.
    let paddingTop = min(geometry.height, max(0, Int(viewportRect.maxY * scale)))
    if paddingTop < geometry.height {
      encoder.setScissorRect(MTLScissorRect(x: 0, y: paddingTop,
        width: geometry.width, height: geometry.height - paddingTop))
      sampling[1] = Float(lineHeight * scale) / Float(pixelHeight)
      encoder.setVertexBytes(&sampling, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
    let intersection = viewportRect.intersection(bounds)
    let clip = intersection.isEmpty ? bounds : intersection
    let clipX = min(geometry.width - 1, max(0, Int(clip.minX * scale)))
    let clipY = min(geometry.height - 1, max(0, Int(clip.minY * scale)))
    encoder.setScissorRect(MTLScissorRect(x: clipX, y: clipY,
      width: min(geometry.width - clipX, max(1, Int(clip.width * scale))),
      height: min(geometry.height - clipY, max(1, Int(clip.height * scale)))))
    sampling[1] = Float(scrollTranslation * scale) / Float(pixelHeight)
    encoder.setVertexBytes(&sampling, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    drawMetalText(textPlacements, encoder: encoder, pipeline: glyphPipeline, scale: scale)
    if hasDecorations {
      encoder.setRenderPipelineState(overlayPipeline)
      encoder.setFragmentTexture(decorationTexture, index: 0)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
    drawMetalImages(snapshot.images, encoder: encoder, pipeline: imagePipeline)
    if hasOverlay {
      encoder.setRenderPipelineState(overlayPipeline)
      encoder.setFragmentTexture(overlayTexture, index: 0)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
    drawMetalCursor(snapshot.frame, encoder: encoder, pipeline: cursorPipeline)
    encoder.endEncoding()
    if let trace = model.takeLatencyTrace() {
      TerminalLatencyTrace.signposter.emitEvent("NativeRasterCompleted", id: trace)
      drawable.addPresentedHandler { _ in
        TerminalLatencyTrace.signposter.emitEvent("CompositorPresented", id: trace)
      }
    }
    command.present(drawable)
    command.commit()
    presentation.isHidden = false
    return true
  }

  private func rasterizeOverlay(frame: TerminalRenderFrame, in bitmap: CGContext) {
    bitmap.clear(CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height + lineHeight))
    let context = NSGraphicsContext(cgContext: bitmap, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawMarkedText(frame)
    drawHintLabels()
    NSGraphicsContext.restoreGraphicsState()
  }

  private func drawHintLabels() {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: max(9, preferences.fontSize - 1), weight: .bold),
      .foregroundColor: NSColor.black,
      .backgroundColor: NSColor.systemYellow,
    ]
    for hint in linkHints {
      guard let suffix = hintSuffix(hint), suffix.length > 0 else { continue }
      let text = withUnsafeBytes(of: hint.label.bytes) {
        String(decoding: $0[Int(suffix.offset)..<Int(suffix.offset + suffix.length)], as: UTF8.self)
      }
      NSAttributedString(string: text, attributes: attributes).draw(at: NSPoint(
        x: originX + CGFloat(hint.startColumn) * cellWidth,
        y: originY + CGFloat(hint.row) * lineHeight))
    }
  }

  private func metalTextPlacements<C: Collection>(_ cells: C) -> [MetalTextPlacement]
    where C.Element == TerminalRenderCell
  {
    var placements: [MetalTextPlacement] = []
    prepareText(cells, drawBuiltins: false) { placements.append($0) }
    return placements
  }

  private func prepareText<C: Collection>(_ cells: C, drawBuiltins: Bool,
    emit: (MetalTextPlacement) -> Void) where C.Element == TerminalRenderCell
  {
    var state = zigonaut_text_run_state()
    var bytes = textRunBytes
    textRunBytes = []
    defer { bytes.removeAll(keepingCapacity: true); textRunBytes = bytes }
    var x = 0
    var y = 0
    var columns = 0
    var runStyle: TextStyle?
    func flush() {
      guard let style = runStyle else { return }
      emit(MetalTextPlacement(text: String(decoding: bytes, as: UTF8.self),
        x: x, y: y, columns: columns, style: style, batched: true))
      bytes.removeAll(keepingCapacity: true)
      runStyle = nil
    }
    for cell in cells {
      let style = textStyle(cell)
      let span = cell.occupancy == 1 ? 2 : 1
      let scalar = proceduralScalar(cell.textBytes)
      let mask = drawBuiltins ? scalar.flatMap { pseudographicsMask(codepoint: $0, columns: span) } : nil
      var input = zigonaut_text_run_input(column: UInt32(cell.x), row: UInt32(cell.y),
        columns: UInt32(span), foreground: style.rgb,
        style: (style.bold ? 1 : 0) | (style.italic ? 2 : 0) | (style.faint ? 4 : 0),
        occupancy: UInt32(cell.occupancy),
        builtin: scalar != nil && (!drawBuiltins || mask != nil) ? 1 : 0,
        empty: cell.textBytes.isEmpty ? 1 : 0)
      let action = zigonaut_text_run_push(&state, &input, false)
      if action != UInt32(ZIGONAUT_RUN_APPEND) && action != UInt32(ZIGONAUT_RUN_SKIP) { flush() }
      switch action {
      case UInt32(ZIGONAUT_RUN_BUILTIN):
        if let mask { drawPseudographics(mask, cell: cell) }
      case UInt32(ZIGONAUT_RUN_SINGLE):
        emit(MetalTextPlacement(text: cell.text, x: cell.x, y: cell.y,
          columns: span, style: style, batched: false))
      case UInt32(ZIGONAUT_RUN_START), UInt32(ZIGONAUT_RUN_APPEND):
        if runStyle == nil { x = cell.x; y = cell.y; columns = 0; runStyle = style }
        if cell.textBytes.isEmpty { bytes.append(32) } else { bytes.append(contentsOf: cell.textBytes) }
        columns += span
      default: break
      }
    }
    flush()
  }

  private func glyphKey(_ placement: MetalTextPlacement, scale: CGFloat) -> GlyphKey? {
    guard !placement.text.allSatisfy({ $0 == " " }) else { return nil }
    return GlyphKey(text: placement.text, style: placement.style, columns: placement.columns,
      pixelWidth: max(1, Int((CGFloat(placement.columns) * cellWidth * scale).rounded(.up))),
      pixelHeight: max(1, Int((lineHeight * scale).rounded(.up))), batched: placement.batched)
  }

  private func prepareMetalGlyphs(_ placements: [MetalTextPlacement], device: MTLDevice,
    scale: CGFloat) -> Bool
  {
    metalGlyphUse &+= 1
    if metalGlyphUse == 0 { metalGlyphUse = 1 }
    let loader = MTKTextureLoader(device: device)
    var active = Set<GlyphKey>()
    for placement in placements {
      guard let key = glyphKey(placement, scale: scale) else { continue }
      active.insert(key)
      if var cached = metalGlyphTextures[key] {
        cached.lastUsed = metalGlyphUse
        metalGlyphTextures[key] = cached
        continue
      }
      guard let texture = makeGlyphTexture(key, loader: loader, scale: scale) else { return false }
      metalGlyphTextures[key] = CachedGlyph(
        texture: texture, byteCount: texture.width * texture.height * 4, lastUsed: metalGlyphUse)
    }
    let maximumGlyphs = 2_048
    let maximumBytes = 64 * 1_024 * 1_024
    var cachedBytes = metalGlyphTextures.values.reduce(0) { $0 + $1.byteCount }
    if metalGlyphTextures.count > maximumGlyphs || cachedBytes > maximumBytes {
      let removable = metalGlyphTextures
        .filter { !active.contains($0.key) }
        .sorted { $0.value.lastUsed < $1.value.lastUsed }
      for entry in removable {
        guard metalGlyphTextures.count > maximumGlyphs || cachedBytes > maximumBytes else { break }
        metalGlyphTextures.removeValue(forKey: entry.key)
        cachedBytes -= entry.value.byteCount
      }
    }
    return true
  }

  private func makeGlyphTexture(_ key: GlyphKey, loader: MTKTextureLoader,
    scale: CGFloat) -> MTLTexture?
  {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let bitmap = CGContext(data: nil, width: key.pixelWidth, height: key.pixelHeight,
      bitsPerComponent: 8, bytesPerRow: key.pixelWidth * 4, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    bitmap.translateBy(x: 0, y: CGFloat(key.pixelHeight))
    bitmap.scaleBy(x: scale, y: -scale)
    let context = NSGraphicsContext(cgContext: bitmap, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    var traits: NSFontTraitMask = []
    if key.style.bold { traits.insert(.boldFontMask) }
    if key.style.italic { traits.insert(.italicFontMask) }
    let glyphFont = styledFont(traits: traits)
    var attributes: [NSAttributedString.Key: Any] = [
      .font: glyphFont,
      .foregroundColor: color(key.style.rgb, alpha: key.style.faint ? 0.55 : 1),
    ]
    if key.batched && key.text.unicodeScalars.allSatisfy(\.isASCII) {
      attributes[.ligature] = 0
      attributes[.kern] = cellWidth - styledAdvance(traits: traits, font: glyphFont)
    }
    let target = NSRect(x: 0, y: 0, width: CGFloat(key.columns) * cellWidth, height: lineHeight)
    NSBezierPath(rect: target).addClip()
    NSAttributedString(string: key.text, attributes: attributes).draw(
      at: NSPoint(x: 0, y: textOffsetY + font.ascender - glyphFont.ascender))
    NSGraphicsContext.restoreGraphicsState()
    guard let image = bitmap.makeImage() else { return nil }
    return try? loader.newTexture(cgImage: image, options: [
      .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft,
    ])
  }

  private func drawMetalText(_ placements: [MetalTextPlacement], encoder: MTLRenderCommandEncoder,
    pipeline: MTLRenderPipelineState, scale: CGFloat)
  {
    encoder.setRenderPipelineState(pipeline)
    for placement in placements {
      guard let key = glyphKey(placement, scale: scale),
        let cached = metalGlyphTextures[key] else { continue }
      let destination = CGRect(
        x: originX + CGFloat(placement.x) * cellWidth,
        y: originY + CGFloat(placement.y) * lineHeight,
        width: CGFloat(placement.columns) * cellWidth, height: lineHeight)
      var vertices = quadVertices(destination: destination,
        source: CGRect(x: 0, y: 0, width: cached.texture.width, height: cached.texture.height),
        textureWidth: CGFloat(cached.texture.width), textureHeight: CGFloat(cached.texture.height))
      withUnsafeBytes(of: &vertices) { bytes in
        encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
      }
      encoder.setFragmentTexture(cached.texture, index: 0)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
  }

  private func rasterizeDecorations<C: Collection>(_ cells: C, in bitmap: CGContext)
    where C.Element == TerminalRenderCell
  {
    bitmap.clear(CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height + lineHeight))
    let context = NSGraphicsContext(cgContext: bitmap, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    for cell in cells where !cell.textBytes.isEmpty && cell.occupancy != 2 {
      drawDecorations(cell, rect: cellRect(cell), forceUnderline: isHoveredLinkCell(cell))
    }
    NSGraphicsContext.restoreGraphicsState()
  }

  private func isHoveredLinkCell(_ cell: TerminalRenderCell) -> Bool {
    if let hoveredLink, cell.y == hoveredLink.row && cell.x >= hoveredLink.startColumn
      && cell.x < hoveredLink.endColumn { return true }
    return linkHints.contains { hint in
      hintSuffix(hint) != nil && cell.y == hint.row
        && cell.x >= hint.startColumn && cell.x < hint.endColumn
    }
  }

  private func drawMetalImages(_ images: [TerminalRenderImage], encoder: MTLRenderCommandEncoder,
    pipeline: MTLRenderPipelineState)
  {
    let active = Set(images.map(\.key))
    metalImageTextures = metalImageTextures.filter { active.contains($0.key) }
    guard !images.isEmpty, bounds.width > 0, bounds.height > 0,
      let device = retainedTexture?.device else { return }
    let loader = MTKTextureLoader(device: device)
    let clip = ImageRect(x: Double(originX), y: Double(unscrolledOriginY),
      width: Double(CGFloat(gridColumns) * cellWidth),
      height: Double(CGFloat(gridRows) * lineHeight))
    encoder.setRenderPipelineState(pipeline)
    for placement in images {
      let destination = ImageRect(
        x: Double(originX + CGFloat(placement.viewportColumn) * cellWidth + placement.xOffset),
        y: Double(originY + CGFloat(placement.viewportRow) * lineHeight + placement.yOffset),
        width: Double(placement.pixelWidth), height: Double(placement.pixelHeight))
      guard let quad = ImageGeometry.clippedQuad(
        destination: destination,
        source: ImageRect(x: Double(placement.sourcePixels.minX),
          y: Double(placement.sourcePixels.minY), width: Double(placement.sourcePixels.width),
          height: Double(placement.sourcePixels.height)), clip: clip) else { continue }
      let texture: MTLTexture
      if let cached = metalImageTextures[placement.key] {
        texture = cached
      } else {
        guard let loaded = try? loader.newTexture(cgImage: placement.cgImage, options: [
          .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft,
        ]) else { continue }
        metalImageTextures[placement.key] = loaded
        texture = loaded
      }
      let destinationRect = CGRect(x: quad.destination.x, y: quad.destination.y,
        width: quad.destination.width, height: quad.destination.height)
      let sourceRect = CGRect(x: quad.source.x, y: quad.source.y,
        width: quad.source.width, height: quad.source.height)
      let left = Float(destinationRect.minX / bounds.width * 2 - 1)
      let right = Float(destinationRect.maxX / bounds.width * 2 - 1)
      let top = Float(1 - destinationRect.minY / bounds.height * 2)
      let bottom = Float(1 - destinationRect.maxY / bounds.height * 2)
      let u0 = Float(sourceRect.minX / CGFloat(texture.width))
      let u1 = Float(sourceRect.maxX / CGFloat(texture.width))
      let v0 = Float(sourceRect.minY / CGFloat(texture.height))
      let v1 = Float(sourceRect.maxY / CGFloat(texture.height))
      // Four inline position/UV records, not a heap array for each placement.
      var vertices = (SIMD4(left, bottom, u0, v1), SIMD4(right, bottom, u1, v1),
        SIMD4(left, top, u0, v0), SIMD4(right, top, u1, v0))
      withUnsafeBytes(of: &vertices) { bytes in
        encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
      }
      encoder.setFragmentTexture(texture, index: 0)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
  }

  private func quadVertices(destination: CGRect, source: CGRect,
    textureWidth: CGFloat = 1, textureHeight: CGFloat = 1
  ) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
  {
    let left = Float(destination.minX / bounds.width * 2 - 1)
    let right = Float(destination.maxX / bounds.width * 2 - 1)
    let top = Float(1 - destination.minY / bounds.height * 2)
    let bottom = Float(1 - destination.maxY / bounds.height * 2)
    let u0 = Float(source.minX / textureWidth)
    let u1 = Float(source.maxX / textureWidth)
    let v0 = Float(source.minY / textureHeight)
    let v1 = Float(source.maxY / textureHeight)
    return (SIMD4(left, bottom, u0, v1), SIMD4(right, bottom, u1, v1),
      SIMD4(left, top, u0, v0), SIMD4(right, top, u1, v0))
  }

  private func drawMetalCursor(_ frame: TerminalRenderFrame, encoder: MTLRenderCommandEncoder,
    pipeline: MTLRenderPipelineState)
  {
    guard frame.cursorVisible else { return }
    let rect = CGRect(x: originX + CGFloat(frame.cursorX) * cellWidth,
      y: originY + CGFloat(frame.cursorY) * lineHeight,
      width: cellWidth * CGFloat(max(frame.cursorColumns, 1)), height: lineHeight)
    var difference: UInt32 = frame.cursorStyle == 1 ? 1 : 0
    var cursor = SIMD4<Float>(Float((frame.cursor >> 16) & 0xff) / 255,
      Float((frame.cursor >> 8) & 0xff) / 255, Float(frame.cursor & 0xff) / 255, 1)
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentBytes(&difference, length: MemoryLayout<UInt32>.stride, index: 0)
    encoder.setFragmentBytes(&cursor, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
    func draw(_ rectangle: CGRect) {
      var vertices = quadVertices(destination: rectangle, source: .zero)
      withUnsafeBytes(of: &vertices) { bytes in
        encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
      }
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
    switch frame.cursorStyle {
    case 0: draw(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height))
    case 2: draw(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2))
    case 3:
      draw(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1))
      draw(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))
      draw(CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height))
      draw(CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height))
    default: draw(rect)
    }
  }

  private func shiftRetainedScene(delta: Int, rowCount: Int, scale: CGFloat,
    pixelWidth: Int, pixelHeight: Int, bitmap: CGContext) -> Bool
  {
    guard let texture = retainedTexture, let scratch = retainedScrollTexture,
      let queue = metalQueue, let command = queue.makeCommandBuffer(),
      let encoder = command.makeBlitCommandEncoder(), let data = bitmap.data else { return false }
    let rowHeight = max(1, Int((lineHeight * scale).rounded()))
    let gridTop = max(0, Int((originY * scale).rounded()))
    let gridBottom = min(pixelHeight, gridTop + rowHeight * rowCount)
    let amount = abs(delta) * rowHeight
    let retainedHeight = gridBottom - gridTop - amount
    guard retainedHeight > 0 else { encoder.endEncoding(); return false }
    let sourceY = delta > 0 ? gridTop : gridTop + amount
    let destinationY = delta > 0 ? gridTop + amount : gridTop
    let size = MTLSize(width: pixelWidth, height: retainedHeight, depth: 1)
    encoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
      sourceOrigin: MTLOrigin(x: 0, y: sourceY, z: 0), sourceSize: size,
      to: scratch, destinationSlice: 0, destinationLevel: 0,
      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    encoder.copy(from: scratch, sourceSlice: 0, sourceLevel: 0,
      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: size,
      to: texture, destinationSlice: 0, destinationLevel: 0,
      destinationOrigin: MTLOrigin(x: 0, y: destinationY, z: 0))
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else { return false }

    let byteCount = retainedHeight * bitmap.bytesPerRow
    // Swift's raw copyMemory has memmove semantics, including overlapping rows.
    data.advanced(by: destinationY * bitmap.bytesPerRow).copyMemory(
      from: data.advanced(by: sourceY * bitmap.bytesPerRow), byteCount: byteCount)
    return true
  }

  private func disableMetal() -> Bool {
    metalLayer?.isHidden = true
    return false
  }

  private func rasterize(snapshot: TerminalRenderSnapshot, rowCount: Int, rows: [Int]?,
    refreshPadding: Bool, in bitmap: CGContext)
  {
    let context = NSGraphicsContext(cgContext: bitmap, flipped: true)
    let selectionPath = roundedSelectionPath(snapshot.cellsByRow)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    func drawRow(_ row: Int) {
      bitmap.saveGState()
      var rowRect = NSRect(x: 0, y: originY + CGFloat(row) * lineHeight,
        width: bounds.width, height: lineHeight)
      if row == 0 { rowRect.origin.y = 0; rowRect.size.height += originY }
      NSBezierPath(rect: rowRect).addClip()
      color(snapshot.frame.background, alpha: preferences.opacity).setFill()
      rowRect.fill()
      guard snapshot.cellsByRow.indices.contains(row) else { bitmap.restoreGState(); return }
      let cells = snapshot.cellsByRow[row]
      drawEdgeColors(cells)
      drawBackgrounds(cells, selectionPath: selectionPath)
      drawRetainedPseudographics(cells)
      bitmap.restoreGState()
    }
    if let rows {
      for row in rows { drawRow(row) }
    } else {
      for row in 0..<rowCount { drawRow(row) }
    }
    if rowCount > gridRows && refreshPadding {
      bitmap.saveGState()
      let bottom = originY + CGFloat(gridRows + 1) * lineHeight
      let padding = NSRect(x: 0, y: bottom, width: bounds.width,
        height: max(0, bounds.height + lineHeight - bottom))
      NSBezierPath(rect: padding).addClip()
      color(snapshot.frame.background, alpha: preferences.opacity).setFill()
      padding.fill()
      bitmap.translateBy(x: 0, y: lineHeight)
      if snapshot.cellsByRow.indices.contains(gridRows - 1) {
        drawEdgeColors(snapshot.cellsByRow[gridRows - 1])
      }
      bitmap.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
  }

  private func drawEdgeColors<C: Collection>(_ cells: C) where C.Element == TerminalRenderCell {
    guard preferences.paddingColor != "Background" else { return }
    let always = preferences.paddingColor == "Always Extend"
    let gridRight = originX + CGFloat(gridColumns) * cellWidth
    let gridBottom = originY + CGFloat(gridRows) * lineHeight
    for cell in cells where cell.y < gridRows && (always || !cell.backgroundIsDefault) {
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
    let clip = ImageRect(x: Double(originX), y: Double(unscrolledOriginY),
      width: Double(CGFloat(gridColumns) * cellWidth),
      height: Double(CGFloat(gridRows) * lineHeight))
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(rect: NSRect(x: originX, y: unscrolledOriginY,
      width: CGFloat(gridColumns) * cellWidth, height: CGFloat(gridRows) * lineHeight)).addClip()
    for placement in images {
      let destination = NSRect(
        x: originX + CGFloat(placement.viewportColumn) * cellWidth + placement.xOffset,
        y: originY + CGFloat(placement.viewportRow) * lineHeight + placement.yOffset,
        width: placement.pixelWidth, height: placement.pixelHeight)
      guard ImageGeometry.clippedQuad(
        destination: ImageRect(x: Double(destination.minX), y: Double(destination.minY),
          width: Double(destination.width), height: Double(destination.height)),
        source: ImageRect(x: Double(placement.sourcePixels.minX),
          y: Double(placement.sourcePixels.minY), width: Double(placement.sourcePixels.width),
          height: Double(placement.sourcePixels.height)), clip: clip) != nil else { continue }
      // AppKit retains its flipped source coordinates and original filtering crop.
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

  private func roundedSelectionPath(_ rows: [PackedRenderRow]) -> CGPath? {
    selectionPathBuffer.reset()
    for (row, cells) in rows.enumerated() {
      var start: Int?
      var end = 0
      for cell in cells where cell.selected {
        start = min(start ?? cell.x, cell.x)
        end = max(end, cell.x + (cell.occupancy == 1 ? 2 : 1))
      }
      if let start, start < end {
        selectionPathBuffer.append(row: row, startColumn: start, endColumn: end)
      }
    }
    return selectionPathBuffer.withCommands(
      rowCount: rows.count, originX: Double(originX), originY: Double(originY),
      cellWidth: Double(cellWidth), lineHeight: Double(lineHeight)
    ) { commands in
      guard !commands.isEmpty else { return nil }
      let path = CGMutablePath()
      for command in commands {
        let end = CGPoint(x: command.x, y: command.y)
        switch command.tag {
        case 0:
          path.move(to: end)
        case 1:
          path.addLine(to: end)
        case 2:
          path.addQuadCurve(
            to: end, control: CGPoint(x: command.cx, y: command.cy))
        default:
          path.closeSubpath()
        }
      }
      return path
    }
  }

  private func drawBackgrounds<C: Collection>(_ cells: C, selectionPath: CGPath?)
    where C.Element == TerminalRenderCell
  {
    var pending: zigonaut_background_span?
    func flushBackground() {
      guard let span = pending else { return }
      color(span.colour, alpha: preferences.opacity).setFill()
      NSRect(x: span.left, y: span.top,
        width: span.right - span.left, height: span.bottom - span.top).fill()
      pending = nil
    }
    for cell in cells {
      if cell.backgroundIsDefault {
        flushBackground()
        continue
      }
      let rect = cellRect(cell)
      var next = zigonaut_background_span(left: rect.minX, top: rect.minY,
        right: rect.maxX, bottom: rect.maxY, colour: cell.background)
      if var span = pending, zigonaut_background_span_extend(&span, &next) != 0 {
        pending = span
      } else {
        flushBackground()
        pending = next
      }
    }
    flushBackground()

    if let selectionPath, let context = NSGraphicsContext.current?.cgContext {
      let radius = CGFloat(SelectionShape.cornerRadius(
        cellWidth: Double(cellWidth), lineHeight: Double(lineHeight)))
      context.saveGState()
      context.addPath(selectionPath)
      context.clip()
      // Concave curves extend just beyond the selected cell union. Bleed the
      // nearest cell colours into those pixels, then restore exact cell fills.
      for cell in cells where cell.selected && cell.searchHighlight == 0 {
        selectionBackground(cell).setFill()
        cellRect(cell).insetBy(dx: -radius, dy: -radius).fill()
      }
      for cell in cells where cell.selected && cell.searchHighlight == 0 {
        selectionBackground(cell).setFill()
        cellRect(cell).fill()
      }
      context.restoreGState()
    }

    let radius = CGFloat(SelectionShape.cornerRadius(
      cellWidth: Double(cellWidth), lineHeight: Double(lineHeight)))
    var pendingSearch = zigonaut_search_span()
    var span = zigonaut_search_span()
    func drawSearch(_ span: zigonaut_search_span) {
      let rect = NSRect(x: originX + CGFloat(span.start) * cellWidth,
        y: originY + CGFloat(span.row) * lineHeight,
        width: CGFloat(span.end - span.start) * cellWidth, height: lineHeight)
      (span.highlight == 2 ? NSColor.systemOrange : .systemYellow).setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    for cell in cells {
      if zigonaut_search_span_push(&pendingSearch, UInt32(cell.y), UInt32(cell.x),
        cell.occupancy == 1 ? 2 : 1, UInt32(cell.searchHighlight), &span) {
        drawSearch(span)
      }
    }
    if zigonaut_search_span_push(&pendingSearch, 0, 0, 0, 0, &span) { drawSearch(span) }
  }

  private func drawText<C: Collection>(_ cells: C) where C.Element == TerminalRenderCell {
    prepareText(cells, drawBuiltins: true) { placement in
      drawText(placement.text, x: placement.x, y: placement.y, columns: placement.columns,
        style: placement.style, batched: placement.batched)
    }
  }

  private func drawRetainedPseudographics<C: Collection>(_ cells: C)
    where C.Element == TerminalRenderCell
  {
    for cell in cells {
      let columns = cell.occupancy == 1 ? 2 : 1
      guard let scalar = proceduralScalar(cell.textBytes),
        let mask = pseudographicsMask(codepoint: scalar, columns: columns) else { continue }
      drawPseudographics(mask, cell: cell)
    }
  }

  private func proceduralScalar(_ bytes: ArraySlice<UInt8>) -> UInt32? {
    guard bytes.count == 3 else { return nil }
    let scalar = bytes.withUnsafeBufferPointer { zigonaut_render_procedural_scalar($0.baseAddress, $0.count) }
    return scalar == 0 ? nil : scalar
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
        // CGImage masks use inverse alpha by default. Reverse their decode range
        // so the shared A8 contract remains 0 = transparent, 255 = foreground.
        bytesPerRow: width, provider: provider, decode: [1, 0], shouldInterpolate: false)
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
      rgb: cell.selected
        ? (copyFlash ? cell.background : rgb(NSColor.selectedTextColor))
        : cell.foreground,
      bold: cell.bold,
      italic: cell.italic,
      faint: cell.faint)
  }

  private func selectionBackground(_ cell: TerminalRenderCell) -> NSColor {
    copyFlash
      ? color(cell.foreground, alpha: preferences.opacity)
      : NSColor.selectedTextBackgroundColor
  }

  private func rgb(_ color: NSColor) -> UInt32 {
    guard let converted = color.usingColorSpace(.deviceRGB) else { return 0xffffff }
    let red = UInt32((converted.redComponent * 255).rounded())
    let green = UInt32((converted.greenComponent * 255).rounded())
    let blue = UInt32((converted.blueComponent * 255).rounded())
    return red << 16 | green << 8 | blue
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
      y: originY + CGFloat(y) * lineHeight + textOffsetY + font.ascender - styledFont.ascender)
    let target = NSRect(x: origin.x, y: originY + CGFloat(y) * lineHeight,
      width: CGFloat(columns) * cellWidth, height: lineHeight)
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(rect: target).addClip()
    NSAttributedString(string: text, attributes: attributes).draw(at: origin)
    NSGraphicsContext.current?.restoreGraphicsState()
  }

  private func drawMarkedText(_ frame: TerminalRenderFrame) {
    guard markedText.length > 0 else { return }
    let point = NSPoint(
      x: originX + CGFloat(frame.cursorX) * cellWidth,
      y: originY + CGFloat(frame.cursorY) * lineHeight + textOffsetY)
    markedText.addAttributes(
      [
        .font: font, .foregroundColor: NSColor.textColor,
        .backgroundColor: NSColor.selectedTextBackgroundColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ],
      range: NSRange(location: 0, length: markedText.length))
    markedText.draw(at: point)
  }

  private func drawDecorations(_ cell: TerminalRenderCell, rect: NSRect,
    forceUnderline: Bool = false)
  {
    let underlineStyle = forceUnderline ? max(cell.underlineStyle, 1) : cell.underlineStyle
    guard underlineStyle != 0 || cell.strikethrough || cell.overline else { return }
    color(cell.underlineColor).setStroke()
    switch underlineStyle {
    case 1:
      strokeLine(y: rect.maxY - 1.5, rect: rect, width: 1)
    case 2:
      strokeLine(y: rect.maxY - 1, rect: rect, width: 1)
      strokeLine(y: rect.maxY - 3, rect: rect, width: 1)
    case 3:
      strokeWavyLine(y: rect.maxY - 2.5, rect: rect)
    case 4:
      strokePattern(y: rect.maxY - 1.5, rect: rect, pattern: [1, 2], rounded: true)
    case 5:
      strokePattern(y: rect.maxY - 1.5, rect: rect, pattern: [4, 2], rounded: false)
    default:
      if underlineStyle != 0 { strokeLine(y: rect.maxY - 1.5, rect: rect, width: 1) }
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
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let path: NSBezierPath
    if let cached = wavyPaths[rect.width] {
      path = cached
    } else {
      let count = zigonaut_curly_underline_f64(Double(rect.width), nil, 0)
      guard count > 0 else { return }
      var commands = [zigonaut_decoration_command_f64](
        repeating: zigonaut_decoration_command_f64(), count: count)
      _ = commands.withUnsafeMutableBufferPointer {
        zigonaut_curly_underline_f64(Double(rect.width), $0.baseAddress, $0.count)
      }
      path = NSBezierPath()
      for command in commands {
        if command.tag == 0 {
          path.move(to: NSPoint(x: command.x, y: command.y))
        } else {
          path.curve(to: NSPoint(x: command.x, y: command.y),
            controlPoint1: NSPoint(x: command.c1x, y: command.c1y),
            controlPoint2: NSPoint(x: command.c2x, y: command.c2y))
        }
      }
      path.lineWidth = 1
      // The fixed style depends only on width, not font, position or colour.
      // Bound retained geometry when zooming through many cell sizes.
      if wavyPaths.count >= 16 { wavyPaths.removeAll(keepingCapacity: true) }
      wavyPaths[rect.width] = path
    }
    context.saveGState()
    context.translateBy(x: rect.minX, y: y)
    path.stroke()
    context.restoreGState()
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
    model.applyCommandNotificationSettings()
    view.updateTerminalSettings()
    view.resizeTerminal()
    view.needsDisplay = true
    view.updateAccessibilityValue()
    view.updateMouseCursor()
    view.setAccessibilityFocused(wantsKeyboardFocus)
    if shouldClaimKeyboardFocus {
      view.window?.makeFirstResponder(view)
    }
  }
}
