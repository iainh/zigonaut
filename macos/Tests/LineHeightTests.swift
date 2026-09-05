import Testing
@testable import ZigonautRenderSupport

@Test func lineHeightPreservesDefaultAndCentresTightAndLooseRows() {
  let standard = LineHeight(naturalHeight: 19.2, percent: 100)
  #expect(standard.height == 20)
  #expect(standard.textOffset == 0)
  let tight = LineHeight(naturalHeight: 19.2, percent: 75)
  #expect(tight.height == 15)
  #expect(tight.textOffset == -2.5)
  let loose = LineHeight(naturalHeight: 19.2, percent: 150)
  #expect(loose.height == 30)
  #expect(loose.textOffset == 5)
}

@Test func lineHeightBoundsStoredPreferencesAndScalesWithFontSize() {
  #expect(LineHeight(naturalHeight: 20, percent: -1).height == 15)
  #expect(LineHeight(naturalHeight: 20, percent: 201).height == 40)
  #expect(LineHeight(naturalHeight: 20, percent: .nan).height == 20)
  #expect(LineHeight(naturalHeight: 40, percent: 150).height == 60)
  #expect(LineHeight(naturalHeight: 1, percent: 75).height == 1)
}
