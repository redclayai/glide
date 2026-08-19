import Foundation
import XCTest
@testable import ModelManagement

final class DownloadOutcomeClassifierTests: XCTestCase {

    func testCancellationErrorIsUserCancel() {
        XCTAssertTrue(DownloadOutcomeClassifier.isUserCancellation(CancellationError()))
    }

    func testURLCancelledIsUserCancel() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertTrue(DownloadOutcomeClassifier.isUserCancellation(error))
    }

    func testCocoaUserCancelledIsUserCancel() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        XCTAssertTrue(DownloadOutcomeClassifier.isUserCancellation(error))
    }

    func testTimeoutIsNotUserCancel() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertFalse(DownloadOutcomeClassifier.isUserCancellation(error))
    }
}
