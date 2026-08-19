import XCTest
@testable import ModelManagement

final class ModelDownloadStateTests: XCTestCase {
    func testDownloadingExposesProgressAndPercentText() throws {
        let state = ModelDownloadState.downloading(progress: 0.42)
        XCTAssertTrue(state.isDownloading)
        XCTAssertFalse(state.isPaused)
        XCTAssertEqual(try XCTUnwrap(state.progressFraction), 0.42, accuracy: 0.0001)
        XCTAssertEqual(state.statusText, "Downloading 42%")
    }

    func testPausedExposesProgressAndPercentText() throws {
        let state = ModelDownloadState.paused(progress: 0.6)
        XCTAssertTrue(state.isPaused)
        XCTAssertFalse(state.isDownloading)
        XCTAssertEqual(try XCTUnwrap(state.progressFraction), 0.6, accuracy: 0.0001)
        XCTAssertEqual(state.statusText, "Paused at 60%")
    }

    func testPausedWithoutProgressFallsBackToIndeterminate() {
        let state = ModelDownloadState.paused(progress: nil)
        XCTAssertTrue(state.isPaused)
        XCTAssertNil(state.progressFraction)
        XCTAssertEqual(state.statusText, "Paused")
    }

    func testProgressFractionIsClampedToUnitRange() {
        XCTAssertEqual(ModelDownloadState.downloading(progress: 1.5).progressFraction, 1)
        XCTAssertEqual(ModelDownloadState.paused(progress: -0.2).progressFraction, 0)
    }

    func testNonProgressStatesHaveNoProgressFraction() {
        XCTAssertNil(ModelDownloadState.idle.progressFraction)
        XCTAssertNil(ModelDownloadState.downloaded.progressFraction)
        XCTAssertNil(ModelDownloadState.failed("boom").progressFraction)
    }
}
