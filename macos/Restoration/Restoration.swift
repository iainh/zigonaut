import AppKit
import Foundation

public struct SavedPane: Codable, Equatable {
  public let id: UUID
  public var directory: String?
  public init(id: UUID, directory: String?) { self.id = id; self.directory = directory }
}

public enum SavedAxis: String, Codable { case horizontal, vertical }

public indirect enum SavedPaneNode: Codable, Equatable {
  case leaf(SavedPane)
  case split(UUID, SavedAxis, Double, SavedPaneNode, SavedPaneNode)
}

public struct SavedTab: Codable, Equatable {
  public var root: SavedPaneNode
  public var focusedPane: UUID
  public init(root: SavedPaneNode, focusedPane: UUID) { self.root = root; self.focusedPane = focusedPane }
}

public struct SavedWindowGroup: Codable, Equatable {
  public var frame: String
  public var tabs: [SavedTab]
  public var selectedTab: Int
  public init(frame: String, tabs: [SavedTab], selectedTab: Int) {
    self.frame = frame; self.tabs = tabs; self.selectedTab = selectedTab
  }
}

public struct SavedApplication: Codable, Equatable {
  public static let version = 1
  public var version = Self.version
  public var groups: [SavedWindowGroup]
  public init(groups: [SavedWindowGroup]) { self.groups = groups }

  public func sanitized() -> SavedApplication? {
    guard version == Self.version else { return nil }
    let validGroups = groups.prefix(32).compactMap { group -> SavedWindowGroup? in
      let tabs = group.tabs.prefix(128).compactMap { tab -> SavedTab? in
        let leaves = tab.root.leafIDs
        guard !leaves.isEmpty, leaves.count <= 64, Set(leaves).count == leaves.count else { return nil }
        var copy = tab
        if !leaves.contains(copy.focusedPane) { copy.focusedPane = leaves[0] }
        copy.root = copy.root.sanitized
        return copy
      }
      guard !tabs.isEmpty else { return nil }
      return SavedWindowGroup(frame: group.frame, tabs: Array(tabs),
        selectedTab: min(max(group.selectedTab, 0), tabs.count - 1))
    }
    return validGroups.isEmpty ? nil : SavedApplication(groups: validGroups)
  }
}

extension SavedPaneNode {
  var leafIDs: [UUID] {
    switch self {
    case .leaf(let pane): [pane.id]
    case .split(_, _, _, let first, let second): first.leafIDs + second.leafIDs
    }
  }
  var sanitized: SavedPaneNode {
    switch self {
    case .leaf: self
    case .split(let id, let axis, let ratio, let first, let second):
      .split(id, axis, min(max(ratio.isFinite ? ratio : 0.5, 0.1), 0.9),
        first.sanitized, second.sanitized)
    }
  }
}

public enum RestorationStore {
  static let key = "terminalRestorationV1"
  public static func load(defaults: UserDefaults = .standard) -> SavedApplication? {
    guard let data = defaults.data(forKey: key), data.count <= 1_048_576,
      let state = try? JSONDecoder().decode(SavedApplication.self, from: data) else { return nil }
    return state.sanitized()
  }
  public static func save(_ state: SavedApplication, defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(state), data.count <= 1_048_576 else { return }
    defaults.set(data, forKey: key)
  }
  public static func clear(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}
