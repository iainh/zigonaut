import ZigonautCore

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

/// One per terminal surface. Retains caller-owned ABI storage across redraws;
/// no per-cell calls, component arrays, or command-enum conversion on the hot path.
public final class SelectionPathBuffer {
  private var lines: [zigonaut_selection_line] = []
  private var commands: [zigonaut_selection_command] = []

  public init() {}

  public func reset() { lines.removeAll(keepingCapacity: true) }

  public func append(row: Int, startColumn: Int, endColumn: Int) {
    lines.append(zigonaut_selection_line(
      row: Int64(row), start_column: Int64(startColumn), end_column: Int64(endColumn)))
  }

  public func withCommands<Result>(
    rowCount: Int, originX: Double, originY: Double, cellWidth: Double, lineHeight: Double,
    _ body: (UnsafeBufferPointer<zigonaut_selection_command>) -> Result
  ) -> Result {
    let capacity = lines.count * 9
    if commands.count < capacity {
      commands.append(contentsOf: repeatElement(
        zigonaut_selection_command(), count: capacity - commands.count))
    }
    return lines.withUnsafeBufferPointer { input in
      commands.withUnsafeMutableBufferPointer { output in
        let count = zigonaut_selection_path(
          input.baseAddress, input.count, Int64(rowCount), originX, originY,
          cellWidth, lineHeight, output.baseAddress, output.count)
        return body(UnsafeBufferPointer(start: output.baseAddress, count: count))
      }
    }
  }
}

public enum SelectionShape {
  public static func cornerRadius(cellWidth: Double, lineHeight: Double) -> Double {
    max(0, min(lineHeight * 0.15, cellWidth * 0.25, lineHeight * 0.5))
  }

  /// Value-based adapter for tests and non-rendering callers. The renderer uses
  /// SelectionPathBuffer directly, without allocating these nested arrays.
  public static func paths(
    lines: [SelectionLine], rowCount: Int, originX: Double, originY: Double,
    cellWidth: Double, lineHeight: Double
  ) -> [[SelectionPathCommand]] {
    let buffer = SelectionPathBuffer()
    for line in lines {
      buffer.append(row: line.row, startColumn: line.startColumn, endColumn: line.endColumn)
    }
    return buffer.withCommands(
      rowCount: rowCount, originX: originX, originY: originY,
      cellWidth: cellWidth, lineHeight: lineHeight
    ) { commands in
      var result: [[SelectionPathCommand]] = []
      var component: [SelectionPathCommand] = []
      for command in commands {
        let end = SelectionPoint(x: command.x, y: command.y)
        switch command.tag {
        case 0: component.append(.move(end))
        case 1: component.append(.line(end))
        case 2:
          component.append(.quadratic(
            control: SelectionPoint(x: command.cx, y: command.cy), end: end))
        default:
          component.append(.close)
          result.append(component)
          component = []
        }
      }
      return result
    }
  }
}
