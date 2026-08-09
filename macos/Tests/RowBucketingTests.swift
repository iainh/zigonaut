import Testing
@testable import ZigonautRenderSupport

@Test func imageOverlapAccountsForOffsetsAndHeight() {
  #expect(RowBucketing.overlappingRows(
    viewportRow: 2, yOffset: -3, height: 25, lineHeight: 10, rowCount: 6) == 1..<5)
}

@Test func imageOverlapUsesHalfOpenRowBoundsAndCropsToViewport() {
  #expect(RowBucketing.overlappingRows(
    viewportRow: 1, yOffset: 0, height: 10, lineHeight: 10, rowCount: 4) == 1..<2)
  #expect(RowBucketing.overlappingRows(
    viewportRow: -2, yOffset: 0, height: 50, lineHeight: 10, rowCount: 3) == 0..<3)
  #expect(RowBucketing.overlappingRows(
    viewportRow: 5, yOffset: 0, height: 10, lineHeight: 10, rowCount: 3).isEmpty)
}
