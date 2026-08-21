import AppCompatibility
import AutocompleteCore
import XCTest
@testable import TextInsertion

final class TextReplacementTests: XCTestCase {
    private static let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

    private func context(target: AppTarget = TextReplacementTests.target) -> TextFieldContext {
        TextFieldContext(beforeCursor: "i beleive this", target: target)
    }

    // MARK: - Recording seams

    /// Ordered log of every synthesiser + pasteboard call, so tests can assert that the span was
    /// removed before the replacement was written — and by which mechanism.
    private final class Recorder: KeystrokeSynthesizing, CompletionPasteboard {
        var events: [String] = []
        func paste() { events.append("paste") }
        func pasteAndMatchStyle() { events.append("pasteAndMatchStyle") }
        func type(_ string: String) { events.append("type(\(string))") }
        func deleteBackward() { events.append("deleteBackward") }
        func selectBackward(count: Int) { events.append("selectBackward(\(count))") }
        func save() { events.append("save") }
        func write(_ string: String) { events.append("write(\(string))") }
        func restore() { events.append("restore") }
    }

    @MainActor
    private final class StubSpanReplacer: CaretSpanReplacing {
        var succeeds: Bool
        var calls: [(CaretSpan, String)] = []

        init(succeeds: Bool) { self.succeeds = succeeds }

        func replaceBehindCaret(_ span: CaretSpan, with replacement: String) -> Bool {
            calls.append((span, replacement))
            return succeeds
        }
    }

    private func makeReplacer(
        _ recorder: Recorder,
        spanReplacer: (any CaretSpanReplacing)? = nil,
        planner: ReplacementPlanner = ReplacementPlanner()
    ) -> PasteboardTextReplacer {
        PasteboardTextReplacer(
            planner: planner,
            inserter: PasteboardCompletionInserter(
                synthesizer: recorder,
                pasteboard: recorder,
                restoreDelayNanoseconds: 0
            ),
            synthesizer: recorder,
            spanReplacer: spanReplacer,
            settleDelayNanoseconds: 0
        )
    }

    // MARK: - CaretSpan

    func testTrailingSpanResolvesFromTextBeforeCaret() {
        let span = CaretSpan.trailing(of: "i beleive this", keystrokeLength: 4)
        XCTAssertEqual(span?.original, "this")
    }

    func testTrailingSpanRefusesWhenTextIsShorterThanRequested() {
        XCTAssertNil(CaretSpan.trailing(of: "hi", keystrokeLength: 5))
        XCTAssertNil(CaretSpan.trailing(of: "hi", keystrokeLength: 0))
    }

    /// The two counts genuinely differ for non-BMP text: AX addresses UTF-16 units, one arrow
    /// keystroke moves one grapheme. Conflating them eats or spares characters.
    func testSpanLengthsDivergeForMultiUnitGraphemes() {
        let span = CaretSpan(original: "ok 👍🏽")
        XCTAssertEqual(span.keystrokeLength, 4)
        XCTAssertEqual(span.utf16Length, 7)
    }

    // MARK: - Planner

    func testPlannerDefaultsToShiftArrowFallback() {
        let plan = ReplacementPlanner().plan(
            span: CaretSpan(original: "beleive"),
            replacement: "believe",
            context: context()
        )
        XCTAssertEqual(plan.keystrokeFallback, .shiftArrowSelection)
        XCTAssertEqual(plan.write.text, "believe")
    }

    /// Replacement types its text rather than pasting it. A paste after a long selection run loses a
    /// race with the clipboard restore and inserts whatever the user had copied earlier.
    func testPlannerWritesByInjectionNotThePasteboard() {
        let plan = ReplacementPlanner().plan(
            span: CaretSpan(original: "beleive"),
            replacement: "believe",
            context: context()
        )
        guard case .chunkedStringInjection = plan.write.strategy else {
            return XCTFail("expected injection, got \(plan.write.strategy)")
        }
        XCTAssertFalse(plan.write.restorePasteboard, "nothing was written to the pasteboard")
    }

    /// The one app-driven exception: match-style pasting exists because plain insertion carries the
    /// wrong styling, and wrong styling is visible where a clipboard race is merely baffling.
    func testMatchStylePastingIsPreserved() {
        let store = AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: Self.target.bundleIdentifier, requiresPasteAndMatchStyle: true)
        ])
        let plan = ReplacementPlanner(
            insertionPlanner: InsertionPlanner(compatibilityStore: store),
            compatibilityStore: store
        ).plan(span: CaretSpan(original: "beleive"), replacement: "believe", context: context())

        XCTAssertEqual(plan.write.strategy, .pasteAndMatchStyle)
    }

    // MARK: - Settle timing

    /// A sentence-length span is hundreds of synthesized events; the app must drain them before the
    /// replacement is written or it lands in the wrong place.
    func testSettleDelayScalesWithTheSelectionLength() {
        let short = PasteboardTextReplacer.settleDelay(base: 12_000_000, keystrokes: 7)
        let long = PasteboardTextReplacer.settleDelay(base: 12_000_000, keystrokes: 200)
        XCTAssertGreaterThan(long, short)
        XCTAssertGreaterThan(long, 100_000_000, "200 keystrokes need well over 100ms to drain")
    }

    func testSettleDelayHandlesAnEmptySpan() {
        XCTAssertEqual(PasteboardTextReplacer.settleDelay(base: 0, keystrokes: 0), 0)
    }

    /// Apps that need chunked injection also mishandle a synthesized shift-selection, so the span
    /// is deleted outright instead.
    func testPlannerPrefersDeletionWhereInjectionIsChunked() {
        let store = AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: Self.target.bundleIdentifier, stringInjectionChunkSize: 2)
        ])
        let planner = ReplacementPlanner(
            insertionPlanner: InsertionPlanner(compatibilityStore: store),
            compatibilityStore: store
        )
        let plan = planner.plan(span: CaretSpan(original: "beleive"), replacement: "believe", context: context())
        XCTAssertEqual(plan.keystrokeFallback, .backspaceDeletion)
    }

    // MARK: - Actionability

    func testPlanIsNotActionableWhenNothingWouldChange() {
        let plan = ReplacementPlan(span: CaretSpan(original: "believe"), write: InsertionPlan(text: "believe"))
        XCTAssertFalse(plan.isActionable)
    }

    func testPlanIsNotActionableWhenSpanOrReplacementIsEmpty() {
        XCTAssertFalse(ReplacementPlan(span: CaretSpan(original: ""), write: InsertionPlan(text: "x")).isActionable)
        XCTAssertFalse(ReplacementPlan(span: CaretSpan(original: "x"), write: InsertionPlan(text: "")).isActionable)
    }

    func testPlanIsNotActionableBeyondTheKeystrokeBound() {
        let span = CaretSpan(original: String(repeating: "a", count: maximumReplacementKeystrokes + 1))
        XCTAssertFalse(ReplacementPlan(span: span, write: InsertionPlan(text: "short")).isActionable)
    }

    func testSkippedPlanTouchesNothing() async throws {
        let recorder = Recorder()
        let outcome = try await makeReplacer(recorder).replace(
            plan: ReplacementPlan(span: CaretSpan(original: "same"), write: InsertionPlan(text: "same"))
        )
        XCTAssertEqual(outcome, .skipped)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    // MARK: - Mechanism ladder

    func testAccessibilityWriteWinsAndFiresNoKeystrokes() async throws {
        let recorder = Recorder()
        let spanReplacer = await StubSpanReplacer(succeeds: true)
        let plan = ReplacementPlan(span: CaretSpan(original: "beleive"), write: InsertionPlan(text: "believe"))

        let outcome = try await makeReplacer(recorder, spanReplacer: spanReplacer).replace(plan: plan)

        XCTAssertEqual(outcome, .applied(.accessibilitySelectedText))
        XCTAssertTrue(recorder.events.isEmpty, "AX path must not synthesize keystrokes or touch the pasteboard")
        let calls = await spanReplacer.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0.original, "beleive")
        XCTAssertEqual(calls.first?.1, "believe")
    }

    func testRefusedAccessibilityWriteFallsBackToShiftSelection() async throws {
        let recorder = Recorder()
        let spanReplacer = await StubSpanReplacer(succeeds: false)
        let plan = ReplacementPlan(
            span: CaretSpan(original: "beleive"),
            keystrokeFallback: .shiftArrowSelection,
            write: InsertionPlan(text: "believe", strategy: .chunkedStringInjection(size: 24), restorePasteboard: false)
        )

        let outcome = try await makeReplacer(recorder, spanReplacer: spanReplacer).replace(plan: plan)

        XCTAssertEqual(outcome, .applied(.shiftArrowSelection))
        XCTAssertEqual(recorder.events, ["selectBackward(7)", "type(believe)"])
        XCTAssertFalse(
            recorder.events.contains { $0 == "save" || $0 == "restore" },
            "the clipboard must not be involved — that race is the bug this replaced"
        )
    }

    func testDeletionFallbackRemovesSpanOneKeystrokePerGrapheme() async throws {
        let recorder = Recorder()
        let plan = ReplacementPlan(
            span: CaretSpan(original: "cat"),
            keystrokeFallback: .backspaceDeletion,
            write: InsertionPlan(text: "dog", strategy: .chunkedStringInjection(size: 24), restorePasteboard: false)
        )

        let outcome = try await makeReplacer(recorder).replace(plan: plan)

        XCTAssertEqual(outcome, .applied(.backspaceDeletion))
        XCTAssertEqual(recorder.events, [
            "deleteBackward", "deleteBackward", "deleteBackward", "type(dog)"
        ])
    }

    /// Guards the one-keystroke-mechanism rule: with no AX seam available, a plan naming the AX
    /// mechanism as its fallback must skip rather than write over text it never removed.
    func testAccessibilityFallbackWithoutSeamSkipsRatherThanAppending() async throws {
        let recorder = Recorder()
        let plan = ReplacementPlan(
            span: CaretSpan(original: "cat"),
            keystrokeFallback: .accessibilitySelectedText,
            write: InsertionPlan(text: "dog")
        )

        let outcome = try await makeReplacer(recorder).replace(plan: plan)

        XCTAssertEqual(outcome, .skipped)
        XCTAssertTrue(recorder.events.isEmpty, "nothing was removed, so nothing may be written")
    }

    func testShiftSelectionInheritsPerAppInsertionQuirks() async throws {
        let recorder = Recorder()
        let plan = ReplacementPlan(
            span: CaretSpan(original: "beleive"),
            keystrokeFallback: .shiftArrowSelection,
            write: InsertionPlan(text: "believe", strategy: .pasteAndMatchStyle)
        )

        _ = try await makeReplacer(recorder).replace(plan: plan)

        XCTAssertEqual(recorder.events, [
            "selectBackward(7)", "save", "write(believe)", "pasteAndMatchStyle", "restore"
        ])
    }
}
