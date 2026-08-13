public enum RetainedScroll {
  /// Returns the retained-scene row delta. A positive delta moves old rows
  /// down, matching the terminal scrollbar whose offset grows toward the end.
  public static func rowDelta(
    previousOffset: UInt64, currentOffset: UInt64, rowCount: Int
  ) -> Int? {
    guard rowCount > 1, previousOffset != currentOffset else { return nil }
    let magnitude: UInt64
    let positive: Bool
    if previousOffset > currentOffset {
      magnitude = previousOffset - currentOffset
      positive = true
    } else {
      magnitude = currentOffset - previousOffset
      positive = false
    }
    guard magnitude < UInt64(rowCount), magnitude <= UInt64(Int.max) else { return nil }
    let rows = Int(magnitude)
    return positive ? rows : -rows
  }

  public static func sourceRow(for destinationRow: Int, delta: Int, rowCount: Int) -> Int? {
    let source = destinationRow - delta
    return source >= 0 && source < rowCount ? source : nil
  }
}
