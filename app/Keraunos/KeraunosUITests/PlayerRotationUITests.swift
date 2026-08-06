import XCTest

/// Regression: playing a downloaded video and rotating the device must not dismiss the
/// player.
///
/// The original bug only reproduced on iPhones whose landscape orientation reports
/// `horizontalSizeClass == .regular` (Pro Max / Plus). `AppShell` branched on the size
/// class, so rotating swapped a `TabView` for a `NavigationSplitView` — a view-identity
/// change that destroyed `LibraryScreen`, its `previewURL` state, and the QuickLook
/// presentation hosted above it. **Run this on a Pro Max** (or any device whose landscape
/// is regular width); on a non-Max iPhone the size class never flips and the test would
/// pass even against the broken shell.
///
/// Requires at least one file in the Library.
final class PlayerRotationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testPlayerSurvivesRotationToLandscape() throws {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10), "no Library tab")
        libraryTab.tap()

        // Open the first library row.
        let row = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no library row — is the Library empty?")
        row.tap()

        // QuickLook takes a beat to present.
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "player did not present in portrait")
        print("EVIDENCE portrait: \(shellState(app))")

        // The bug: rotate to landscape. With a single `.sidebarAdaptable` TabView the shell
        // restyles in place instead of swapping containers, so the player survives.
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 3)
        print("EVIDENCE landscape: \(shellState(app))")
        XCTAssertTrue(app.buttons["Done"].exists,
                      "player was dismissed by rotating to landscape")

        // Rotating back must not dismiss it either — the reverse flip is a second chance to
        // tear the shell down.
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 3)
        print("EVIDENCE back to portrait: \(shellState(app))")
        XCTAssertTrue(app.buttons["Done"].exists,
                      "player was dismissed by rotating back to portrait")
    }

    /// Which shell chrome is up, and is the player still there. `sidebarBrand` appearing
    /// while `tabBar` disappears is the container swap this test exists to catch.
    @MainActor
    private func shellState(_ app: XCUIApplication) -> String {
        "tabBar=\(app.tabBars.buttons["Library"].exists) " +
        "sidebarBrand=\(app.staticTexts["Keraunos"].exists) " +
        "Done=\(app.buttons["Done"].exists)"
    }
}
