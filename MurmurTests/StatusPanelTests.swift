import XCTest
@testable import Murmur

final class StatusPanelTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1728, height: 1085)      // visible frame, menu bar excluded
    private let external = CGRect(x: 1728, y: 200, width: 3440, height: 1440)
    private let size = CGSize(width: 220, height: 44)

    // MARK: Anchor

    func testDefaultAnchorIsBottomCentreOfTheScreen() {
        let anchor = PanelAnchor.default(for: main)
        XCTAssertEqual(anchor.centerX, 864)
        XCTAssertEqual(anchor.bottomY, 60)
    }

    func testOriginKeepsCentreXAndBottomYForAnySize() {
        let anchor = PanelAnchor(centerX: 500, bottomY: 80)
        XCTAssertEqual(anchor.origin(for: CGSize(width: 200, height: 40)), CGPoint(x: 400, y: 80))
        XCTAssertEqual(anchor.origin(for: CGSize(width: 300, height: 70)), CGPoint(x: 350, y: 80))
    }

    func testSavedAnchorOnAConnectedScreenIsKept() {
        let saved = PanelAnchor(centerX: 3000, bottomY: 300)
        XCTAssertEqual(saved.resolved(panelSize: size, screens: [main, external], fallback: main), saved)
    }

    func testSavedAnchorOffEveryScreenFallsBackToDefault() {
        let saved = PanelAnchor(centerX: 3000, bottomY: 300)   // was on the external display
        XCTAssertEqual(saved.resolved(panelSize: size, screens: [main], fallback: main), .default(for: main))
    }

    func testAnchorMostlyOffTheEdgeFallsBack() {
        // Only a sliver of the panel would be visible above the top edge.
        let saved = PanelAnchor(centerX: 864, bottomY: 1080)
        XCTAssertEqual(saved.resolved(panelSize: size, screens: [main], fallback: main), .default(for: main))
    }

    func testAnchorRoundTripsThroughJSON() throws {
        let anchor = PanelAnchor(centerX: 12.5, bottomY: 34)
        let data = try JSONEncoder().encode(anchor)
        XCTAssertEqual(try JSONDecoder().decode(PanelAnchor.self, from: data), anchor)
    }

    // MARK: Idle hint

    func testIdleShowsNoHintWhenReady() {
        let idle = StatusPanelIdle.make(isReady: true, statusText: "Hold Right ⌥ to dictate")
        XCTAssertEqual(idle.hint, "")
        XCTAssertFalse(idle.isWarning)
    }

    func testIdleHintShowsTheReasonWhenNotReady() {
        let idle = StatusPanelIdle.make(isReady: false, statusText: "Accessibility permission needed")
        XCTAssertEqual(idle.hint, "Accessibility permission needed")
        XCTAssertTrue(idle.isWarning)
    }

    // MARK: Setting

    @MainActor
    func testStatusPanelIsOffByDefault() {
        let suite = "com.yevhen.murmur.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.showStatusPanel)
        XCTAssertNil(store.statusPanelAnchor)
        defaults.removePersistentDomain(forName: suite)
    }
}
