import Foundation
import Testing
import ZigonautPaneLayout

@Test func paneDropChoosesNearestNormalizedEdge() {
  let size = CGSize(width: 200, height: 100)
  #expect(PaneDropEdge.nearest(to: CGPoint(x: 10, y: 50), in: size) == .left)
  #expect(PaneDropEdge.nearest(to: CGPoint(x: 190, y: 50), in: size) == .right)
  #expect(PaneDropEdge.nearest(to: CGPoint(x: 100, y: 5), in: size) == .top)
  #expect(PaneDropEdge.nearest(to: CGPoint(x: 100, y: 95), in: size) == .bottom)
}

@Test func paneDropRejectsInvalidGeometry() {
  #expect(PaneDropEdge.nearest(to: .zero, in: .zero) == nil)
  #expect(PaneDropEdge.nearest(to: CGPoint(x: -1, y: 10),
    in: CGSize(width: 100, height: 100)) == nil)
}
