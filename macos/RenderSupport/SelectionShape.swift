public struct SelectionLine: Equatable, Sendable {
  public let row: Int
  public let startColumn: Int
  public let endColumn: Int

  public init(row: Int, startColumn: Int, endColumn: Int) {
    self.row = row
    self.startColumn = startColumn
    self.endColumn = endColumn
  }
}

public struct SelectionPoint: Equatable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public enum SelectionPathCommand: Equatable, Sendable {
  case move(SelectionPoint)
  case line(SelectionPoint)
  case quadratic(control: SelectionPoint, end: SelectionPoint)
  case close
}

public enum SelectionShape {
  public static func cornerRadius(cellWidth: Double, lineHeight: Double) -> Double {
    max(0, min(lineHeight * 0.15, cellWidth * 0.25, lineHeight * 0.5))
  }

  public static func paths(
    lines: [SelectionLine], rowCount: Int, originX: Double, originY: Double,
    cellWidth: Double, lineHeight: Double
  ) -> [[SelectionPathCommand]] {
    guard rowCount > 0, cellWidth > 0, lineHeight > 0 else { return [] }
    let valid = lines.filter {
      $0.row >= 0 && $0.row < rowCount && $0.startColumn < $0.endColumn
    }
    guard !valid.isEmpty else { return [] }

    var components: [[SelectionLine]] = []
    var component: [SelectionLine] = []
    for line in valid {
      if let previous = component.last,
        line.row != previous.row + 1
          || max(previous.startColumn, line.startColumn)
            >= min(previous.endColumn, line.endColumn)
      {
        components.append(component)
        component = []
      }
      component.append(line)
    }
    if !component.isEmpty { components.append(component) }

    let radius = cornerRadius(cellWidth: cellWidth, lineHeight: lineHeight)
    return components.map {
      commands(
        for: $0, rowCount: rowCount, originX: originX, originY: originY,
        cellWidth: cellWidth, lineHeight: lineHeight, radius: radius)
    }
  }

  private static func commands(
    for lines: [SelectionLine], rowCount: Int, originX: Double, originY: Double,
    cellWidth: Double, lineHeight: Double, radius: Double
  ) -> [SelectionPathCommand] {
    func left(_ line: SelectionLine) -> Double {
      originX + Double(line.startColumn) * cellWidth
    }
    func right(_ line: SelectionLine) -> Double {
      originX + Double(line.endColumn) * cellWidth
    }
    func top(_ line: SelectionLine) -> Double {
      originY + Double(line.row) * lineHeight
    }
    func point(_ x: Double, _ y: Double) -> SelectionPoint {
      SelectionPoint(x: x, y: y)
    }
    func horizontalRadius(_ first: Double, _ second: Double) -> Double {
      min(radius, abs(second - first) * 0.5)
    }

    let first = lines[0]
    let last = lines[lines.count - 1]
    let firstTop = top(first)
    let topRadius = first.row == 0 ? 0 : horizontalRadius(left(first), right(first))
    let bottomRadius = last.row + 1 == rowCount ? 0 : horizontalRadius(left(last), right(last))
    let topVerticalRadius = first.row == 0 ? 0 : radius
    let bottomVerticalRadius = last.row + 1 == rowCount ? 0 : radius

    var result: [SelectionPathCommand] = [
      .move(point(right(first) - topRadius, firstTop))
    ]
    if topRadius > 0 {
      result.append(
        .quadratic(
          control: point(right(first), firstTop),
          end: point(right(first), firstTop + topVerticalRadius)))
    } else {
      result.append(.line(point(right(first), firstTop)))
    }

    for index in lines.indices {
      let line = lines[index]
      let boundaryY = top(line) + lineHeight
      guard index + 1 < lines.count else {
        result.append(.line(point(right(line), boundaryY - bottomVerticalRadius)))
        if bottomRadius > 0 {
          result.append(
            .quadratic(
              control: point(right(line), boundaryY),
              end: point(right(line) - bottomRadius, boundaryY)))
        } else {
          result.append(.line(point(right(line), boundaryY)))
        }
        result.append(.line(point(left(line) + bottomRadius, boundaryY)))
        if bottomRadius > 0 {
          result.append(
            .quadratic(
              control: point(left(line), boundaryY),
              end: point(left(line), boundaryY - bottomVerticalRadius)))
        } else {
          result.append(.line(point(left(line), boundaryY)))
        }
        continue
      }

      let next = lines[index + 1]
      let currentRight = right(line)
      let nextRight = right(next)
      result.append(.line(point(currentRight, boundaryY - radius)))
      if currentRight == nextRight {
        result.append(.line(point(currentRight, boundaryY)))
      } else {
        let curve = horizontalRadius(currentRight, nextRight)
        let direction = nextRight < currentRight ? -1.0 : 1.0
        result.append(
          .quadratic(
            control: point(currentRight, boundaryY),
            end: point(currentRight + direction * curve, boundaryY)))
        result.append(.line(point(nextRight - direction * curve, boundaryY)))
        result.append(
          .quadratic(
            control: point(nextRight, boundaryY),
            end: point(nextRight, boundaryY + radius)))
      }
    }

    if lines.count > 1 {
      for index in stride(from: lines.count - 1, through: 1, by: -1) {
        let lower = lines[index]
        let upper = lines[index - 1]
        let boundaryY = top(lower)
        let lowerLeft = left(lower)
        let upperLeft = left(upper)
        result.append(.line(point(lowerLeft, boundaryY + radius)))
        if lowerLeft == upperLeft {
          result.append(.line(point(lowerLeft, boundaryY)))
        } else {
          let curve = horizontalRadius(lowerLeft, upperLeft)
          let direction = upperLeft > lowerLeft ? 1.0 : -1.0
          result.append(
            .quadratic(
              control: point(lowerLeft, boundaryY),
              end: point(lowerLeft + direction * curve, boundaryY)))
          result.append(.line(point(upperLeft - direction * curve, boundaryY)))
          result.append(
            .quadratic(
              control: point(upperLeft, boundaryY),
              end: point(upperLeft, boundaryY - radius)))
        }
      }
    }

    result.append(.line(point(left(first), firstTop + topVerticalRadius)))
    if topRadius > 0 {
      result.append(
        .quadratic(
          control: point(left(first), firstTop),
          end: point(left(first) + topRadius, firstTop)))
    } else {
      result.append(.line(point(left(first), firstTop)))
    }
    result.append(.close)
    return result
  }
}
