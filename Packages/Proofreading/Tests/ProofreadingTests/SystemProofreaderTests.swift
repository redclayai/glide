import AppKit
import AutocompleteCore
import XCTest
@testable import Proofreading

final class SystemProofreaderTests: XCTestCase {
    private static let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

    private func context(_ beforeCursor: String, traits: TextFieldTraits = TextFieldTraits()) -> TextFieldContext {
        TextFieldContext(beforeCursor: beforeCursor, target: Self.target, traits: traits)
    }

    // MARK: - Correction acceptance gates

    func testRejectsIdenticalOrEmptyCorrection() {
        XCTAssertFalse(SystemProofreader.isAcceptable(candidate: "believe", for: "believe"))
        XCTAssertFalse(SystemProofreader.isAcceptable(candidate: "", for: "believe"))
    }

    /// A correction that introduces a space would split the word and move the caret in ways the
    /// replacement mechanisms don't model.
    func testRejectsMultiWordCorrection() {
        XCTAssertFalse(SystemProofreader.isAcceptable(candidate: "a lot", for: "alot"))
    }

    /// Nobody wants an assistant fighting their lowercase style.
    func testRejectsBareCaseFlip() {
        XCTAssertFalse(SystemProofreader.isAcceptable(candidate: "I", for: "i"))
        XCTAssertFalse(SystemProofreader.isAcceptable(candidate: "Monday", for: "monday"))
    }

    func testAcceptsGenuineSpellingFix() {
        XCTAssertTrue(SystemProofreader.isAcceptable(candidate: "believe", for: "beleive"))
    }

    // MARK: - Sentence window

    func testEnclosingSentenceStopsAtPreviousTerminator() {
        let sentence = SystemProofreader.enclosingSentence(of: "First thought. i beleive ")
        XCTAssertEqual(sentence, " i beleive ")
    }

    func testEnclosingSentenceKeepsWholeWindowWithoutTerminator() {
        let sentence = SystemProofreader.enclosingSentence(of: "i beleive ")
        XCTAssertEqual(sentence, "i beleive ")
    }

    func testEnclosingSentenceIsBounded() {
        let long = String(repeating: "word ", count: 200)
        XCTAssertLessThanOrEqual(SystemProofreader.enclosingSentence(of: long).count, 240)
    }

    // MARK: - Suppression

    @MainActor
    func testNeverProofreadsSecureFields() async {
        let proofreader = SystemProofreader()
        let secure = context("recieve ", traits: TextFieldTraits(isSecureTextEntry: true))
        let password = context("recieve ", traits: TextFieldTraits(isPasswordField: true))

        let secureSuggestion = await proofreader.suggestion(for: secure)
        let passwordSuggestion = await proofreader.suggestion(for: password)

        XCTAssertNil(secureSuggestion)
        XCTAssertNil(passwordSuggestion)
    }

    @MainActor
    func testProducesNothingMidWord() async {
        let suggestion = await SystemProofreader().suggestion(for: context("i reciev"))
        XCTAssertNil(suggestion)
    }

    @MainActor
    func testCorrectlySpelledTextProducesNothing() async {
        let suggestion = await SystemProofreader().suggestion(for: context("i receive "))
        XCTAssertNil(suggestion)
    }

    // MARK: - Integration with the system checker

    /// Exercises the real `NSSpellChecker`. Its dictionaries are environment-dependent, so the test
    /// skips rather than fails when the host doesn't flag the misspelling — but when a suggestion
    /// *is* produced, its shape is asserted strictly.
    @MainActor
    func testSpanAndReplacementShapeOnRealMisspelling() async throws {
        let beforeCursor = "i recieve "
        let suggestion = await SystemProofreader().suggestion(for: context(beforeCursor))

        guard let suggestion else {
            throw XCTSkip("Host NSSpellChecker did not flag 'recieve'; nothing to assert.")
        }

        XCTAssertEqual(suggestion.origin, .proofreader)
        XCTAssertEqual(suggestion.span.original, "recieve ")
        XCTAssertTrue(suggestion.replacement.hasSuffix(" "), "boundary must be carried through")
        XCTAssertTrue(suggestion.isMeaningful)
        XCTAssertTrue(
            beforeCursor.hasSuffix(suggestion.span.original),
            "span must end exactly at the caret"
        )
    }
}
