import XCTest
@testable import ZigonautRestoration
import ZigonautPaneLayout

final class RestorationTests: XCTestCase {
  func testRoundTripPreservesTopologyAndSanitizesUnsafeValues() throws {
    let first = UUID(), second = UUID()
    let state = SavedApplication(groups: [SavedWindowGroup(frame: "{{1, 2}, {800, 600}}", tabs: [
      SavedTab(root: .split(UUID(), .horizontal, 2,
        .leaf(SavedPane(id: first, directory: "/tmp")),
        .leaf(SavedPane(id: second, directory: nil))), focusedPane: UUID())
    ], selectedTab: 99)])
    let decoded = try JSONDecoder().decode(SavedApplication.self,
      from: JSONEncoder().encode(state)).sanitized()

    XCTAssertEqual(decoded?.groups[0].selectedTab, 0)
    XCTAssertEqual(decoded?.groups[0].tabs[0].focusedPane, first)
    guard case .split(_, .horizontal, let ratio, _, _) = decoded?.groups[0].tabs[0].root else {
      return XCTFail("split topology was not preserved")
    }
    XCTAssertEqual(ratio, 0.9)
  }

  func testDuplicatePaneIdentitiesRejectCorruptTab() {
    let id = UUID()
    let tab = SavedTab(root: .split(UUID(), .vertical, 0.5,
      .leaf(SavedPane(id: id, directory: nil)), .leaf(SavedPane(id: id, directory: nil))),
      focusedPane: id)
    XCTAssertNil(SavedApplication(groups: [SavedWindowGroup(frame: "", tabs: [tab],
      selectedTab: 0)]).sanitized())
  }

  func testSharedTreeRestoresIdentityRatiosAndMutatesWithoutLosingHiddenPanes() throws {
    // Deliberately share the UUID's upper half: truncated UUIDs must not alias.
    let a = UUID(uuidString: "12345678-1234-1234-0000-000000000001")!
    let b = UUID(uuidString: "12345678-1234-1234-0000-000000000002")!
    let c = UUID(), outer = UUID(), inner = UUID()
    let tree = try XCTUnwrap(SharedPaneTree(saved: .split(outer, .horizontal, 0.3,
      .leaf(SavedPane(id: a, directory: nil)), .split(inner, .vertical, 0.7,
        .leaf(SavedPane(id: b, directory: nil)), .leaf(SavedPane(id: c, directory: nil))))))
    XCTAssertEqual(tree.leafIDs, [a, b, c])
    XCTAssertTrue(tree.focus(c))
    XCTAssertTrue(tree.toggleZoom())
    XCTAssertEqual(tree.zoomed, c)
    let exported = tree.saved { $0 == b ? "/tmp" : nil }
    let restored = try XCTUnwrap(SharedPaneTree(saved: exported))
    XCTAssertEqual(restored.saved { $0 == b ? "/tmp" : nil }, exported)
    XCTAssertNil(restored.zoomed)
    XCTAssertTrue(tree.cycle(forward: true))
    XCTAssertEqual(tree.focused, a)
    XCTAssertEqual(tree.zoomed, a)
    XCTAssertTrue(tree.focus(c))
    XCTAssertTrue(tree.resize(.up))
    XCTAssertNil(tree.zoomed)
    XCTAssertEqual(tree.node(at: try XCTUnwrap(tree.index(of: outer))).ratio, 19661)
    XCTAssertEqual(tree.node(at: try XCTUnwrap(tree.index(of: inner))).ratio, 42598)
    XCTAssertTrue(tree.setRatio(outer, 0.4))
    XCTAssertFalse(tree.setRatio(outer, 0.4))
    XCTAssertTrue(tree.setRatio(outer, 0.9))
    XCTAssertFalse(tree.resize(.right))
    XCTAssertTrue(tree.move(a, onto: c, edge: .bottom))
    XCTAssertEqual(tree.leafIDs, [b, c, a])
    XCTAssertEqual(tree.focused, a)
    XCTAssertNil(tree.index(of: outer))
    XCTAssertTrue(tree.close(c))
    XCTAssertEqual(tree.leafIDs, [b, a])
    XCTAssertEqual(tree.focused, b)
    XCTAssertTrue(tree.close(a))
    XCTAssertFalse(tree.close(b))
    XCTAssertEqual(tree.leafIDs, [b])
    let d = UUID()
    XCTAssertTrue(tree.split(target: b, pane: d, vertical: false))
    XCTAssertEqual(tree.focused, d)
    XCTAssertEqual(tree.leafIDs, [b, d])
  }

  func testSharedTreeRepairsSplitUUIDCollisionsWithoutAliasingTerminals() throws {
    let a = UUID(), b = UUID(), c = UUID()
    let tree = try XCTUnwrap(SharedPaneTree(saved: .split(a, .horizontal, 0.4,
      .leaf(SavedPane(id: a, directory: nil)), .split(a, .vertical, 0.6,
        .leaf(SavedPane(id: b, directory: nil)), .leaf(SavedPane(id: c, directory: nil))))))
    XCTAssertEqual(tree.leafIDs, [a, b, c])
    let saved = tree.saved { _ in nil }
    guard case .split(let outer, _, _, _, .split(let inner, _, _, _, _)) = saved else {
      return XCTFail("mixed split topology was not preserved")
    }
    XCTAssertNotEqual(outer, a)
    XCTAssertNotEqual(inner, a)
    XCTAssertNotEqual(outer, inner)
    XCTAssertEqual(try XCTUnwrap(SharedPaneTree(saved: saved)).saved { _ in nil }, saved)
  }
}
