import ZigonautCore

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
    var quad = zigonaut_image_quad()
    guard zigonaut_image_clip_quad(
      zigonaut_image_rect(x: destination.x, y: destination.y,
        width: destination.width, height: destination.height),
      zigonaut_image_rect(x: source.x, y: source.y, width: source.width, height: source.height),
      zigonaut_image_clip(left: clip.x, top: clip.y,
        right: clip.x + clip.width, bottom: clip.y + clip.height), &quad) == 2 else { return nil }
    return ImageQuad(
      destination: ImageRect(x: quad.destination.x, y: quad.destination.y,
        width: quad.destination.width, height: quad.destination.height),
      source: ImageRect(x: quad.source.x, y: quad.source.y,
        width: quad.source.width, height: quad.source.height))
  }
}
