import CoreGraphics
import ZigonautCore

public enum PaneFocusDirection: UInt8 {
  case left, right, up, down
}

public enum DirectionalPaneFocus {
  public static func destination<ID: Hashable>(
    from sourceID: ID,
    direction: PaneFocusDirection,
    frames: [ID: CGRect],
    stableOrder: [ID]
  ) -> ID? {
    guard let source = stableOrder.firstIndex(of: sourceID), frames[sourceID] != nil else { return nil }
    // A bounded stack buffer, not a converted tree or a heap candidate list.
    return withUnsafeTemporaryAllocation(of: zigonaut_pane_frame.self, capacity: stableOrder.count) { buffer in
      var count = 0
      for (index, id) in stableOrder.enumerated() {
        guard let frame = frames[id] else { continue }
        buffer[count] = zigonaut_pane_frame(id: UInt64(index + 1), x: frame.minX, y: frame.minY,
          width: frame.width, height: frame.height)
        count += 1
      }
      guard let base = buffer.baseAddress else { return nil }
      let destination = zigonaut_panes_destination(UInt64(source + 1), direction.rawValue, base, count)
      return destination == 0 ? nil : stableOrder[Int(destination - 1)]
    }
  }
}
