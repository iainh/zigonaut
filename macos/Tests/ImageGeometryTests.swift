import Testing
@testable import ZigonautRenderSupport

@Test func imageGeometryClipsDestinationAndSourceTogether() {
  let result = ImageGeometry.clippedQuad(
    destination: ImageRect(x: -10, y: 20, width: 100, height: 50),
    source: ImageRect(x: 20, y: 40, width: 200, height: 100),
    clip: ImageRect(x: 0, y: 0, width: 80, height: 60))
  #expect(result == ImageQuad(
    destination: ImageRect(x: 0, y: 20, width: 80, height: 40),
    source: ImageRect(x: 40, y: 40, width: 160, height: 80)))
}

@Test func imageGeometryRejectsInvisibleAndEmptyPlacements() {
  let clip = ImageRect(x: 0, y: 0, width: 80, height: 60)
  #expect(ImageGeometry.clippedQuad(
    destination: ImageRect(x: 90, y: 0, width: 10, height: 10),
    source: ImageRect(x: 0, y: 0, width: 10, height: 10), clip: clip) == nil)
  #expect(ImageGeometry.clippedQuad(
    destination: ImageRect(x: 0, y: 0, width: 0, height: 10),
    source: ImageRect(x: 0, y: 0, width: 10, height: 10), clip: clip) == nil)
}
