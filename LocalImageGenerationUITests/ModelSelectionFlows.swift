import XCTest

/// Run sequentially on a development installation; downloads real public packages.
final class ModelSelectionFlows: XCTestCase {
    @MainActor func test01LegacyModelDownloadAndGeneration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let welcome = app.buttons["welcome.continue"]
        if welcome.waitForExistence(timeout: 5) { reveal(welcome, in: app); attach(app, "model-onboarding"); welcome.tap() }
        finishDownload(in: app, pauseAndRelaunch: true)
        waitReady(in: app)
        XCTAssertEqual(app.staticTexts["model.current"].label, "FLUX.2 Klein 4B")
        XCTAssertFalse(app.segmentedControls["generation.steps"].exists)
        attach(app, "flux2-generation-controls")
        openLibrary(in: app)
        attach(app, "two-model-library")
        app.buttons["model.library.close"].tap()
        setSeed42(in: app)
        let example = app.buttons["prompt.example.stillLife"]
        reveal(example, in: app); example.tap()
        generate(in: app, model: "FLUX.2 Klein 4B", steps: 4)
    }

    @MainActor func test02Flux3DownloadAndVariableSteps() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["model.manage"].waitForExistence(timeout: 180))
        waitReady(in: app)
        if app.staticTexts["model.current"].label != "FLUX.3 Image Klein" {
            openLibrary(in: app)
            let choose = app.buttons["model.select.flux3-klein"]
            reveal(choose, in: app); choose.tap()
        }
        finishDownload(in: app, pauseAndRelaunch: true)
        waitReady(in: app)
        XCTAssertEqual(app.staticTexts["model.current"].label, "FLUX.3 Image Klein")
        XCTAssertTrue(app.segmentedControls["generation.steps"].exists)
        attach(app, "flux3-generation-controls")
        setSeed42(in: app)
        let prompt = app.textViews["generation.prompt"]
        reveal(prompt, in: app, towardTop: true)
        prompt.tap()
        if let previous = prompt.value as? String { prompt.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count)) }
        prompt.typeText("A watercolor painting of a red lighthouse standing on a grassy cliff above a calm blue sea. A small white sailboat is visible on the right. Warm afternoon sunlight comes from the left. Soft textured paper, delicate brush strokes, clear simple composition, no people, no text.")
        if app.toolbars.buttons["閉じる"].exists { app.toolbars.buttons["閉じる"].tap() }
        for (steps, title) in [(4, "高速 4"), (8, "標準 8"), (16, "じっくり 16")] {
            let picker = app.segmentedControls["generation.steps"]
            reveal(picker, in: app, towardTop: true)
            picker.buttons[title].tap()
            generate(in: app, model: "FLUX.3 Image Klein", steps: steps)
        }
        // Settings changes must not relabel the previous, already approved image.
        reveal(app.segmentedControls["generation.steps"], in: app, towardTop: true)
        app.segmentedControls["generation.steps"].buttons["高速 4"].tap()
        let previous = app.staticTexts["FLUX.3 Image Klein / 512×512 / 16ステップ"]
        reveal(previous, in: app)
        XCTAssertTrue(previous.exists)
        attach(app, "result-metadata-retained")
    }

    @MainActor func test03SafetyCancellationAndSwitchBack() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        waitReady(in: app)
        XCTAssertEqual(app.staticTexts["model.current"].label, "FLUX.3 Image Klein")
        let example = app.buttons["prompt.example.stillLife"]
        reveal(example, in: app); example.tap()
        generate(in: app, model: "FLUX.3 Image Klein", steps: 4)
        let prompt = app.textViews["generation.prompt"]
        reveal(prompt, in: app, towardTop: true); prompt.tap()
        if let old = prompt.value as? String { prompt.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        prompt.typeText("nude adult portrait")
        if app.toolbars.buttons["閉じる"].exists { app.toolbars.buttons["閉じる"].tap() }
        let button = app.buttons["generation.generate"]
        reveal(button, in: app); button.tap()
        XCTAssertTrue(app.staticTexts["この内容では生成できません"].waitForExistence(timeout: 10))
        reveal(app.images["result.image"], in: app)
        XCTAssertTrue(app.images["result.image"].exists)
        attach(app, "blocked-prompt-retains-approved-image")
        reveal(example, in: app, towardTop: true); example.tap()
        reveal(button, in: app); button.tap()
        let cancel = app.buttons["generation.cancel"]
        reveal(cancel, in: app); cancel.tap()
        XCTAssertTrue(app.staticTexts["生成を中断しました"].waitForExistence(timeout: 90))
        XCTAssertTrue(app.images["result.image"].exists)
        attach(app, "cancellation-retains-approved-image")
        openLibrary(in: app)
        let choose = app.buttons["model.select.flux2-klein-4b"]
        reveal(choose, in: app, towardTop: true); choose.tap()
        waitReady(in: app)
        XCTAssertEqual(app.staticTexts["model.current"].label, "FLUX.2 Klein 4B")
        XCTAssertFalse(app.segmentedControls["generation.steps"].exists)
        let previous = app.staticTexts["FLUX.3 Image Klein / 512×512 / 4ステップ"]
        reveal(previous, in: app)
        XCTAssertTrue(previous.exists)
        attach(app, "switch-back-preserves-image-provenance")
        openLibrary(in: app)
        let delete = app.buttons["model.delete.flux3-klein"]
        reveal(delete, in: app); delete.tap()
        XCTAssertTrue(app.buttons["キャンセル"].waitForExistence(timeout: 5))
        app.buttons["キャンセル"].tap()
        app.buttons["model.library.close"].tap()
        openLibrary(in: app)
        let restore = app.buttons["model.select.flux3-klein"]
        reveal(restore, in: app); restore.tap()
        waitReady(in: app)
        XCTAssertEqual(app.staticTexts["model.current"].label, "FLUX.3 Image Klein")
    }

    @MainActor private func finishDownload(in app: XCUIApplication, pauseAndRelaunch: Bool) {
        let start = app.buttons["model.download.start"]
        guard start.waitForExistence(timeout: 8) else { return }
        reveal(start, in: app); attach(app, "model-download-details"); start.tap()
        if pauseAndRelaunch {
            let progress = app.staticTexts["model.download.progress"]
            XCTAssertTrue(app.buttons["model.download.pause"].waitForExistence(timeout: 30))
            reveal(progress, in: app)
            let received = NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                let amount = element.label.split(separator: "/").first ?? ""
                return (Double(amount.filter { "0123456789.".contains($0) }) ?? 0) > 1
            }
            expectation(for: received, evaluatedWith: progress); waitForExpectations(timeout: 90)
            let pause = app.buttons["model.download.pause"]
            reveal(pause, in: app); pause.tap()
            XCTAssertTrue(start.waitForExistence(timeout: 30))
            attach(app, "model-download-paused")
            app.terminate(); app.launch()
            XCTAssertTrue(start.waitForExistence(timeout: 30))
            XCTAssertEqual(start.label, "ダウンロードを再開")
            reveal(start, in: app); start.tap()
        }
        XCTAssertTrue(app.staticTexts["model.current"].waitForExistence(timeout: 3600))
    }

    @MainActor private func waitReady(in app: XCUIApplication) {
        let button = app.buttons["generation.generate"]
        XCTAssertTrue(app.staticTexts["model.current"].waitForExistence(timeout: 180))
        reveal(button, in: app)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button)
        waitForExpectations(timeout: 600)
        reveal(app.buttons["model.manage"], in: app, towardTop: true)
    }
    @MainActor private func setSeed42(in app: XCUIApplication) {
        app.buttons["settings.open"].tap()
        let manual = app.segmentedControls.buttons["固定値を使う"]
        reveal(manual, in: app); manual.tap()
        let seed = app.textFields["settings.manual-seed"]
        reveal(seed, in: app); seed.tap()
        if let old = seed.value as? String, UInt32(old) != nil { seed.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        seed.typeText("42")
        app.buttons["settings.close"].tap()
    }
    @MainActor private func generate(in app: XCUIApplication, model: String, steps: Int) {
        let button = app.buttons["generation.generate"]
        reveal(button, in: app); button.tap()
        let cancel = app.buttons["generation.cancel"]
        reveal(cancel, in: app)
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 600))
        let metadata = app.staticTexts["\(model) / 512×512 / \(steps)ステップ"]
        if !metadata.exists {
            let details = app.buttons.matching(identifier: "result.details")
                .matching(NSPredicate(format: "label == %@", "この画像の生成情報")).firstMatch
            reveal(details, in: app); details.tap()
        }
        reveal(metadata, in: app)
        XCTAssertEqual(metadata.label, "\(model) / 512×512 / \(steps)ステップ")
        attach(app, model + "-\(steps)-steps-information")
        reveal(app.images["result.image"], in: app, towardTop: true)
        attach(app, model + "-\(steps)-steps-checked-image")
    }
    @MainActor private func openLibrary(in app: XCUIApplication) {
        let button = app.buttons["model.manage"]
        reveal(button, in: app, towardTop: true); button.tap()
        XCTAssertTrue(app.buttons["model.library.close"].waitForExistence(timeout: 5))
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<12 where !element.isHittable { if towardTop { app.swipeDown() } else { app.swipeUp() } }
        XCTAssertTrue(element.isHittable, "Control is not reachable: \(element)")
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
