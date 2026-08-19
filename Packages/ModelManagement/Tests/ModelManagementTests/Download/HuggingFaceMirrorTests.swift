import Foundation
import XCTest
@testable import ModelManagement

final class HuggingFaceMirrorTests: XCTestCase {

    func testRewritesHuggingFaceHostToMirrorPreservingPath() throws {
        let url = URL(string: "https://huggingface.co/org/repo/resolve/main/model.gguf?download=true")!
        let mirror = HuggingFaceMirror.mirrorURL(for: url)
        XCTAssertEqual(
            mirror?.absoluteString,
            "https://hf-mirror.com/org/repo/resolve/main/model.gguf?download=true"
        )
    }

    func testRewritesWwwHost() throws {
        let url = URL(string: "https://www.huggingface.co/a/b.gguf")!
        XCTAssertEqual(HuggingFaceMirror.mirrorURL(for: url)?.host, "hf-mirror.com")
    }

    func testNonHuggingFaceURLHasNoMirror() throws {
        let url = URL(string: "https://example.com/model.gguf")!
        XCTAssertNil(HuggingFaceMirror.mirrorURL(for: url))
    }

    func testUnreachableHostErrorsAreRetriable() {
        for code in [NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorTimedOut,
                     NSURLErrorNotConnectedToInternet, NSURLErrorDNSLookupFailed] {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            XCTAssertTrue(HuggingFaceMirror.isUnreachableHostError(error), "code \(code)")
        }
    }

    func testHTTPStatusAndCancelAreNotRetriable() {
        XCTAssertFalse(HuggingFaceMirror.isUnreachableHostError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        ))
        XCTAssertFalse(HuggingFaceMirror.isUnreachableHostError(
            ModelDownloadManager.DownloadError.badStatus(404)
        ))
    }
}
