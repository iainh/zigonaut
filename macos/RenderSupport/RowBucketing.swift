import Foundation

public enum RowBucketing {
  /// Returns the viewport rows touched by a vertically positioned rectangle.
  /// Rows use half-open bounds, so an image ending exactly at a row boundary
  /// does not unnecessarily invalidate/draw the following row.
  public static func overlappingRows(
    viewportRow: Int, yOffset: Double, height: Double, lineHeight: Double, rowCount: Int
  ) -> Range<Int> {
    guard rowCount > 0, lineHeight > 0, height > 0 else { return 0..<0 }
    let minimumY = Double(viewportRow) * lineHeight + yOffset
    let maximumY = minimumY + height
    let first = max(0, Int(floor(minimumY / lineHeight)))
    let lastExclusive = min(rowCount, Int(ceil(maximumY / lineHeight)))
    guard first < lastExclusive else { return 0..<0 }
    return first..<lastExclusive
  }
}
