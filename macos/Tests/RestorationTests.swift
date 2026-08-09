import XCTest
@testable import ZigonautRestoration

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
}
