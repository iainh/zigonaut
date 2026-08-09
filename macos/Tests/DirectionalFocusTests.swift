import Foundation
import Testing
import ZigonautPaneLayout

struct DirectionalFocusTests {
  private let frames: [String: CGRect] = [
    "topLeft": CGRect(x: 0, y: 0, width: 100, height: 100),
    "topRight": CGRect(x: 100, y: 0, width: 100, height: 100),
    "bottomLeft": CGRect(x: 0, y: 100, width: 100, height: 100),
    "bottomRight": CGRect(x: 100, y: 100, width: 100, height: 100),
  ]
  private let order = ["topLeft", "topRight", "bottomLeft", "bottomRight"]

  @Test func directionsChooseGeometricNeighbour() {
    #expect(destination("bottomRight", .left) == "bottomLeft")
    #expect(destination("bottomRight", .up) == "topRight")
    #expect(destination("topLeft", .right) == "topRight")
    #expect(destination("topLeft", .down) == "bottomLeft")
  }

  @Test func candidatesOutsideRequestedHalfPlaneAreRejected() {
    #expect(destination("topLeft", .left) == nil)
    #expect(destination("topLeft", .up) == nil)
  }

  @Test func overlappingProjectionBeatsEquidistantDiagonal() {
    var layout = frames
    layout["diagonal"] = CGRect(x: 100, y: 110, width: 100, height: 100)
    let result = DirectionalPaneFocus.destination(from: "topLeft", direction: .right,
      frames: layout, stableOrder: order + ["diagonal"])
    #expect(result == "topRight")
  }

  @Test func stableOrderBreaksEqualGeometryTie() {
    let layout = ["source": CGRect(x: 0, y: 0, width: 100, height: 100),
      "first": CGRect(x: 100, y: 0, width: 100, height: 100),
      "second": CGRect(x: 100, y: 0, width: 100, height: 100)]
    let result = DirectionalPaneFocus.destination(from: "source", direction: .right,
      frames: layout, stableOrder: ["source", "second", "first"])
    #expect(result == "second")
  }

  private func destination(_ source: String, _ direction: PaneFocusDirection) -> String? {
    DirectionalPaneFocus.destination(from: source, direction: direction,
      frames: frames, stableOrder: order)
  }
}
