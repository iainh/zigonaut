import Foundation
import CoreGraphics

public struct AccessibilityCell: Sendable {
  public let column: Int
  public let row: Int
  public let text: String
  public let columns: Int
  public let continuation: Bool
  public let selected: Bool

  public init(column: Int, row: Int, text: String, columns: Int = 1,
    continuation: Bool = false, selected: Bool = false)
  {
    self.column = column
    self.row = row
    self.text = text
    self.columns = columns
    self.continuation = continuation
    self.selected = selected
  }
}

/// An immutable, UTF-16-indexed view of the visible terminal grid.
public struct TerminalAccessibilityLayout: Sendable {
  public let string: String
  public let lineRanges: [NSRange]
  public let selectedRanges: [NSRange]
  public let cursorRange: NSRange
  private let spans: [Span]

  private struct Span: Sendable {
    let range: NSRange
    let column: Int
    let row: Int
    let columns: Int
  }

  public init(columns: Int, rows: Int, cells: [AccessibilityCell], cursorColumn: Int,
    cursorRow: Int, maximumUTF16Length: Int = 100_000)
  {
    let width = max(columns, 0)
    let height = max(rows, 0)
    let limit = max(maximumUTF16Length, 0)
    let leading = Dictionary(grouping: cells.filter { !$0.continuation }, by: { $0.row })
    var value = ""
    var lines: [NSRange] = []
    var builtSpans: [Span] = []
    var selections: [NSRange] = []
    var cursor = NSRange(location: 0, length: 0)
    var cursorSet = false

    func append(_ source: String, remaining: Int) -> String {
      guard remaining > 0 else { return "" }
      let ns = source as NSString
      var length = min(ns.length, remaining)
      if length > 0, length < ns.length {
        let last = ns.character(at: length - 1)
        if UTF16.isLeadSurrogate(last) { length -= 1 }
      }
      return ns.substring(with: NSRange(location: 0, length: length))
    }

    outer: for row in 0..<height {
      if row > 0 {
        guard (value as NSString).length < limit else { break }
        value += "\n"
      }
      let lineStart = (value as NSString).length
      let rowCells = (leading[row] ?? []).sorted { $0.column < $1.column }
      var byColumn: [Int: AccessibilityCell] = [:]
      for cell in rowCells where cell.column >= 0 && cell.column < width { byColumn[cell.column] = cell }
      var column = 0
      while column < width {
        let location = (value as NSString).length
        let cell = byColumn[column]
        let cellWidth = min(max(cell?.columns ?? 1, 1), width - column)
        if row == cursorRow && cursorColumn >= column && cursorColumn < column + cellWidth {
          cursor = NSRange(location: location, length: 0)
          cursorSet = true
        }
        let content = (cell?.text.isEmpty == false) ? cell!.text : " "
        let fragment = append(content, remaining: limit - location)
        guard !fragment.isEmpty else { break outer }
        value += fragment
        let range = NSRange(location: location, length: (fragment as NSString).length)
        builtSpans.append(Span(range: range, column: column, row: row, columns: cellWidth))
        if cell?.selected == true { selections.append(range) }
        column += cellWidth
      }
      lines.append(NSRange(location: lineStart, length: (value as NSString).length - lineStart))
    }
    if !cursorSet { cursor = NSRange(location: (value as NSString).length, length: 0) }
    string = value
    lineRanges = lines
    selectedRanges = Self.merge(selections)
    cursorRange = cursor
    spans = builtSpans
  }

  public var fullRange: NSRange { NSRange(location: 0, length: (string as NSString).length) }
  public var selectedRange: NSRange { selectedRanges.first ?? cursorRange }

  public func validRange(_ range: NSRange) -> NSRange? {
    guard range.location != NSNotFound, range.location <= fullRange.length,
      range.length <= fullRange.length - range.location else { return nil }
    return range
  }

  public func string(for range: NSRange) -> String? {
    guard let range = validRange(range) else { return nil }
    return (string as NSString).substring(with: range)
  }

  public func range(forLine line: Int) -> NSRange {
    lineRanges.indices.contains(line) ? lineRanges[line] : NSRange(location: NSNotFound, length: 0)
  }

  public func line(for index: Int) -> Int {
    guard index >= 0, index <= fullRange.length else { return NSNotFound }
    return lineRanges.firstIndex { index <= NSMaxRange($0) } ?? max(lineRanges.count - 1, 0)
  }

  public func gridRect(for range: NSRange) -> CGRect {
    guard let range = validRange(range) else { return .zero }
    if range.length == 0, let span = spans.first(where: { range.location <= NSMaxRange($0.range) }) {
      return CGRect(x: span.column, y: span.row, width: max(span.columns, 1), height: 1)
    }
    let matches = spans.filter { NSIntersectionRange($0.range, range).length > 0 }
    guard let first = matches.first else { return .zero }
    return matches.dropFirst().reduce(
      CGRect(x: first.column, y: first.row, width: first.columns, height: 1)
    ) { result, span in result.union(CGRect(x: span.column, y: span.row, width: span.columns, height: 1)) }
  }

  private static func merge(_ ranges: [NSRange]) -> [NSRange] {
    var result: [NSRange] = []
    for range in ranges {
      if let last = result.last, range.location <= NSMaxRange(last) {
        result[result.count - 1] = NSUnionRange(last, range)
      } else { result.append(range) }
    }
    return result
  }
}
