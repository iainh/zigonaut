import Foundation
import CoreGraphics
import ZigonautCore

/// Owns one immutable Zig allocation. Copies of the Swift value share this
/// owner; neither AX queries nor deinit need the terminal to remain alive.
private final class LayoutStorage: @unchecked Sendable {
  let pointer: OpaquePointer
  let view: zigonaut_accessibility_view

  init(_ pointer: OpaquePointer) {
    self.pointer = pointer
    var view = zigonaut_accessibility_view()
    zigonaut_accessibility_get_view(pointer, &view)
    self.view = view
  }

  deinit { zigonaut_accessibility_release(pointer) }
}

/// Native string/NSRange adapter over the core's bounded UTF-16 layout.
public struct TerminalAccessibilityLayout: Sendable {
  public let string: String
  public let selectedRanges: [NSRange]
  public let cursorRange: NSRange
  private let storage: LayoutStorage?
  private let length: Int

  /// Takes ownership, including when the terminal is subsequently destroyed.
  public init(owning pointer: OpaquePointer? = nil) {
    guard let pointer else {
      storage = nil
      string = ""
      selectedRanges = []
      cursorRange = NSRange(location: 0, length: 0)
      length = 0
      return
    }
    let owner = LayoutStorage(pointer)
    storage = owner
    let view = owner.view
    length = Int(view.text_count)
    string = String(decoding: UnsafeBufferPointer(start: view.text, count: length), as: UTF16.self)
    selectedRanges = UnsafeBufferPointer(start: view.selections, count: Int(view.selection_count)).map {
      NSRange(location: Int($0.location), length: Int($0.length))
    }
    cursorRange = NSRange(location: Int(view.cursor.location), length: Int(view.cursor.length))
  }

  public var fullRange: NSRange { NSRange(location: 0, length: length) }
  public var selectedRange: NSRange { selectedRanges.first ?? cursorRange }

  public func validRange(_ range: NSRange) -> NSRange? {
    guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
      range.location <= length, range.length <= length - range.location else { return nil }
    return range
  }

  public func string(for range: NSRange) -> String? {
    guard let range = validRange(range) else { return nil }
    return (string as NSString).substring(with: range)
  }

  public func range(forLine line: Int) -> NSRange {
    guard let storage, line >= 0, line < storage.view.line_count else {
      return NSRange(location: NSNotFound, length: 0)
    }
    return withExtendedLifetime(storage) {
      let range = storage.view.lines[line]
      return NSRange(location: Int(range.location), length: Int(range.length))
    }
  }

  public func line(for index: Int) -> Int {
    guard index >= 0, index <= length else { return NSNotFound }
    guard let storage else { return 0 }
    return withExtendedLifetime(storage) {
      let line = zigonaut_accessibility_line(storage.pointer, UInt32(index))
      return line < 0 ? NSNotFound : Int(line)
    }
  }

  public func gridRect(for range: NSRange) -> CGRect {
    guard let range = validRange(range), let storage else { return .zero }
    return withExtendedLifetime(storage) {
      let rect = zigonaut_accessibility_grid_rect(storage.pointer,
        zigonaut_accessibility_range(location: UInt32(range.location), length: UInt32(range.length)))
      return CGRect(x: Int(rect.x), y: Int(rect.y), width: Int(rect.width), height: Int(rect.height))
    }
  }
}
