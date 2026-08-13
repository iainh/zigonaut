import Testing
@testable import ZigonautRenderSupport

@Test func retainedScrollConvertsScrollbarDirectionToSceneDirection() {
  #expect(RetainedScroll.rowDelta(previousOffset: 20, currentOffset: 18, rowCount: 24) == 2)
  #expect(RetainedScroll.rowDelta(previousOffset: 18, currentOffset: 20, rowCount: 24) == -2)
}

@Test func retainedScrollRejectsEmptyAndCompleteViewportShifts() {
  #expect(RetainedScroll.rowDelta(previousOffset: 20, currentOffset: 20, rowCount: 24) == nil)
  #expect(RetainedScroll.rowDelta(previousOffset: 0, currentOffset: 24, rowCount: 24) == nil)
  #expect(RetainedScroll.rowDelta(previousOffset: 0, currentOffset: 1, rowCount: 1) == nil)
}

@Test func retainedScrollMapsDestinationRowsToRetainedSources() {
  #expect(RetainedScroll.sourceRow(for: 2, delta: 2, rowCount: 4) == 0)
  #expect(RetainedScroll.sourceRow(for: 0, delta: 2, rowCount: 4) == nil)
  #expect(RetainedScroll.sourceRow(for: 1, delta: -1, rowCount: 4) == 2)
  #expect(RetainedScroll.sourceRow(for: 3, delta: -1, rowCount: 4) == nil)
}
