import XCTest

/// Drives the demo video. Skipped unless run with `TEST_RUNNER_BRICK_DEMO=1`, so it never slows the
/// normal suite. Pauses are deliberate, just long enough for a viewer to read each screen.
final class DemoRecordingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    private func mark(_ label: String) {
        print("DEMO_\(label) \(Date().timeIntervalSince1970)")
    }

    private func row(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func launch(_ arguments: String...) {
        app.launchArguments = ["-uiTesting", "-time", "12:00"] + arguments
        app.launch()
    }

    func testRecordDemo() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BRICK_DEMO"] == "1", "Demo recording only")

        // Online: the day at a glance.
        launch("-resetStore")
        XCTAssertTrue(row("Pick, WO-10402").waitForExistence(timeout: 10))
        mark("START")
        pause(2.0)

        // Complete with confirmation; the next step unlocks.
        row("Pick, WO-10402").tap()
        pause(1.2)
        app.buttons["completeButton"].tap()
        XCTAssertTrue(app.buttons["Mark done"].waitForExistence(timeout: 5))
        pause(1.0)
        app.buttons["Mark done"].tap()
        XCTAssertTrue(app.staticTexts["confirmation"].waitForExistence(timeout: 5))
        pause(1.6)

        // Next step, now completable: reschedule it to tomorrow.
        row("2. Pack").tap()
        pause(1.2)
        app.buttons["rescheduleButton"].tap()
        XCTAssertTrue(app.buttons["confirmReschedule"].waitForExistence(timeout: 5))
        pause(1.2)
        app.buttons["confirmReschedule"].tap()
        XCTAssertTrue(app.staticTexts["confirmation"].waitForExistence(timeout: 5))
        pause(1.6)

        // Back to the list: overdue count and waiting markers have updated.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(0.5)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1.8)

        // Customer view, grouped by work order.
        app.buttons["customerFilter"].tap()
        pause(0.8)
        app.buttons["Brightwater Skincare"].tap()
        pause(2.0)

        // The filter follows to tomorrow, where the rescheduled pack now lives.
        app.buttons["nextDay"].tap()
        pause(2.0)
        app.buttons["customerFilter"].tap()
        pause(0.6)
        app.buttons["All customers"].tap()
        pause(0.8)
        app.buttons["todayButton"].tap()
        pause(1.2)

        // Offline: the app restarts with no network and works from its saved copy.
        app.terminate()
        launch("-offline")
        XCTAssertTrue(row("Pack, WO-10401").waitForExistence(timeout: 10))
        pause(2.5)

        row("Pack, WO-10401").tap()
        XCTAssertTrue(app.buttons["completeButton"].waitForExistence(timeout: 5))
        pause(2.8)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(0.8)

        // A day never loaded while online: a clear message and a way out, not a dead end.
        app.buttons["nextDay"].tap()
        pause(0.6)
        app.buttons["nextDay"].tap()
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 5))
        pause(2.5)
        app.buttons["todayButton"].tap()
        pause(1.5)
        mark("END")
    }
}
