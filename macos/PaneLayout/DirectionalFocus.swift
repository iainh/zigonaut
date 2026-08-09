import CoreGraphics

public enum PaneFocusDirection {
  case left
  case right
  case up
  case down
}

public enum DirectionalPaneFocus {
  public static func destination<ID: Hashable>(
    from sourceID: ID,
    direction: PaneFocusDirection,
    frames: [ID: CGRect],
    stableOrder: [ID]
  ) -> ID? {
    guard let source = frames[sourceID] else { return nil }
    let sourceCentre = CGPoint(x: source.midX, y: source.midY)

    return stableOrder.enumerated().compactMap { orderIndex, candidateID -> Candidate<ID>? in
      guard candidateID != sourceID, let frame = frames[candidateID] else { return nil }
      let centre = CGPoint(x: frame.midX, y: frame.midY)
      let primaryDistance: CGFloat
      let primaryGap: CGFloat
      let perpendicularGap: CGFloat
      let perpendicularCentreDistance: CGFloat

      switch direction {
      case .left:
        guard centre.x < sourceCentre.x else { return nil }
        primaryDistance = sourceCentre.x - centre.x
        primaryGap = max(0, source.minX - frame.maxX)
        perpendicularGap = intervalGap(source.minY...source.maxY, frame.minY...frame.maxY)
        perpendicularCentreDistance = abs(sourceCentre.y - centre.y)
      case .right:
        guard centre.x > sourceCentre.x else { return nil }
        primaryDistance = centre.x - sourceCentre.x
        primaryGap = max(0, frame.minX - source.maxX)
        perpendicularGap = intervalGap(source.minY...source.maxY, frame.minY...frame.maxY)
        perpendicularCentreDistance = abs(sourceCentre.y - centre.y)
      case .up:
        guard centre.y < sourceCentre.y else { return nil }
        primaryDistance = sourceCentre.y - centre.y
        primaryGap = max(0, source.minY - frame.maxY)
        perpendicularGap = intervalGap(source.minX...source.maxX, frame.minX...frame.maxX)
        perpendicularCentreDistance = abs(sourceCentre.x - centre.x)
      case .down:
        guard centre.y > sourceCentre.y else { return nil }
        primaryDistance = centre.y - sourceCentre.y
        primaryGap = max(0, frame.minY - source.maxY)
        perpendicularGap = intervalGap(source.minX...source.maxX, frame.minX...frame.maxX)
        perpendicularCentreDistance = abs(sourceCentre.x - centre.x)
      }
      return Candidate(id: candidateID, primaryGap: primaryGap,
        primaryDistance: primaryDistance, perpendicularGap: perpendicularGap,
        perpendicularCentreDistance: perpendicularCentreDistance, orderIndex: orderIndex)
    }.min()?.id
  }

  private static func intervalGap(_ first: ClosedRange<CGFloat>, _ second: ClosedRange<CGFloat>) -> CGFloat {
    max(0, max(first.lowerBound, second.lowerBound) - min(first.upperBound, second.upperBound))
  }

  private struct Candidate<ID>: Comparable {
    let id: ID
    let primaryGap: CGFloat
    let primaryDistance: CGFloat
    let perpendicularGap: CGFloat
    let perpendicularCentreDistance: CGFloat
    let orderIndex: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
      if lhs.primaryGap != rhs.primaryGap { return lhs.primaryGap < rhs.primaryGap }
      if lhs.primaryDistance != rhs.primaryDistance { return lhs.primaryDistance < rhs.primaryDistance }
      if lhs.perpendicularGap != rhs.perpendicularGap { return lhs.perpendicularGap < rhs.perpendicularGap }
      if lhs.perpendicularCentreDistance != rhs.perpendicularCentreDistance {
        return lhs.perpendicularCentreDistance < rhs.perpendicularCentreDistance
      }
      return lhs.orderIndex < rhs.orderIndex
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.primaryGap == rhs.primaryGap && lhs.primaryDistance == rhs.primaryDistance
        && lhs.perpendicularGap == rhs.perpendicularGap
        && lhs.perpendicularCentreDistance == rhs.perpendicularCentreDistance
        && lhs.orderIndex == rhs.orderIndex
    }
  }
}
