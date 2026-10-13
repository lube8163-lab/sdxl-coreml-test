import XCTest

final class DeviceFlows: XCTestCase {
    @MainActor func testFirstDownload() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let welcome = app.buttons["welcome.continue"]
        if welcome.waitForExistence(timeout: 5) {
            attach(app, "onboarding")
            if !welcome.isHittable { app.swipeUp() }
            welcome.tap()
        }
        let start = app.buttons["model.download.start"]
        if start.waitForExistence(timeout: 5) {
            attach(app, "download-announcement")
            if !start.isHittable { app.swipeUp() }
            start.tap()
            let received = app.staticTexts["model.download.progress"]
            XCTAssertTrue(received.waitForExistence(timeout: 30))
            let amount = NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                let first = element.label.split(separator: "/").first ?? ""
                let digits = first.filter { "0123456789.".contains($0) }
                return (Double(digits) ?? 0) > 0
            }
            expectation(for: amount, evaluatedWith: received)
            waitForExpectations(timeout: 60)
            let pause = app.buttons["model.download.pause"]
            if !pause.isHittable { app.swipeUp() }
            pause.tap()
            XCTAssertTrue(start.waitForExistence(timeout: 30))
            attach(app, "download-paused")
            start.tap()
        }
        XCTAssertTrue(app.buttons["generation.generate"].waitForExistence(timeout: 3600))
        attach(app, "model-ready")
    }

    @MainActor func testGenerationDemo() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let generate = app.buttons["generation.generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 120))
        waitUntilEnabled(generate)
        app.buttons["settings.open"].tap()
        let manual = app.segmentedControls.buttons["固定値を使う"]
        for _ in 0..<6 where !manual.isHittable { app.swipeUp() }
        XCTAssertTrue(manual.exists)
        manual.tap()
        let seed = app.textFields["settings.manual-seed"]
        XCTAssertTrue(seed.waitForExistence(timeout: 5))
        if !seed.isHittable { app.swipeUp() }
        seed.tap(); seed.typeText("42")
        app.buttons["settings.close"].tap()
        let prompt = app.textViews["generation.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.tap()
        if let old = prompt.value as? String { prompt.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        prompt.typeText("A cinematic photo of a small robot walking in Tokyo at night, neon reflections, detailed.")
        attach(app, "prompt")
        generate.tap()
        XCTAssertTrue(app.staticTexts["生成完了"].waitForExistence(timeout: 120))
        attach(app, "checked-image")
    }
    @MainActor private func waitUntilEnabled(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: element)
        waitForExpectations(timeout: 120)
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
