import XCTest

/// End-to-end flows on the simulated server (`-uiTesting`), with the clock pinned to 12:00 today.
/// Sample data at 12:00: WO-10401 (Tidewell Apparel) pick done, pack overdue, ship waiting;
/// WO-10402 (Brightwater Skincare) pick overdue; WO-10403 (Foxglove Pet Supply) all later today.
final class BrickTasksUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ arguments: String...) {
        app.launchArguments = ["-uiTesting", "-time", "12:00"] + arguments
        app.launch()
    }

    private func row(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func text(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
    }

    func testTodayShowsOverdueAtAGlance() {
        launch("-resetStore")
        XCTAssertTrue(app.staticTexts["dayTitle"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["dayTitle"].firstMatch.label.hasPrefix("Today"))
        XCTAssertTrue(row("Pick, WO-10402").waitForExistence(timeout: 10))
        XCTAssertTrue(row("Pick, WO-10402").label.contains("overdue"))
        XCTAssertTrue(row("Pack, WO-10401").label.contains("overdue"))
        XCTAssertFalse(row("Pick, WO-10403").label.contains("overdue"))
        XCTAssertTrue(text(containing: "2 overdue").exists)
    }

    func testCompleteAsksFirstThenUnlocksTheNextStep() {
        launch("-resetStore")
        XCTAssertTrue(row("Pack, WO-10401").waitForExistence(timeout: 10))
        XCTAssertTrue(row("Ship, WO-10401").label.contains("waiting"))
        row("Pack, WO-10401").tap()

        app.buttons["completeButton"].tap()
        let confirm = app.buttons["Mark done"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(app.staticTexts["confirmation"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["confirmation"].label, "Marked done.")
        XCTAssertFalse(app.buttons["completeButton"].exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row("Ship, WO-10401").waitForExistence(timeout: 5))
        XCTAssertFalse(row("Ship, WO-10401").label.contains("waiting"))
    }

    func testCancellingTheConfirmationChangesNothing() {
        launch("-resetStore")
        XCTAssertTrue(row("Pick, WO-10402").waitForExistence(timeout: 10))
        row("Pick, WO-10402").tap()
        app.buttons["completeButton"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["completeButton"].isEnabled)
        XCTAssertFalse(app.staticTexts["confirmation"].exists)
    }

    func testBlockedStepExplainsWhy() {
        launch("-resetStore")
        XCTAssertTrue(row("Ship, WO-10401").waitForExistence(timeout: 10))
        row("Ship, WO-10401").tap()
        XCTAssertTrue(app.buttons["completeButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["completeButton"].isEnabled)
        XCTAssertEqual(app.staticTexts["disabledReason"].label, "Complete pack first.")
        XCTAssertTrue(app.buttons["rescheduleButton"].isEnabled)
    }

    func testRescheduleMovesTaskToAnotherDay() {
        launch("-resetStore")
        XCTAssertTrue(row("Pick, WO-10403").waitForExistence(timeout: 10))
        row("Pick, WO-10403").tap()

        app.buttons["rescheduleButton"].tap()
        XCTAssertTrue(app.buttons["confirmReschedule"].waitForExistence(timeout: 5))
        app.buttons["confirmReschedule"].tap()
        XCTAssertTrue(app.staticTexts["confirmation"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["confirmation"].label, "Moved to Tomorrow.")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row("Pack, WO-10403").waitForExistence(timeout: 5))
        XCTAssertFalse(row("Pick, WO-10403").exists)

        app.buttons["nextDay"].tap()
        XCTAssertTrue(row("Pick, WO-10403").waitForExistence(timeout: 5))
        app.buttons["todayButton"].tap()
        XCTAssertTrue(row("Pack, WO-10403").waitForExistence(timeout: 5))
    }

    func testOfflineRelaunchShowsSavedTasksAndDisablesActions() {
        launch("-resetStore")
        XCTAssertTrue(row("Pick, WO-10402").waitForExistence(timeout: 10))
        app.terminate()

        launch("-offline")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Offline. Showing tasks saved at'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(row("Pick, WO-10402").exists)

        row("Pick, WO-10402").tap()
        XCTAssertTrue(app.buttons["completeButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["completeButton"].isEnabled)
        XCTAssertFalse(app.buttons["rescheduleButton"].isEnabled)
        XCTAssertTrue(text(containing: "You're offline. Connect to make changes.").exists)
    }

    func testOfflineWithNothingSavedOffersRetryNotADeadEnd() {
        launch("-resetStore", "-offline")
        XCTAssertTrue(app.staticTexts["Can't load tasks"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Try again"].exists)
    }

    func testCustomerFilterGroupsByWorkOrder() {
        launch("-resetStore")
        XCTAssertTrue(row("Pick, WO-10402").waitForExistence(timeout: 10))

        app.buttons["customerFilter"].tap()
        app.buttons["Tidewell Apparel"].tap()

        XCTAssertTrue(text(containing: "1 of 3 done today").waitForExistence(timeout: 5))
        XCTAssertTrue(row("Pack, WO-10401").exists)
        XCTAssertFalse(row("Pick, WO-10402").exists)
        XCTAssertTrue(text(containing: "1 overdue").exists)

        app.buttons["customerFilter"].tap()
        app.buttons["All customers"].tap()
        XCTAssertTrue(row("Pick, WO-10402").waitForExistence(timeout: 5))
    }

    /// Regression: the "Marked done." message used to sit inline and auto-hide after 4 seconds,
    /// shifting every row up under the operator's finger.
    func testRowsDoNotMoveWhenTheConfirmationHides() {
        launch("-resetStore")
        XCTAssertTrue(row("Pack, WO-10401").waitForExistence(timeout: 10))
        row("Pack, WO-10401").tap()
        app.buttons["completeButton"].tap()
        XCTAssertTrue(app.buttons["Mark done"].waitForExistence(timeout: 5))
        app.buttons["Mark done"].tap()
        XCTAssertTrue(app.staticTexts["confirmation"].waitForExistence(timeout: 5))

        let ship = row("3. Ship")
        XCTAssertTrue(ship.waitForExistence(timeout: 5))
        let before = ship.frame
        let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["confirmation"])
        wait(for: [hidden], timeout: 8)
        XCTAssertEqual(ship.frame, before)
    }

    /// Regression: tapping a step opens that step, and the step you came from isn't left highlighted.
    func testStepLinksOpenThatStep() {
        launch("-resetStore")
        XCTAssertTrue(row("Pick, WO-10402").waitForExistence(timeout: 10))
        row("Pick, WO-10402").tap()

        XCTAssertTrue(row("2. Pack").waitForExistence(timeout: 5))
        row("2. Pack").tap()
        XCTAssertTrue(app.navigationBars["Pack"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["disabledReason"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["disabledReason"].label, "Complete pick first.")
        XCTAssertFalse(row("1. Pick").isSelected)
    }
}
