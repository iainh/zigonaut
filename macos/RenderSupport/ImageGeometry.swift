public struct ImageRect: Equatable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct ImageQuad: Equatable {
  public let destination: ImageRect
  public let source: ImageRect

  public init(destination: ImageRect, source: ImageRect) {
    self.destination = destination
    self.source = source
  }
}

public enum ImageGeometry {
  /// Clips an image placement while preserving its source-to-destination mapping.
  public static func clippedQuad(
    destination: ImageRect, source: ImageRect, clip: ImageRect
  ) -> ImageQuad? {
    guard destination.width > 0, destination.height > 0,
      source.width > 0, source.height > 0 else { return nil }
    let visibleX = max(destination.x, clip.x)
    let visibleY = max(destination.y, clip.y)
    let visibleMaxX = min(destination.x + destination.width, clip.x + clip.width)
    let visibleMaxY = min(destination.y + destination.height, clip.y + clip.height)
    guard visibleX < visibleMaxX, visibleY < visibleMaxY else { return nil }
    let visible = ImageRect(x: visibleX, y: visibleY,
      width: visibleMaxX - visibleX, height: visibleMaxY - visibleY)
    let xScale = source.width / destination.width
    let yScale = source.height / destination.height
    let visibleSource = ImageRect(
      x: source.x + (visible.x - destination.x) * xScale,
      y: source.y + (visible.y - destination.y) * yScale,
      width: visible.width * xScale,
      height: visible.height * yScale)
    return ImageQuad(destination: visible, source: visibleSource)
  }
}
