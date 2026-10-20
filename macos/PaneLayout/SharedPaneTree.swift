import Foundation
import ZigonautCore
import ZigonautRestoration

/// Native identity registry and read-only presentation of the authoritative Zig
/// tree. Confined to the owning window's main thread. Never stores a Swift tree.
public final class SharedPaneTree {
  private let pointer: OpaquePointer
  private let nodes: UnsafeMutableBufferPointer<zigonaut_pane_node>
  private var nativeIDs: [UUID: UInt64]
  private var uuids: [UInt64: UUID]
  private var nextID: UInt64
  private var indices: [UUID: Int] = [:]
  public private(set) var count = 0
  public private(set) var leafIDs: [UUID] = []

  public init?(saved: SavedPaneNode) {
    var reservedLeaves = Set<UUID>()
    func reserve(_ node: SavedPaneNode) -> Bool {
      switch node {
      case .leaf(let pane): return reservedLeaves.insert(pane.id).inserted && reservedLeaves.count <= 64
      case .split(_, _, _, let first, let second): return reserve(first) && reserve(second)
      }
    }
    guard reserve(saved) else { return nil }
    var records: [zigonaut_pane_node] = []
    var nativeIDs: [UUID: UInt64] = [:]
    var uuids: [UInt64: UUID] = [:]
    var next: UInt64 = 1
    func append(_ saved: SavedPaneNode) {
      let index = records.count
      let uuid: UUID
      switch saved {
      case .leaf(let pane): uuid = pane.id
      case .split(let id, _, _, _, _):
        // Older restoration accepted duplicate split UUIDs. Repair metadata,
        // never alias two nodes or truncate UUIDs into integer identities.
        uuid = nativeIDs[id] == nil && !reservedLeaves.contains(id) ? id : UUID()
      }
      let id = next
      next += 1
      nativeIDs[uuid] = id
      uuids[id] = uuid
      records.append(zigonaut_pane_node(id: id, subtree_size: 1, ratio: 0, split: false, vertical: false))
      if case .split(_, let axis, let ratio, let first, let second) = saved {
        append(first)
        append(second)
        records[index].split = true
        records[index].vertical = axis == .vertical
        records[index].ratio = Self.encodedRatio(ratio)
        records[index].subtree_size = UInt32(records.count - index)
      }
    }
    append(saved)
    guard let pointer = records.withUnsafeBufferPointer({
      zigonaut_panes_create($0.baseAddress!, $0.count)
    }) else { return nil }
    self.pointer = pointer
    self.nativeIDs = nativeIDs
    self.uuids = uuids
    nextID = next
    nodes = .allocate(capacity: 127)
    refresh(topology: true)
  }

  deinit {
    zigonaut_panes_destroy(pointer)
    nodes.deallocate()
  }

  public var focused: UUID? { uuids[zigonaut_panes_focused(pointer)] }
  public var zoomed: UUID? { uuids[zigonaut_panes_zoomed(pointer)] }
  public func node(at index: Int) -> zigonaut_pane_node { nodes[index] }
  public func id(at index: Int) -> UUID { uuids[nodes[index].id]! }
  public func index(of id: UUID) -> Int? { indices[id] }

  @discardableResult public func focus(_ id: UUID) -> Bool {
    guard let native = nativeIDs[id] else { return false }
    return zigonaut_panes_focus(pointer, native)
  }

  public func split(target: UUID, pane: UUID, vertical: Bool) -> Bool {
    guard let target = nativeIDs[target], nativeIDs[pane] == nil, leafIDs.count < 64 else { return false }
    let paneID = register(pane)
    let splitID = register(UUID())
    guard zigonaut_panes_split(pointer, target, paneID, splitID, vertical) else {
      refresh(topology: true)
      return false
    }
    refresh(topology: true)
    return true
  }

  public func move(_ source: UUID, onto target: UUID, edge: PaneDropEdge) -> Bool {
    guard let source = nativeIDs[source], let target = nativeIDs[target] else { return false }
    let splitID = register(UUID())
    let changed = zigonaut_panes_move(pointer, source, target, splitID, edge.rawValue)
    refresh(topology: true)
    return changed
  }

  public func close(_ id: UUID) -> Bool {
    guard let native = nativeIDs[id], zigonaut_panes_close(pointer, native) else { return false }
    refresh(topology: true)
    return true
  }

  public func setRatio(_ id: UUID, _ ratio: Double) -> Bool {
    guard let index = indices[id], nodes[index].split else { return false }
    let encoded = Self.encodedRatio(ratio)
    guard nodes[index].ratio != encoded,
      zigonaut_panes_ratio(pointer, nodes[index].id, encoded) else { return false }
    // Only this record changed: divider motion doesn't rebuild the snapshot.
    nodes[index].ratio = encoded
    return true
  }

  public func canResize(_ direction: PaneFocusDirection) -> Bool {
    zigonaut_panes_can_resize(pointer, direction.rawValue)
  }
  public func cycle(forward: Bool) -> Bool { zigonaut_panes_action(pointer, forward ? 5 : 4) }
  public func toggleZoom() -> Bool { zigonaut_panes_action(pointer, 11) }
  public func resize(_ direction: PaneFocusDirection) -> Bool {
    let changed = zigonaut_panes_action(pointer, 6 + direction.rawValue)
    if changed { refresh(topology: false) }
    return changed
  }
  public func equalize() -> Bool {
    let changed = zigonaut_panes_action(pointer, 10)
    if changed { refresh(topology: false) }
    return changed
  }

  public func saved(directory: (UUID) -> String?) -> SavedPaneNode {
    func save(_ index: Int) -> SavedPaneNode {
      let node = nodes[index]
      let uuid = id(at: index)
      guard node.split else { return .leaf(SavedPane(id: uuid, directory: directory(uuid))) }
      let second = index + 1 + Int(nodes[index + 1].subtree_size)
      return .split(uuid, node.vertical ? .vertical : .horizontal, Double(node.ratio) / 65535,
        save(index + 1), save(second))
    }
    return save(0)
  }

  private func register(_ uuid: UUID) -> UInt64 {
    let id = nextID
    nextID += 1
    nativeIDs[uuid] = id
    uuids[id] = uuid
    return id
  }
  private func refresh(topology: Bool) {
    count = zigonaut_panes_nodes(pointer, nodes.baseAddress!, nodes.count)
    precondition(count <= nodes.count)
    guard topology else { return }
    leafIDs.removeAll(keepingCapacity: true)
    indices.removeAll(keepingCapacity: true)
    for index in 0..<count {
      let uuid = id(at: index)
      indices[uuid] = index
      if !nodes[index].split { leafIDs.append(uuid) }
    }
    nativeIDs = nativeIDs.filter { indices[$0.key] != nil }
    uuids = uuids.filter { indices[$0.value] != nil }
  }
  private static func encodedRatio(_ ratio: Double) -> UInt16 {
    let bounded = min(max(ratio.isFinite ? ratio : 0.5, 0.1), 0.9)
    return min(max(UInt16((bounded * 65535).rounded()), 6554), 58981)
  }
}
