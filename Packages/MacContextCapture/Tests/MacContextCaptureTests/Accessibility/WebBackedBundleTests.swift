//
//  WebBackedBundleTests.swift
//  MacContextCaptureTests
//
//  Whether an app is web-rendered decides how its text is replaced: a Chromium-backed app returns
//  `.success` from an `AXSelectedText` write and discards it (ADR-133), so those have to be
//  replaced by pasting instead. Getting the classification wrong is silent — the write reports
//  success and nothing changes.
//

import XCTest
@testable import MacContextCapture

final class WebBackedBundleTests: XCTestCase {
    private func bundle(containing relativePaths: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("web-backed-\(UUID().uuidString).app")
        for path in relativePaths {
            let full = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: full, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testChromiumForkIsWebBacked() throws {
        // Millie is `app.millie`: a Chromium build with no Electron markers and no entry in the
        // browser bundle-id list, so before this it was treated as a native app and its
        // replacements were written into an accessibility API that throws them away.
        let app = try bundle(containing: ["Contents/Frameworks/Chromium Framework.framework"])
        XCTAssertTrue(AppBundleWebAppClassifier.bundleContainsElectronMarkers(at: app))
    }

    func testElectronAppIsWebBacked() throws {
        let app = try bundle(containing: ["Contents/Frameworks/Electron Framework.framework"])
        XCTAssertTrue(AppBundleWebAppClassifier.bundleContainsElectronMarkers(at: app))
    }

    func testPlainNativeAppIsNot() throws {
        let app = try bundle(containing: ["Contents/Frameworks/CocoaUI.framework"])
        XCTAssertFalse(AppBundleWebAppClassifier.bundleContainsElectronMarkers(at: app))
    }
}
