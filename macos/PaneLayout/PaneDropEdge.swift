import CoreGraphics
import ZigonautCore

public enum PaneDropEdge: UInt8, Equatable {
  case left
  case right
  case top
  case bottom

  public static func nearest(to point: CGPoint, in size: CGSize) -> PaneDropEdge? {
    let edge = zigonaut_panes_drop_edge(point.x, point.y, size.width, size.height)
    return edge < 0 ? nil : PaneDropEdge(rawValue: UInt8(edge))
  }
}
