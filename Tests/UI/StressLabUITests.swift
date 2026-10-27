import XCTest

final class StressLabUITests: XCTestCase {
    func testHealthNotificationSettingsExplainBackgroundAndOfferTest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["toolbar.settings"].waitForExistence(timeout: 10))
        app.buttons["toolbar.settings"].tap()
        for _ in 0..<3 where !app.switches["notifications.enabled"].exists { app.swipeUp() }
        XCTAssertTrue(app.switches["notifications.enabled"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["notifications.enabled"].isEnabled)
        XCTAssertFalse(app.switches["notifications.heartRate"].exists)
        XCTAssertTrue(app.switches["notifications.trend"].exists)
        XCTAssertFalse(app.switches["notifications.trend"].isEnabled)
        for _ in 0..<3 where !app.buttons["notifications.test"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["notifications.test"].exists)
        for _ in 0..<3 where !app.staticTexts["notifications.backgroundStatus"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["notifications.backgroundStatus"].exists)
    }

    func testLocalTestNotificationCanBeScheduledWithoutHealthData() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["toolbar.settings"].waitForExistence(timeout: 10))
        app.buttons["toolbar.settings"].tap()
        let button = app.buttons["notifications.test"]
        for _ in 0..<6 {
            if button.exists && button.frame.midY > 150 && button.frame.midY < app.frame.height - 150 { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 0.01,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50)))
        }
        XCTAssertTrue(button.isHittable)
        button.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemAlert = springboard.alerts.firstMatch
        let alert = systemAlert.waitForExistence(timeout: 3) ? systemAlert : app.alerts.firstMatch
        if alert.exists {
            let allow = alert.buttons.matching(NSPredicate(format: "label == 'Allow' OR label == '允许' OR label == '允许通知'")).firstMatch
            XCTAssertTrue(allow.exists)
            allow.tap()
        }
        for _ in 0..<3 where !app.staticTexts["notifications.deliveryStatus"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["notifications.deliveryStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["notifications.deliveryStatus"].label.contains("测试通知已安排"), app.debugDescription)
    }

    func testDemoMovingIntervalIsMarkedUnscored() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " ms")).firstMatch.waitForExistence(timeout: 20))
        app.buttons["dashboard.previousDay"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "个时间格已留空")).firstMatch.waitForExistence(timeout: 5))
    }

    func testPastDayReportReusesCachedSnapshotWhenSwitchingDates() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " ms")).firstMatch.waitForExistence(timeout: 20))
        app.buttons["dashboard.previousDay"].tap()
        XCTAssertTrue(app.staticTexts["report.cached"].waitForExistence(timeout: 20))
        let previousValue = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " ms")).firstMatch.label
        app.buttons["dashboard.nextDay"].tap()
        app.buttons["dashboard.previousDay"].tap()
        XCTAssertTrue(app.staticTexts["report.cached"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " ms")).firstMatch.label, previousValue)
    }

    func testV1DemoShowsRestingHeartRateInput() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " ms")).firstMatch.waitForExistence(timeout: 20))
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["静息心率"].waitForExistence(timeout: 5))
    }

    func testUnpairedSDNNIsExplainedWithoutInventingRMSSD() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let diagnostic = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "仅 SDNN")).firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 20))
        diagnostic.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "不能把 SDNN 直接换算为 RMSSD")).firstMatch.waitForExistence(timeout: 5))
    }

    func testTapHRVPointShowsPressureAssessment() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let point = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "hrv.point.")).firstMatch
        XCTAssertTrue(point.waitForExistence(timeout: 20))
        point.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "参考分")).firstMatch.waitForExistence(timeout: 5))
    }

    func testDemoRefreshKeepsChartsMounted() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let value = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " ms")).firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 20))
        let before = value.label
        let refresh = app.buttons["刷新"]
        XCTAssertTrue(refresh.exists)
        for _ in 0..<3 {
            refresh.tap()
            XCTAssertTrue(value.exists)
            XCTAssertEqual(value.label, before)
            XCTAssertFalse(app.staticTexts["当天没有可用 RMSSD"].exists)
        }
    }

    func testDemoDashboardAndParameters() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Stress Lab"].waitForExistence(timeout: 15))
        let measuredValue = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " ms")).firstMatch
        let rendered = measuredValue.waitForExistence(timeout: 20)
        if !rendered { print(app.debugDescription) }
        XCTAssertTrue(rendered, "Demo must calculate actual RMSSD, not merely show the card shell")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Stress Lab demo dashboard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["实时压力 · 实验模型"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "有效 ", " 格")).firstMatch.waitForExistence(timeout: 5))
        let pressureShot = XCTAttachment(screenshot: app.screenshot())
        pressureShot.name = "Stress Lab pressure dashboard"
        pressureShot.lifetime = .keepAlways
        add(pressureShot)
        let parameters = app.buttons["toolbar.parameters"]
        if !parameters.isHittable { app.swipeUp() }
        XCTAssertTrue(parameters.waitForExistence(timeout: 5))
        parameters.tap()
        XCTAssertTrue(app.buttons["parameters.apply"].waitForExistence(timeout: 5))
        app.buttons["parameters.apply"].tap()
        XCTAssertTrue(app.buttons["toolbar.settings"].waitForExistence(timeout: 10))
        app.buttons["toolbar.records"].tap()
        XCTAssertTrue(app.staticTexts["Apple SDNN"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
    }

    func testEmptyDoesNotInventChartMeasurements() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--empty-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Stress Lab"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["toolbar.settings"].exists)
        XCTAssertTrue(app.staticTexts["当天没有可用 RMSSD"].waitForExistence(timeout: 10))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["当天暂无可估算的压力时间格"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Stress Lab empty dashboard"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
