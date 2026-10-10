import XCTest

/// QA walk-through of PixelPare in sample mode. Every launch passes `--sample`.
/// Screenshots are attached to the result bundle and written to .build/pp-uitest/ inside the project
/// (the /tmp location from the brief is forbidden by runtime policy).
/// SAFETY: no test taps Render preview, Preview size, Compare, Press or Start, and no video plan is confirmed.
final class PixelPareUITests: XCTestCase {
    static let outputDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/pp-uitest", isDirectory: true)
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func launch(screen: String? = nil, extra: [String] = []) {
        app.launchArguments = ["--sample"]
        if let screen { app.launchArguments += ["--screen", screen] }
        app.launchArguments += extra
        app.launch()
    }

    /// Attaches a screenshot to the result bundle and writes a PNG for the view tool.
    func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        let url = Self.outputDir.appendingPathComponent("\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }

    /// Buttons whose label starts with the given text (for labels that change, e.g. "Undo" vs "Undo mark").
    func buttons(startingWith prefix: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
    }

    func lightTableReady() -> Bool {
        app.buttons["Skip"].firstMatch.waitForExistence(timeout: 20)
    }

    // MARK: Workbench

    func testWorkbenchTraysAndToolbar() throws {
        launch()
        XCTAssertTrue(app.buttons["Calm mode"].waitForExistence(timeout: 20))
        snap("01-workbench-top")
        // Silk() uppercases its text, so match case-insensitively.
        let trayLabels = ["Module 01 · Lookalike tray", "Module 02 · Video press", "Module 03 · Old screenshots",
                          "Module 04 · Blurry shots", "Gauge · Honest estimate"]
        for (i, label) in trayLabels.enumerated() {
            let element = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
            let found = scrollUntilVisible(element)
            snap(String(format: "02-tray-%02d", i + 1))
            XCTAssertTrue(found, "Tray missing: \(label)")
        }
        XCTAssertTrue(app.buttons["Rescan"].exists, "Rescan button missing")
        XCTAssertTrue(app.buttons["More"].exists, "More menu missing")
    }

    func testPullToRefreshDoesNotBreakWorkbench() throws {
        launch()
        XCTAssertTrue(app.buttons["Calm mode"].waitForExistence(timeout: 20))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.1, thenDragTo: end)
        Thread.sleep(forTimeInterval: 3)
        snap("07-after-pull-to-refresh")
        XCTAssertTrue(app.buttons["Calm mode"].exists, "Toolbar gone after pull-to-refresh")
    }

    func testCalmModeToggleOnAndOff() throws {
        launch()
        let calm = app.buttons["Calm mode"]
        XCTAssertTrue(calm.waitForExistence(timeout: 20))
        calm.tap()
        Thread.sleep(forTimeInterval: 0.5)
        snap("03-calm-on")
        calm.tap()
        Thread.sleep(forTimeInterval: 0.5)
        snap("04-calm-off")
    }

    func testMoreMenuOpensHistoryAndSettings() throws {
        launch()
        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        app.buttons["Settings"].firstMatch.tap()
        snap("05-settings")
        app.navigationBars.buttons.firstMatch.tap()
        more.tap()
        app.buttons["History"].firstMatch.tap()
        snap("06-history")
    }

    // MARK: Light table

    func testLightTableUndoAndKeeperRules() throws {
        launch(screen: "lighttable")
        XCTAssertTrue(lightTableReady(), "Group action bar missing on light table")
        snap("10-lighttable-initial")

        // The sample group has one marked duplicate and a keeper. The keeper must never offer Mark or Undo.
        XCTAssertEqual(buttons(startingWith: "Undo").count, 1, "Expected exactly one Undo (the marked, non-keeper photo)")

        buttons(startingWith: "Undo").firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.5)
        snap("14-lighttable-after-undo")
        XCTAssertEqual(buttons(startingWith: "Undo").count, 0, "Undo should disappear after undoing the only mark")
    }

    func testLightTableApproveChangesToUndoApproval() throws {
        launch(screen: "lighttable")
        XCTAssertTrue(lightTableReady(), "Group action bar missing on light table")
        app.buttons["Approve"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        snap("15-lighttable-after-approve")
        XCTAssertTrue(app.buttons["Undo approval"].waitForExistence(timeout: 3), "Approve should change to Undo approval")
    }

    func testLightTableLandscape() throws {
        launch(screen: "lighttable")
        XCTAssertTrue(lightTableReady())
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1)
        snap("11-lighttable-landscape")
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1)
        snap("12-lighttable-portrait")
    }

    // MARK: Screenshots and blurry

    func testScreenshotsScreen() throws {
        launch(screen: "screenshots")
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 1)
        snap("20-screenshots")
    }

    func testBlurryScreen() throws {
        launch(screen: "blurry")
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 1)
        snap("21-blurry")
    }

    // MARK: Video press (presets and dial only)

    func testVideoPressPresetChipsAndDial() throws {
        launch(screen: "press")
        XCTAssertTrue(app.buttons["Balanced"].waitForExistence(timeout: 20) || app.staticTexts["Balanced"].waitForExistence(timeout: 2),
                      "Preset labels missing")
        snap("30-press-initial")
        for preset in ["Balanced", "Smaller resolution", "Gentle"] {
            let chip = app.buttons.matching(NSPredicate(format: "label == %@", preset)).firstMatch
            if chip.exists { chip.tap() } else { app.staticTexts[preset].firstMatch.tap() }
            Thread.sleep(forTimeInterval: 0.6)
            snap("31-press-\(preset.replacingOccurrences(of: " ", with: "-").lowercased())")
        }
        let dial = app.otherElements["Preset dial"].firstMatch
        XCTAssertTrue(dial.waitForExistence(timeout: 5), "Preset dial not found by accessibility label")
        let center = dial.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 120, dy: 0)))
        Thread.sleep(forTimeInterval: 0.6)
        snap("32-press-after-dial-drag")
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: -240, dy: 0)))
        Thread.sleep(forTimeInterval: 0.6)
        snap("33-press-after-dial-drag-back")
    }

    func testPressShowsPickHintWhenNothingSelected() throws {
        launch(screen: "press")
        XCTAssertTrue(app.staticTexts["Pick videos below"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Pick at least one video"].exists)
        XCTAssertFalse(app.buttons["Review receipt"].exists)
    }

    // MARK: Receipt (sample only; the plan has photos only, so no video confirm exists here)

    func testReceiptNumbersAndRemoval() throws {
        launch(screen: "receipt")
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove'")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 20), "Remove button missing on receipt")
        snap("40-receipt")
        XCTAssertTrue(app.staticTexts["Lookalikes removed"].exists)
        XCTAssertTrue(app.staticTexts["Old screenshots removed"].exists)
        XCTAssertTrue(app.staticTexts["Favorites are never included"].exists)
        remove.tap()
        Thread.sleep(forTimeInterval: 2)
        snap("41-after-remove-tap")
    }

    // MARK: Dynamic Type XL

    func testWorkbenchAccessibilityXL() throws {
        launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        XCTAssertTrue(app.buttons["Calm mode"].waitForExistence(timeout: 20))
        snap("50-workbench-axl")
    }

    func testLightTableAccessibilityXL() throws {
        launch(screen: "lighttable", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        XCTAssertTrue(lightTableReady())
        snap("51-lighttable-axl")
        let width = app.windows.firstMatch.frame.width
        for label in ["Skip", "Keep all"] {
            let f = app.buttons[label].firstMatch.frame
            XCTAssertTrue(f.minX >= 0 && f.maxX <= width, "\(label) button exceeds the screen at AX XL: \(f)")
        }
    }

    // MARK: Helpers

    @discardableResult
    func scrollUntilVisible(_ element: XCUIElement, maxSwipes: Int = 12) -> Bool {
        var n = 0
        while !(element.exists && element.isHittable) && n < maxSwipes {
            app.swipeUp()
            n += 1
        }
        return element.exists
    }
}
