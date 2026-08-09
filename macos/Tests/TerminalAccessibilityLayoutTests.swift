import Foundation
import Testing
import ZigonautAccessibility

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
