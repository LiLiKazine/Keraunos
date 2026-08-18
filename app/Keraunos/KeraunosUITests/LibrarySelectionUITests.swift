import XCTest

/// Covers Library's selection mode end-to-end: Edit reveals the batch affordances, tapping a
/// download checks it off, and the confirmed batch delete actually removes the file and leaves
/// selection mode.
///
/// This is screen-level wiring — the branch that decides whether a tap plays a video or ticks a
/// checkbox — which no unit test can reach. Batch delete is destructive and irreversible, so the
/// path deserves a real tap-through rather than a hand check.
///
/// Like `PlayerRotationUITests`, it needs a non-empty Library, which a factory-fresh simulator
/// never has: `-KeraunosSeedLibrary` makes the app plant one clip before Library first renders.
final class LibrarySelectionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testSelectingADownloadAndDeletingItEmptiesTheLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-KeraunosSeedLibrary"]
        app.launch()

        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10), "no Library tab")
        libraryTab.tap()

        let seed = app.staticTexts["UITest Sample"]
        XCTAssertTrue(seed.waitForExistence(timeout: 10), "no library row — is the Library empty?")

        // Nothing selection-related exists until Edit is tapped.
        XCTAssertFalse(app.buttons["Select All"].exists, "batch bar showed outside selection mode")

        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "no Edit affordance in the Library header")
        edit.tap()

        XCTAssertTrue(app.buttons["Select All"].waitForExistence(timeout: 5),
                      "selection mode did not reveal the batch bar")
        // Delete is inert until something is actually selected.
        XCTAssertFalse(app.buttons["Delete"].isEnabled, "Delete was enabled with nothing selected")

        XCTAssertTrue(app.buttons["Done"].exists, "Edit did not become Done")

        // The tap must tick the row rather than open the player.
        seed.tap()
        XCTAssertTrue(app.staticTexts["1 Selected"].waitForExistence(timeout: 5),
                      "tapping a row in selection mode did not select it")
        // QuickLook would cover the shell; the tab bar still being reachable proves no player
        // was presented. (Don't probe for a "Done" button here — Edit/Done owns that label.)
        XCTAssertTrue(libraryTab.isHittable, "a tap in selection mode opened the player")

        let deleteOne = app.buttons["Delete (1)"]
        XCTAssertTrue(deleteOne.exists, "batch Delete did not pick up the count")
        deleteOne.tap()

        // Confirm the destructive dialog.
        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no delete confirmation appeared")
        confirm.tap()

        // The seed was the only download, so the Library falls back to its empty state — which
        // also proves selection mode was left behind.
        XCTAssertTrue(app.staticTexts["Nothing here yet"].waitForExistence(timeout: 10),
                      "the batch delete did not remove the download")
        XCTAssertFalse(app.buttons["Select All"].exists, "still in selection mode after deleting")
    }
}
