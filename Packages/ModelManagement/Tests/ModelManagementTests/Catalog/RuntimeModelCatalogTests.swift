import ModelRuntime
import XCTest
@testable import ModelManagement

final class RuntimeModelCatalogTests: XCTestCase {

    func testCatalogHasFiveBaseModels() {
        XCTAssertEqual(RuntimeModelCatalog.models.count, 5)
    }

    func testFilenamesAreUnique() {
        let filenames = RuntimeModelCatalog.models.map(\.filename)
        XCTAssertEqual(Set(filenames).count, filenames.count)
    }

    func testEveryGgufFilenameEndsInGguf() {
        for model in RuntimeModelCatalog.models {
            XCTAssertTrue(model.filename.lowercased().hasSuffix(".gguf"), "\(model.filename)")
        }
    }

    func testRecommendedMatchesContainerDefault() {
        XCTAssertEqual(RuntimeModelCatalog.recommended.filename, ModelContainer.defaultModelFilename)
    }

    func testDefaultModelKeepsLegacyQwenFamily() {
        // An ACPF profile already on disk for the default model must keep loading without a rebuild,
        // so its family must equal the value the pipeline historically hardcoded.
        let model = RuntimeModelCatalog.model(forFilename: ModelContainer.defaultModelFilename)
        XCTAssertEqual(model?.tokenizerFamily, "qwen3-v151936")
    }

    func testUnverifiedEntriesAreNotDownloadable() {
        for model in RuntimeModelCatalog.models where model.downloadURL == nil {
            XCTAssertFalse(model.isDownloadable)
            XCTAssertNotNil(model.unavailableReason)
        }
    }
}
