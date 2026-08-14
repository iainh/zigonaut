import Testing

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
