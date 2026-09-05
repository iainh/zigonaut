import Foundation

/// Row geometry changes independently of glyph size. Round to logical pixels
/// like the existing font metrics, then centre text within the adjusted row.
public struct LineHeight {
  public let height: Double
  public let textOffset: Double

  public init(naturalHeight: Double, percent: Double) {
    let natural = max(1, ceil(naturalHeight))
    let boundedPercent = percent.isFinite ? min(200, max(75, percent)) : 100
    height = max(1, (natural * boundedPercent / 100).rounded())
    textOffset = (height - natural) / 2
  }
}
