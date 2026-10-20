import Foundation
import Testing
import ZigonautAccessibility
import ZigonautCore

// Keep the original layout fixtures at the Swift/native boundary, but send one
// POD batch instead of making a language crossing for every cell.
private struct AccessibilityCell {
  let column: Int
  let row: Int
  let text: String
  var columns: Int = 1
  var continuation = false
  var selected = false
}

private extension TerminalAccessibilityLayout {
  init(columns: Int, rows: Int, cells: [AccessibilityCell], cursorColumn: Int,
    cursorRow: Int, maximumUTF16Length: Int = 100_000)
  {
    var bytes: [UInt8] = []
    let records = cells.map { cell in
      var record = zigonaut_render_cell_v1()
      record.x = UInt16(cell.column)
      record.y = UInt16(cell.row)
      record.text_offset = UInt32(bytes.count)
      bytes.append(contentsOf: cell.text.utf8)
      record.text_length = UInt32(bytes.count) - record.text_offset
      record.occupancy = cell.continuation ? 2 : cell.columns == 2 ? 1 : 0
      record.selected = cell.selected ? 1 : 0
      return record
    }
    let pointer = records.withUnsafeBufferPointer { records in
      bytes.withUnsafeBufferPointer { bytes in
        zigonaut_accessibility_build(UInt16(columns), UInt16(rows), records.baseAddress,
          UInt32(records.count), bytes.baseAddress, UInt32(bytes.count), UInt16(cursorColumn),
          UInt16(cursorRow), UInt32(maximumUTF16Length))
      }
    }
    #expect(pointer != nil)
    self.init(owning: pointer)
  }
}

@Test func accessibilityUsesUTF16RangesAndPreservesRowBreaks() {
  let layout = TerminalAccessibilityLayout(columns: 3, rows: 2, cells: [
    AccessibilityCell(column: 0, row: 0, text: "😀"),
    AccessibilityCell(column: 0, row: 1, text: "e\u{301}"),
  ], cursorColumn: 1, cursorRow: 0)

  #expect(layout.string == "😀  \né  ")
  #expect(layout.fullRange.length == 9)
  #expect(layout.range(forLine: 0) == NSRange(location: 0, length: 4))
  #expect(layout.range(forLine: 1) == NSRange(location: 5, length: 4))
  #expect(layout.line(for: 5) == 1)
  #expect(layout.cursorRange == NSRange(location: 2, length: 0))
  #expect(layout.string(for: NSRange(location: 0, length: 2)) == "😀")
}

@Test func accessibilityMapsSelectionWideCellsAndGeometry() {
  let layout = TerminalAccessibilityLayout(columns: 4, rows: 2, cells: [
    AccessibilityCell(column: 0, row: 0, text: "界", columns: 2, selected: true),
    AccessibilityCell(column: 1, row: 0, text: "", continuation: true, selected: true),
    AccessibilityCell(column: 2, row: 0, text: "x", selected: true),
    AccessibilityCell(column: 1, row: 1, text: "y"),
  ], cursorColumn: 0, cursorRow: 0)

  #expect(layout.string == "界x \n y  ")
  #expect(layout.selectedRanges == [NSRange(location: 0, length: 2)])
  #expect(layout.gridRect(for: layout.selectedRange) == CGRect(x: 0, y: 0, width: 3, height: 1))
  #expect(layout.gridRect(for: NSRange(location: 5, length: 1)) == CGRect(x: 1, y: 1, width: 1, height: 1))
  #expect(layout.gridRect(for: layout.cursorRange) == CGRect(x: 0, y: 0, width: 2, height: 1))
}

@Test func accessibilityCapDoesNotSplitSurrogatePairs() {
  let layout = TerminalAccessibilityLayout(columns: 2, rows: 1, cells: [
    AccessibilityCell(column: 0, row: 0, text: "😀"),
  ], cursorColumn: 0, cursorRow: 0, maximumUTF16Length: 1)

  #expect(layout.string.isEmpty)
  #expect(layout.fullRange.length == 0)
}

@Test func accessibilityNativeSentinelsAndCaretAffinitySurviveValueCopies() {
  let layout: TerminalAccessibilityLayout = {
    let original = TerminalAccessibilityLayout(columns: 3, rows: 2, cells: [
      AccessibilityCell(column: 0, row: 0, text: "界", columns: 2, selected: true),
      AccessibilityCell(column: 2, row: 0, text: "x"),
      AccessibilityCell(column: 0, row: 1, text: "y", selected: true),
    ], cursorColumn: 1, cursorRow: 0)
    return original
  }()
  #expect(layout.string == "界x\ny  ")
  #expect(layout.cursorRange == NSRange(location: 0, length: 0))
  #expect(layout.selectedRanges == [NSRange(location: 0, length: 1), NSRange(location: 3, length: 1)])
  #expect(layout.line(for: 2) == 0) // newline belongs to the preceding row
  #expect(layout.line(for: 6) == 1) // end of buffer
  #expect(layout.line(for: -1) == NSNotFound)
  #expect(layout.line(for: 7) == NSNotFound)
  #expect(layout.range(forLine: -1) == NSRange(location: NSNotFound, length: 0))
  #expect(layout.range(forLine: 2) == NSRange(location: NSNotFound, length: 0))
  #expect(layout.validRange(NSRange(location: NSNotFound, length: 0)) == nil)
  #expect(layout.validRange(NSRange(location: 1, length: Int.max)) == nil)
  #expect(layout.validRange(NSRange(location: -1, length: 0)) == nil)
  #expect(layout.string(for: NSRange(location: 6, length: 0)) == "")
  #expect(layout.gridRect(for: NSRange(location: 1, length: 0)) == CGRect(x: 0, y: 0, width: 2, height: 1))
  #expect(layout.gridRect(for: NSRange(location: 0, length: 4)) == CGRect(x: 0, y: 0, width: 3, height: 2))
  #expect(layout.gridRect(for: NSRange(location: NSNotFound, length: 0)) == .zero)
}

@Test func accessibilityTruncatedRowsAndSurrogateBoundaries() {
  for (limit, expected, lines) in [(0, "", 0), (1, "a", 0), (2, "a", 0),
    (3, "a😀", 1), (4, "a😀\n", 1), (5, "a😀\nz", 1), (6, "a😀\nz ", 2)]
  {
    let layout = TerminalAccessibilityLayout(columns: 2, rows: 2, cells: [
      AccessibilityCell(column: 0, row: 0, text: "a"),
      AccessibilityCell(column: 1, row: 0, text: "😀"),
      AccessibilityCell(column: 0, row: 1, text: "z"),
    ], cursorColumn: 8, cursorRow: 8, maximumUTF16Length: limit)
    #expect(layout.string == expected)
    #expect(layout.cursorRange == NSRange(location: expected.utf16.count, length: 0))
    #expect(layout.range(forLine: lines).location == NSNotFound)
    #expect(layout.string.utf16.count <= limit)
  }
}

@Test func accessibilityLargeGridsAreBoundedWithoutCapacityOverflow() {
  let large = TerminalAccessibilityLayout(columns: 200, rows: 60, cells: [],
    cursorColumn: 0, cursorRow: 0)
  #expect(large.fullRange.length == 12_059)
  #expect(large.range(forLine: 59) == NSRange(location: 11_859, length: 200))
  let bounded = TerminalAccessibilityLayout(columns: 65_535, rows: 65_535, cells: [],
    cursorColumn: 0, cursorRow: 0, maximumUTF16Length: Int(UInt32.max))
  #expect(bounded.fullRange.length == 100_000)
  #expect(bounded.range(forLine: 0) == NSRange(location: 0, length: 65_535))
  #expect(bounded.range(forLine: 1).location == NSNotFound)
}
