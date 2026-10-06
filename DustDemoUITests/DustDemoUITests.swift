import XCTest

final class DustDemoUITests: XCTestCase {
    @MainActor
    func testDeleteRestoreScrubAndReplay() {
        let app = XCUIApplication()
        app.launch()
        app.segmentedControls["modePicker"].buttons["删除消散"].tap()
        let play = app.buttons["playButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(play.isEnabled)
        XCTAssertEqual(play.label, "删除消息")
        play.tap()
        let finished = NSPredicate(format: "label == %@", "再次播放")
        expectation(for: finished, evaluatedWith: play)
        waitForExpectations(timeout: 6)
        app.buttons["resetButton"].tap()
        XCTAssertEqual(play.label, "删除消息")

        app.sliders["progressSlider"].adjust(toNormalizedSliderPosition: 0.35)
        XCTAssertEqual(play.label, "继续动画")
        XCTAssertEqual(app.staticTexts["playbackStatus"].label, "已暂停")
        app.buttons["四分之一慢速"].tap()
        play.tap()
        XCTAssertEqual(play.label, "暂停动画")
        play.tap()
        XCTAssertEqual(play.label, "继续动画")
        app.buttons["resetButton"].tap()
        XCTAssertEqual(app.staticTexts["progressValue"].label, "000%")
    }

    @MainActor
    func testTextToImageCompletesAndRestores() {
        let app = XCUIApplication()
        app.launch()
        let play = app.buttons["playButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertEqual(play.label, "文字化作图片")
        play.tap()
        expectation(for: NSPredicate(format: "label == %@", "再次播放"), evaluatedWith: play)
        waitForExpectations(timeout: 12)
        XCTAssertTrue(app.images["generatedArtwork"].exists)
        app.buttons["resetButton"].tap()
        XCTAssertEqual(play.label, "文字化作图片")
        XCTAssertEqual(app.staticTexts["progressValue"].label, "000%")
        app.sliders["progressSlider"].adjust(toNormalizedSliderPosition: 0.65)
        XCTAssertEqual(play.label, "继续动画")
        app.swipeDown()
        app.segmentedControls["modePicker"].buttons["删除消散"].tap()
        XCTAssertTrue(play.isEnabled)
        XCTAssertEqual(app.staticTexts["progressValue"].label, "000%")
        app.segmentedControls["modePicker"].buttons["文字 → 图片"].tap()
        XCTAssertTrue(play.isEnabled)
        XCTAssertEqual(play.label, "文字化作图片")
    }

    @MainActor
    func testLoadingStageCanBePausedScrubbedAndCompleted() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-progress", "0.4"]
        app.launch()
        XCTAssertTrue(app.staticTexts["loadingIndicator"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.images["generatedArtwork"].exists)
        XCTAssertEqual(app.staticTexts["playbackStatus"].label, "已暂停")
        app.sliders["progressSlider"].adjust(toNormalizedSliderPosition: 0.48)
        XCTAssertTrue(app.staticTexts["loadingIndicator"].exists)
        app.sliders["progressSlider"].adjust(toNormalizedSliderPosition: 0.7)
        XCTAssertFalse(app.staticTexts["loadingIndicator"].exists)
        app.sliders["progressSlider"].adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(app.images["generatedArtwork"].exists)
        app.buttons["resetButton"].tap()
        XCTAssertEqual(app.staticTexts["progressValue"].label, "000%")
        XCTAssertFalse(app.staticTexts["loadingIndicator"].exists)
    }
}
