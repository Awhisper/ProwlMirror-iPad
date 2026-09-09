import XCTest

final class ProwlMirror_iPadUITests: XCTestCase {
  @MainActor
  func testPaneSwitchRestoresLiveReadingPosition() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture", "--mirror-ui-multiple-fixtures"]
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: nil)
    waitForExpectations(timeout: 10)
    let reading = app.scrollViews["mirror-live-scroll"]
    XCTAssertTrue(reading.waitForExistence(timeout: 10))
    reading.swipeDown()
    let rows = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Live marker "))
    guard
      let anchor = rows.allElementsBoundByIndex.first(where: {
        $0.isHittable && $0.frame.minY > reading.frame.minY + 20
          && $0.frame.maxY < reading.frame.maxY
      })
    else {
      XCTFail("No visible live anchor")
      return
    }
    let label = anchor.label
    let y = anchor.frame.minY
    app.staticTexts["Second Fixture"].tap()
    XCTAssertTrue(app.navigationBars["Second Fixture · Codex"].waitForExistence(timeout: 5))
    app.staticTexts["UI Fixture"].tap()
    let restored = app.staticTexts[label]
    expectation(
      for: NSPredicate { _, _ in
        restored.exists && restored.isHittable && abs(restored.frame.minY - y) < 12
      }, evaluatedWith: nil)
    waitForExpectations(timeout: 5)
  }

  @MainActor
  func testPaneSwitchRestoresHistoryReadingPosition() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture", "--mirror-ui-multiple-fixtures"]
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: nil)
    waitForExpectations(timeout: 10)
    XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 10))
    app.buttons["History"].tap()
    XCTAssertTrue(app.staticTexts["Loaded lines 202–401"].waitForExistence(timeout: 5))
    let history = app.scrollViews["mirror-history-scroll"]
    history.swipeUp()
    let rows = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Retained line "))
    guard
      let anchor = rows.allElementsBoundByIndex.first(where: {
        $0.isHittable && $0.frame.minY > history.frame.minY + 20
          && $0.frame.maxY < history.frame.maxY
      })
    else {
      XCTFail("No visible history anchor")
      return
    }
    let label = anchor.label
    let y = anchor.frame.minY
    app.staticTexts["Second Fixture"].tap()
    XCTAssertTrue(app.navigationBars["Second Fixture · Codex"].waitForExistence(timeout: 5))
    app.staticTexts["UI Fixture"].tap()
    XCTAssertTrue(app.buttons["Live Output"].waitForExistence(timeout: 5))
    let restored = app.staticTexts[label]
    expectation(
      for: NSPredicate { _, _ in
        restored.exists && restored.isHittable && abs(restored.frame.minY - y) < 12
      }, evaluatedWith: nil)
    waitForExpectations(timeout: 5)
  }

  @MainActor
  func testMultilineDraftRequiresExplicitSend() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture"]
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    let wide = NSPredicate { _, _ in app.frame.width > app.frame.height }
    expectation(for: wide, evaluatedWith: nil)
    waitForExpectations(timeout: 10)
    let input = app.descendants(matching: .any).matching(identifier: "mirror-message-input")
      .firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    input.typeText("First line\nSecond line")
    XCTAssertFalse(app.staticTexts["Fixture message delivered"].exists)
    XCTAssertTrue(app.buttons["Send"].isEnabled)
    app.buttons["Send"].tap()
    XCTAssertTrue(app.staticTexts["Fixture message delivered"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Send"].isEnabled)
  }

  @MainActor
  func testReadingHistoryDetailsAndConnectionEditing() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture"]
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    let wide = NSPredicate { _, _ in app.frame.width > app.frame.height }
    expectation(for: wide, evaluatedWith: nil)
    waitForExpectations(timeout: 10)
    XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 10))
    let live = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    live.name = "Fixture live reading"
    live.lifetime = .keepAlways
    add(live)
    app.buttons["Expand"].firstMatch.tap()
    XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
    let detail = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    detail.name = "Fixture frozen code detail"
    detail.lifetime = .keepAlways
    add(detail)
    app.buttons["Done"].tap()
    app.buttons["History"].tap()
    XCTAssertTrue(app.staticTexts["Loaded lines 202–401"].waitForExistence(timeout: 5))
    app.buttons["Load Earlier 200 Lines"].tap()
    XCTAssertTrue(app.staticTexts["Loaded lines 2–401"].waitForExistence(timeout: 5))
    let history = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    history.name = "Fixture history paging"
    history.lifetime = .keepAlways
    add(history)
    app.buttons["Live Output"].tap()
    XCTAssertTrue(app.buttons["Expand"].firstMatch.waitForExistence(timeout: 5))
    app.buttons["Edit Connection"].tap()
    let key = app.secureTextFields["Pairing Key"]
    XCTAssertTrue(key.waitForExistence(timeout: 5))
    key.tap()
    key.typeText("x")
    app.buttons["Reconnect"].tap()
    XCTAssertTrue(
      app.staticTexts["Paste the 64-character pairing key shown on the Host."].waitForExistence(
        timeout: 5))
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testConnectionFormRemainsUsableAcrossRotation() {
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    let wide = NSPredicate { _, _ in app.frame.width > app.frame.height }
    expectation(for: wide, evaluatedWith: nil)
    waitForExpectations(timeout: 10)
    let addButton = app.buttons["add-remote-pane"]
    XCTAssertTrue(addButton.waitForExistence(timeout: 10))
    XCTAssertTrue(addButton.isHittable)
    addButton.tap()
    let address = app.textFields["host-address"]
    XCTAssertTrue(address.waitForExistence(timeout: 5))
    XCTAssertTrue(address.isHittable)
    XCTAssertFalse(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Unable to access saved"))
        .firstMatch.exists)
    let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    landscape.name = "Landscape connection form"
    landscape.lifetime = .keepAlways
    add(landscape)
    XCUIDevice.shared.orientation = .portrait
    let tall = NSPredicate { _, _ in app.frame.height > app.frame.width }
    expectation(for: tall, evaluatedWith: nil)
    waitForExpectations(timeout: 10)
    XCTAssertTrue(address.waitForExistence(timeout: 5))
    XCTAssertTrue(address.isHittable)
    let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    portrait.name = "Portrait connection form"
    portrait.lifetime = .keepAlways
    add(portrait)
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.buttons["add-remote-pane"].waitForExistence(timeout: 5))
  }
}
