import ModelRuntime
import XCTest
@testable import ModelManagement

final class ModelFamilyResolverTests: XCTestCase {

    func testCatalogModelUsesDeclaredFamily() {
        let family = ModelFamilyResolver.family(
            forFilename: ModelContainer.defaultModelFilename,
            vocabSize: 999 // ignored for catalog entries
        )
        XCTAssertEqual(family, "qwen3-v151936")
    }

    func testGemmaCatalogEntryUsesGemmaFamily() {
        let gemma = RuntimeModelCatalog.models.first { $0.displayName == "Gemma 4 E2B" }
        let family = ModelFamilyResolver.family(forFilename: gemma!.filename, vocabSize: 1)
        XCTAssertEqual(family, RuntimeModelCatalog.gemmaFamily)
    }

    func testUnknownModelDerivesFamilyFromNameAndVocab() {
        let family = ModelFamilyResolver.family(forFilename: "My_Custom Model.Q4.gguf", vocabSize: 32000)
        XCTAssertEqual(family, "my-custom-model-q4-v32000")
    }

    func testDerivedFamilyIsDeterministic() {
        let a = ModelFamilyResolver.derivedFamily(forFilename: "foo.gguf", vocabSize: 100)
        let b = ModelFamilyResolver.derivedFamily(forFilename: "foo.gguf", vocabSize: 100)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "foo-v100")
    }

    func testDerivedFamilyCollapsesAndTrimsSeparators() {
        let family = ModelFamilyResolver.derivedFamily(forFilename: "--a__b--.gguf", vocabSize: 7)
        XCTAssertEqual(family, "a-b-v7")
    }
}
