import CoreGraphics
import Testing
import ZigonautCore

@testable import ZigonautRenderSupport

private func curves(_ path: [SelectionPathCommand]) -> [SelectionPathCommand] {
  path.filter {
    if case .quadratic = $0 { return true }
    return false
  }
}

@Test func selectionShapeUsesSubtleScaleAwareRadius() {
  #expect(SelectionShape.cornerRadius(cellWidth: 8, lineHeight: 20) == 2)
  #expect(SelectionShape.cornerRadius(cellWidth: 20, lineHeight: 10) == 1.5)
}

@Test func singleAndRectangularSelectionsOnlyRoundOutsideCorners() {
  let single = SelectionShape.paths(
    lines: [SelectionLine(row: 1, startColumn: 2, endColumn: 5)], rowCount: 4,
    originX: 0, originY: 0, cellWidth: 8, lineHeight: 20)
  #expect(single.count == 1)
  #expect(curves(single[0]).count == 4)

  let rectangle = SelectionShape.paths(
    lines: [
      SelectionLine(row: 1, startColumn: 2, endColumn: 5),
      SelectionLine(row: 2, startColumn: 2, endColumn: 5),
    ], rowCount: 4, originX: 0, originY: 0, cellWidth: 8, lineHeight: 20)
  #expect(rectangle.count == 1)
  #expect(curves(rectangle[0]).count == 4)
}

@Test func steppedSelectionRoundsBothOutsideAndInsideCorners() {
  let paths = SelectionShape.paths(
    lines: [
      SelectionLine(row: 1, startColumn: 3, endColumn: 8),
      SelectionLine(row: 2, startColumn: 0, endColumn: 5),
    ], rowCount: 4, originX: 0, originY: 0, cellWidth: 8, lineHeight: 20)
  #expect(paths.count == 1)
  #expect(curves(paths[0]).count == 8)
  #expect(
    paths[0].contains(
      .quadratic(
        control: SelectionPoint(x: 64, y: 40), end: SelectionPoint(x: 62, y: 40))))
  #expect(
    paths[0].contains(
      .quadratic(
        control: SelectionPoint(x: 0, y: 40), end: SelectionPoint(x: 2, y: 40))))
}

@Test func disconnectedRowsBecomeSeparateRoundedComponents() {
  let paths = SelectionShape.paths(
    lines: [
      SelectionLine(row: 1, startColumn: 7, endColumn: 9),
      SelectionLine(row: 2, startColumn: 0, endColumn: 3),
    ], rowCount: 4, originX: 0, originY: 0, cellWidth: 8, lineHeight: 20)
  #expect(paths.count == 2)
  #expect(paths.allSatisfy { curves($0).count == 4 })
}

@Test func viewportEdgesRemainSquareWhenSelectionMayContinueOffscreen() {
  let paths = SelectionShape.paths(
    lines: [
      SelectionLine(row: 0, startColumn: 1, endColumn: 4),
      SelectionLine(row: 1, startColumn: 1, endColumn: 4),
    ], rowCount: 2, originX: 0, originY: 0, cellWidth: 8, lineHeight: 20)
  #expect(paths.count == 1)
  #expect(curves(paths[0]).isEmpty)
}

@Test func invalidRowsAreSkippedWithoutBreakingComponentsAndTouchingSpansStaySeparate() {
  let paths = SelectionShape.paths(
    lines: [
      SelectionLine(row: -1, startColumn: 0, endColumn: 9),
      SelectionLine(row: 1, startColumn: 3, endColumn: 8),
      SelectionLine(row: 2, startColumn: 4, endColumn: 4),
      SelectionLine(row: 2, startColumn: 0, endColumn: 5),
      SelectionLine(row: 3, startColumn: 5, endColumn: 7),
      SelectionLine(row: 8, startColumn: 0, endColumn: 9),
    ], rowCount: 5, originX: 0.25, originY: -3.75, cellWidth: 8.5, lineHeight: 19.25)
  #expect(paths.count == 2)
  #expect(paths[0].first == .move(SelectionPoint(x: 66.125, y: 15.5)))
  #expect(curves(paths[0]).count == 8)
  #expect(paths[0].contains(.quadratic(
    control: SelectionPoint(x: 68.25, y: 34.75),
    end: SelectionPoint(x: 66.125, y: 34.75))))
}

@Test func selectionBufferDoesNotReplayCommandsAfterSelectionShrinksOrClears() {
  let buffer = SelectionPathBuffer()
  for row in 1..<20 { buffer.append(row: row, startColumn: row % 3, endColumn: 30) }
  let large = buffer.withCommands(
    rowCount: 30, originX: 0, originY: 0, cellWidth: 8, lineHeight: 20) { $0.count }
  #expect(large > 9)
  buffer.reset()
  buffer.append(row: 0, startColumn: 1, endColumn: 4)
  buffer.withCommands(rowCount: 1, originX: 0, originY: -0.5, cellWidth: 8, lineHeight: 20) {
    #expect($0.count == 9)
    #expect($0.filter { $0.tag == 0 }.count == 1)
    #expect($0.allSatisfy { $0.tag != 2 })
    #expect($0[0].x == 32 && $0[0].y == -0.5)
  }
  buffer.reset()
  buffer.withCommands(rowCount: 1, originX: 0, originY: 0, cellWidth: 8, lineHeight: 20) {
    #expect($0.isEmpty)
  }
}

// Reuse the Windows geometry containment cases on macOS as well. This exercises
// the Float ABI through a real native path; Windows retains its D2D tests too.
@Test func windowsSelectionGeometryKeepsRoundedCornersConcaveBleedAndClipping() {
  func path(_ intervals: [zigonaut_selection_interval], top: Float, clipped: Bool = false) -> CGPath {
    var commands = [zigonaut_selection_command_f32](repeating: .init(), count: 27)
    let count = zigonaut_selection_row_path(
      intervals, 0, top, 10, 20, clipped ? 1 : 0, clipped ? 1 : 0, &commands, commands.count)
    let path = CGMutablePath()
    for command in commands.prefix(count) {
      let end = CGPoint(x: Double(command.x), y: Double(command.y))
      switch command.tag {
      case 0: path.move(to: end)
      case 1: path.addLine(to: end)
      case 2: path.addQuadCurve(to: end, control: CGPoint(x: Double(command.cx), y: Double(command.cy)))
      default: path.closeSubpath()
      }
    }
    return path
  }
  let empty = zigonaut_selection_interval()
  let rounded = path([empty, .init(start: 1, end: 4, active: 1), empty], top: 0)
  #expect(rounded.contains(CGPoint(x: 20, y: 10)))
  #expect(!rounded.contains(CGPoint(x: 10.1, y: 0.1)))
  #expect(!rounded.contains(CGPoint(x: 39.9, y: 19.9)))
  let stepped = path([.init(start: 0, end: 4, active: 1), .init(start: 2, end: 4, active: 1), empty], top: 20)
  #expect(stepped.contains(CGPoint(x: 10, y: 10)))
  #expect(stepped.contains(CGPoint(x: 30, y: 30)))
  var bleed = false
  for y in stride(from: 20.05, to: 23, by: 0.05) {
    for x in stride(from: 15.0, to: 20, by: 0.05) where stepped.contains(CGPoint(x: x, y: y)) {
      bleed = true
      #expect(x >= 17.5)
    }
  }
  #expect(bleed)
  let square = path([empty, .init(start: 0, end: 2, active: 1), empty], top: 0, clipped: true)
  #expect(square.contains(CGPoint(x: 0.1, y: 0.1)))
  #expect(square.contains(CGPoint(x: 19.9, y: 19.9)))
}
