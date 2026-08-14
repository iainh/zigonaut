import CoreGraphics

public enum PaneDropEdge: Equatable {
  case left
  case right
  case top
  case bottom

  public static func nearest(to point: CGPoint, in size: CGSize) -> PaneDropEdge? {
    guard size.width > 0, size.height > 0,
      point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return nil }
    let distances: [(PaneDropEdge, CGFloat)] = [
      (.left, point.x / size.width),
      (.right, (size.width - point.x) / size.width),
      (.top, point.y / size.height),
      (.bottom, (size.height - point.y) / size.height),
    ]
    return distances.min { $0.1 < $1.1 }?.0
  }
}
