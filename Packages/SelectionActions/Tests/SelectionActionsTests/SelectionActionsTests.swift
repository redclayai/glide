import XCTest
@testable import SelectionActions

// MARK: - Context detection

final class SelectionContextTests: XCTestCase {
    func testCountsWordsLinesAndCharacters() {
        let context = SelectionContext(text: "one two three\nfour")
        XCTAssertEqual(context.wordCount, 4)
        XCTAssertEqual(context.lineCount, 2)
        XCTAssertEqual(context.characterCount, 18)
        XCTAssertTrue(context.isMultiline)
    }

    func testDetectsURLsAndEmail() {
        XCTAssertTrue(SelectionContext(text: "see https://apple.com for more").containsURL)
        XCTAssertTrue(SelectionContext(text: "danny@example.com").containsEmail)
        XCTAssertFalse(SelectionContext(text: "just some ordinary prose here").containsURL)
    }

    /// Two independent signals, so neither prose-with-punctuation nor code-shaped English trips it.
    func testCodeDetectionNeedsMoreThanOneSignal() {
        XCTAssertFalse(SelectionContext(text: "the function returns nil when the list is empty").looksLikeCode)
        XCTAssertFalse(SelectionContext(text: "Well (that) is unfortunate; isn't it?").looksLikeCode)
        XCTAssertTrue(SelectionContext(text: """
        func total(items: [Int]) -> Int {
            return items.reduce(0, +)
        }
        """).looksLikeCode)
    }

    func testSubstantialProseExcludesCode() {
        let prose = SelectionContext(text: String(repeating: "word ", count: 30))
        XCTAssertTrue(prose.isSubstantialProse)
    }
}

// MARK: - Conditions

final class ActionConditionsTests: XCTestCase {
    func testEmptyConditionsMatchAnything() {
        XCTAssertTrue(ActionConditions().matches(SelectionContext(text: "x")))
    }

    func testWordBoundsAreInclusive() {
        let conditions = ActionConditions(minimumWords: 2, maximumWords: 3)
        XCTAssertFalse(conditions.matches(SelectionContext(text: "one")))
        XCTAssertTrue(conditions.matches(SelectionContext(text: "one two")))
        XCTAssertTrue(conditions.matches(SelectionContext(text: "one two three")))
        XCTAssertFalse(conditions.matches(SelectionContext(text: "one two three four")))
    }

    func testBundleAllowAndBlockLists() {
        let onlyMail = ActionConditions(allowedBundleIdentifiers: ["com.apple.mail"])
        XCTAssertTrue(onlyMail.matches(SelectionContext(text: "hi", bundleIdentifier: "com.apple.mail")))
        XCTAssertFalse(onlyMail.matches(SelectionContext(text: "hi", bundleIdentifier: "com.apple.Safari")))

        let notMail = ActionConditions(blockedBundleIdentifiers: ["com.apple.mail"])
        XCTAssertFalse(notMail.matches(SelectionContext(text: "hi", bundleIdentifier: "com.apple.mail")))
    }

    func testSpecificityCountsStatedConditionsOnly() {
        XCTAssertEqual(ActionConditions().specificity, 0)
        XCTAssertEqual(ActionConditions(minimumWords: 1, requiresURL: true).specificity, 2)
    }
}

// MARK: - Ranking

final class ActionRankerTests: XCTestCase {
    private func action(
        _ id: String,
        priority: Int = 0,
        conditions: ActionConditions = .init(),
        output: ActionOutput = .replaceSelection
    ) -> SelectionAction {
        SelectionAction(id: id, title: id, kind: .transform(.uppercase), output: output,
                        conditions: conditions, priority: priority)
    }

    func testDisabledActionsNeverAppear() {
        var preferences = ActionPreferences()
        preferences.setEnabled(false, for: "b")
        let ranked = ActionRanker().rank([action("a"), action("b")],
                                         for: SelectionContext(text: "hello"),
                                         preferences: preferences)
        XCTAssertEqual(ranked.visible.map(\.id), ["a"])
    }

    func testActionsWhoseConditionsFailAreExcluded() {
        let linkOnly = action("link", conditions: ActionConditions(requiresURL: true))
        let ranked = ActionRanker().rank([action("always"), linkOnly],
                                         for: SelectionContext(text: "no link here"),
                                         preferences: ActionPreferences())
        XCTAssertEqual(ranked.visible.map(\.id), ["always"])
    }

    /// The behaviour that makes "Open link" surface on a link without a special case.
    func testMoreSpecificMatchOutranksHigherPriority() {
        let general = action("general", priority: 50)
        let specific = action("specific", priority: 10, conditions: ActionConditions(requiresURL: true))
        let ranked = ActionRanker().rank([general, specific],
                                         for: SelectionContext(text: "https://apple.com"),
                                         preferences: ActionPreferences())
        XCTAssertEqual(ranked.visible.first?.id, "specific")
    }

    func testPinnedActionsComeFirstAndAreNeverInOverflow() {
        var preferences = ActionPreferences()
        preferences.setPinned(true, for: "z")
        let actions = (1...8).map { action("a\($0)", priority: 100 - $0) } + [action("z", priority: 0)]
        let ranked = ActionRanker(visibleLimit: 3).rank(actions,
                                                        for: SelectionContext(text: "hello there"),
                                                        preferences: preferences)
        XCTAssertEqual(ranked.visible.first?.id, "z")
        XCTAssertFalse(ranked.overflow.contains { $0.id == "z" })
        XCTAssertEqual(ranked.visible.count, 3)
    }

    func testPinningMoreThanFitsWidensRatherThanDropsThem() {
        var preferences = ActionPreferences()
        for id in ["p1", "p2", "p3", "p4"] { preferences.setPinned(true, for: id) }
        let actions = ["p1", "p2", "p3", "p4", "other"].map { action($0) }
        let ranked = ActionRanker(visibleLimit: 2).rank(actions,
                                                        for: SelectionContext(text: "hello"),
                                                        preferences: preferences)
        XCTAssertEqual(ranked.visible.count, 4, "an explicit pin outranks the width budget")
        XCTAssertEqual(ranked.overflow.map(\.id), ["other"])
    }

    func testRecentUseLiftsAnActionButCannotBuryAPerfectMatch() {
        var usage = ActionUsage()
        for _ in 0..<50 { usage.record("habit") }
        let ranked = ActionRanker().rank(
            [action("habit"), action("targeted", conditions: ActionConditions(requiresURL: true))],
            for: SelectionContext(text: "https://apple.com"),
            preferences: ActionPreferences(),
            usage: usage
        )
        XCTAssertEqual(ranked.visible.first?.id, "targeted")
    }

    func testRecencyDecaysWithAge() {
        let ranker = ActionRanker()
        var recent = ActionUsage(); recent.record("a", at: Date())
        var old = ActionUsage(); old.record("a", at: Date().addingTimeInterval(-60 * 60 * 24 * 30))
        let context = SelectionContext(text: "hello")

        let recentScore = ranker.score(action("a"), context: context, preferences: .init(), usage: recent, now: Date())
        let oldScore = ranker.score(action("a"), context: context, preferences: .init(), usage: old, now: Date())
        XCTAssertGreaterThan(recentScore, oldScore)
    }

    func testOrderingIsStableForEqualScores() {
        let actions = [action("b", priority: 5), action("a", priority: 5)]
        let first = ActionRanker().rank(actions, for: SelectionContext(text: "hi"), preferences: .init())
        let second = ActionRanker().rank(actions, for: SelectionContext(text: "hi"), preferences: .init())
        XCTAssertEqual(first.visible.map(\.id), second.visible.map(\.id))
        XCTAssertEqual(first.visible.map(\.id), ["a", "b"])
    }
}

// MARK: - Transforms

final class TextTransformerTests: XCTestCase {
    func testTitleCaseLeavesJoiningWordsAlone() {
        XCTAssertEqual(TextTransformer.apply(.titleCase, to: "the meeting is at the office"),
                       "The Meeting Is at the Office")
    }

    func testSentenceCaseCapitalisesAfterTerminators() {
        XCTAssertEqual(TextTransformer.apply(.sentenceCase, to: "one thing. another THING! a third?  yes"),
                       "One thing. Another thing! A third?  Yes")
    }

    func testSlugify() {
        XCTAssertEqual(TextTransformer.apply(.slugify, to: "Héllo, World — again!"), "hello-world-again")
    }

    func testBase64RoundTrip() {
        let encoded = TextTransformer.apply(.base64Encode, to: "Glide")
        XCTAssertEqual(encoded, "R2xpZGU=")
        XCTAssertEqual(TextTransformer.apply(.base64Decode, to: encoded), "Glide")
    }

    func testBase64DecodeOfGarbageIsEmptyRatherThanWrong() {
        XCTAssertEqual(TextTransformer.apply(.base64Decode, to: "not base64 at all"), "")
    }

    func testLineOperations() {
        let text = "pear\napple\npear\nbanana"
        XCTAssertEqual(TextTransformer.apply(.sortLines, to: text), "apple\nbanana\npear\npear")
        XCTAssertEqual(TextTransformer.apply(.deduplicateLines, to: text), "pear\napple\nbanana")
        XCTAssertEqual(TextTransformer.apply(.reverseLines, to: text), "banana\npear\napple\npear")
    }

    func testCollapseAndJoin() {
        XCTAssertEqual(TextTransformer.apply(.collapseWhitespace, to: "  a   b  "), "a b")
        XCTAssertEqual(TextTransformer.apply(.removeLineBreaks, to: "a\nb\nc"), "a b c")
    }

    func testCountReadsAsASentence() {
        XCTAssertEqual(TextTransformer.apply(.countCharactersAndWords, to: "a b"),
                       "3 characters · 2 words · 1 line")
    }
}

// MARK: - JavaScript

final class JavaScriptActionRunnerTests: XCTestCase {
    func testBareExpression() throws {
        XCTAssertEqual(try JavaScriptActionRunner.run("text.toUpperCase()", text: "glide"), "GLIDE")
    }

    func testMultiStatementBodyWithReturn() throws {
        let source = "var n = text.split(' ').length; return 'words: ' + n;"
        XCTAssertEqual(try JavaScriptActionRunner.run(source, text: "one two three"), "words: 3")
    }

    func testJSONFormattingIsTheShippedCatalogueBehaviour() throws {
        let result = try JavaScriptActionRunner.run("JSON.stringify(JSON.parse(text), null, 2)", text: "{\"a\":1}")
        XCTAssertEqual(result, "{\n  \"a\": 1\n}")
    }

    func testSyntaxErrorSurfacesRatherThanReturningGarbage() {
        XCTAssertThrowsError(try JavaScriptActionRunner.run("this is not javascript", text: "x"))
    }

    /// The claim that a JS action has no side effects rests on the context being bare.
    func testSandboxHasNoHostObjects() throws {
        for probe in ["typeof require", "typeof process", "typeof setTimeout", "typeof fetch"] {
            XCTAssertEqual(try JavaScriptActionRunner.run(probe, text: ""), "undefined", "\(probe) should be unreachable")
        }
    }
}

// MARK: - URL

final class URLActionRunnerTests: XCTestCase {
    func testEncodesSubstitutionByDefault() throws {
        let url = try URLActionRunner.resolve("https://duckduckgo.com/?q={{text}}",
                                              context: SelectionContext(text: "swift concurrency"))
        XCTAssertEqual(url.absoluteString, "https://duckduckgo.com/?q=swift%20concurrency")
    }

    func testRawSubstitutionLeavesAURLIntact() throws {
        let url = try URLActionRunner.resolve("{{text|raw}}", context: SelectionContext(text: "https://apple.com/x?a=1"))
        XCTAssertEqual(url.absoluteString, "https://apple.com/x?a=1")
    }

    func testBareHostGetsAScheme() throws {
        let url = try URLActionRunner.resolve("{{text|raw}}", context: SelectionContext(text: "example.com"))
        XCTAssertEqual(url.scheme, "https")
    }

    func testMailtoAndDictSchemesAreLeftAlone() throws {
        XCTAssertEqual(try URLActionRunner.resolve("mailto:{{text}}", context: SelectionContext(text: "a@b.com")).scheme, "mailto")
        XCTAssertEqual(try URLActionRunner.resolve("dict://{{text}}", context: SelectionContext(text: "cromulent")).scheme, "dict")
    }
}

// MARK: - Runner policy

final class ActionRunnerTests: XCTestCase {
    private func action(_ kind: ActionKind, output: ActionOutput = .replaceSelection) -> SelectionAction {
        SelectionAction(id: "t", title: "t", kind: kind, output: output)
    }

    func testTransformRuns() async throws {
        let result = try await ActionRunner().run(action(.transform(.uppercase)),
                                                  on: SelectionContext(text: "abc"))
        XCTAssertEqual(result, ActionResult(output: .replaceSelection, text: "ABC"))
    }

    func testPromptGoesToTheInjectedModel() async throws {
        let runner = ActionRunner(model: { instruction, text in "\(instruction)|\(text)" })
        let result = try await runner.run(action(.prompt("FIX")), on: SelectionContext(text: "abc"))
        XCTAssertEqual(result.text, "FIX|abc")
    }

    func testPromptWithoutAModelIsAnError() async {
        do {
            _ = try await ActionRunner().run(action(.prompt("FIX")), on: SelectionContext(text: "abc"))
            XCTFail("expected modelUnavailable")
        } catch {
            XCTAssertEqual(error as? ActionError, .modelUnavailable)
        }
    }

    func testCodeExecutionIsOffByDefault() async {
        for kind in [ActionKind.shell("echo hi"), .appleScript("return \"hi\"")] {
            do {
                _ = try await ActionRunner().run(action(kind), on: SelectionContext(text: "x"))
                XCTFail("expected codeExecutionDisabled for \(kind.label)")
            } catch {
                XCTAssertEqual(error as? ActionError, .codeExecutionDisabled)
            }
        }
    }

    func testShellRunsWhenPolicyAllowsIt() async throws {
        let runner = ActionRunner(policy: ExecutionPolicy(allowsCodeExecution: true))
        let result = try await runner.run(action(.shell("tr '[:lower:]' '[:upper:]'")),
                                          on: SelectionContext(text: "glide"))
        XCTAssertEqual(result.text, "GLIDE")
    }

    func testFailingShellCommandReportsItsStderr() async {
        let runner = ActionRunner(policy: ExecutionPolicy(allowsCodeExecution: true))
        do {
            _ = try await runner.run(action(.shell("echo 'went wrong' >&2; exit 3")), on: SelectionContext(text: "x"))
            XCTFail("expected scriptFailed")
        } catch {
            guard case let .scriptFailed(message)? = error as? ActionError else {
                return XCTFail("expected scriptFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("went wrong"), message)
        }
    }

    func testEmptyResultIsAnErrorRatherThanAnEmptyReplacement() async {
        do {
            _ = try await ActionRunner().run(action(.transform(.trimWhitespace)), on: SelectionContext(text: "   "))
            XCTFail("expected emptyResult")
        } catch {
            XCTAssertEqual(error as? ActionError, .emptyResult)
        }
    }

    func testSideEffectClassification() {
        XCTAssertEqual(action(.transform(.uppercase)).sideEffects, .none)
        XCTAssertEqual(action(.javaScript("text")).sideEffects, .none)
        XCTAssertEqual(action(.prompt("x")).sideEffects, .sendsTextToModel)
        XCTAssertEqual(action(.url("https://x")).sideEffects, .opensURL)
        XCTAssertEqual(action(.shell("ls")).sideEffects, .runsCode)
        XCTAssertEqual(action(.appleScript("beep")).sideEffects, .runsCode)
    }
}

// MARK: - Store

final class ActionStoreTests: XCTestCase {
    private func makeStore() -> (ActionStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("actions-\(UUID().uuidString).json")
        return (ActionStore(url: url), url)
    }

    func testBuiltInsAreAvailableWithNoSavedState() {
        let (store, _) = makeStore()
        XCTAssertFalse(store.allActions.isEmpty)
        XCTAssertTrue(store.allActions.allSatisfy { store.preferences.isEnabled($0.id) })
    }

    func testPreferencesAndCustomActionsSurviveAReload() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.update { $0.setEnabled(false, for: "builtin.polish") }
        store.update { $0.setPinned(true, for: "builtin.grammar") }
        store.upsertCustom(SelectionAction(id: "custom.abc", title: "Shout", kind: .transform(.uppercase)))
        store.recordUse(of: "builtin.grammar")

        let reloaded = ActionStore(url: url)
        XCTAssertFalse(reloaded.preferences.isEnabled("builtin.polish"))
        XCTAssertTrue(reloaded.preferences.isPinned("builtin.grammar"))
        XCTAssertEqual(reloaded.customActions.map(\.id), ["custom.abc"])
        XCTAssertEqual(reloaded.usage.counts["builtin.grammar"], 1)
    }

    /// The reason preferences are stored by id rather than as whole records: a new build's catalogue
    /// must reach an existing install without discarding the user's arrangement.
    func testNewBuiltInsArriveEnabledWithoutDisturbingSavedPreferences() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.update { $0.setEnabled(false, for: "builtin.polish") }

        let reloaded = ActionStore(url: url)
        let ids = Set(reloaded.allActions.map(\.id))
        XCTAssertTrue(ids.contains("builtin.summarize"), "the whole shipped catalogue is present")
        XCTAssertTrue(reloaded.preferences.isEnabled("builtin.summarize"), "unknown ids default to enabled")
        XCTAssertFalse(reloaded.preferences.isEnabled("builtin.polish"), "the saved choice survived")
    }

    func testRemovingACustomActionClearsItsPreferences() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.upsertCustom(SelectionAction(id: "custom.abc", title: "Shout", kind: .transform(.uppercase)))
        store.update { $0.setPinned(true, for: "custom.abc") }

        store.removeCustom(id: "custom.abc")
        XCTAssertTrue(store.customActions.isEmpty)
        XCTAssertFalse(store.preferences.isPinned("custom.abc"))
    }

    func testUpsertReplacesRatherThanDuplicates() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.upsertCustom(SelectionAction(id: "custom.abc", title: "One", kind: .transform(.uppercase)))
        store.upsertCustom(SelectionAction(id: "custom.abc", title: "Two", kind: .transform(.lowercase)))
        XCTAssertEqual(store.customActions.count, 1)
        XCTAssertEqual(store.customActions.first?.title, "Two")
    }

    func testExplicitOrderSortsBeforeUnorderedActions() {
        let ordered = ActionStore.sorted(
            [SelectionAction(id: "a", title: "a", kind: .transform(.uppercase)),
             SelectionAction(id: "b", title: "b", kind: .transform(.uppercase)),
             SelectionAction(id: "c", title: "c", kind: .transform(.uppercase))],
            by: ["c", "b"]
        )
        XCTAssertEqual(ordered.map(\.id), ["c", "b", "a"])
    }

    func testCustomIDsCannotCollideWithBuiltIns() {
        XCTAssertTrue(ActionStore.newCustomID().hasPrefix("custom."))
        XCTAssertFalse(ActionCatalog.builtIns.contains { $0.id.hasPrefix("custom.") })
    }
}

// MARK: - Catalogue integrity

final class ActionCatalogTests: XCTestCase {
    func testIDsAreUnique() {
        let ids = ActionCatalog.builtIns.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryBuiltInIsMarkedAsOne() {
        XCTAssertTrue(ActionCatalog.builtIns.allSatisfy(\.isBuiltIn))
    }

    /// No shipped action may execute code. Shell and AppleScript exist for actions the *user* writes;
    /// nothing arrives from us already able to run commands.
    func testNoShippedActionRunsCode() {
        XCTAssertTrue(ActionCatalog.builtIns.allSatisfy { $0.sideEffects != .runsCode })
    }

    func testCatalogueSurvivesARoundTripThroughJSON() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let data = try encoder.encode(ActionCatalog.builtIns)
        XCTAssertEqual(try decoder.decode([SelectionAction].self, from: data), ActionCatalog.builtIns)
    }

    /// The toolbar has to stay short whatever the selection is.
    func testTypicalSelectionsProduceAShortToolbar() {
        let ranker = ActionRanker()
        for text in ["hello", "https://apple.com", "danny@example.com",
                     String(repeating: "word ", count: 60), "a\nb\nc\nd"] {
            let ranked = ranker.rank(ActionCatalog.builtIns,
                                     for: SelectionContext(text: text),
                                     preferences: ActionPreferences())
            XCTAssertLessThanOrEqual(ranked.visible.count, 5, "too many actions for: \(text.prefix(20))")
            XCTAssertFalse(ranked.visible.isEmpty, "no actions at all for: \(text.prefix(20))")
        }
    }

    func testALinkSelectionOffersOpeningIt() {
        let ranked = ActionRanker().rank(ActionCatalog.builtIns,
                                         for: SelectionContext(text: "https://apple.com"),
                                         preferences: ActionPreferences())
        XCTAssertTrue(ranked.visible.contains { $0.id == "builtin.open" })
    }

    func testASingleWordOffersDefineAndNotSummarize() {
        let ranked = ActionRanker().rank(ActionCatalog.builtIns,
                                         for: SelectionContext(text: "cromulent"),
                                         preferences: ActionPreferences())
        XCTAssertTrue(ranked.visible.contains { $0.id == "builtin.define" })
        XCTAssertFalse(ranked.visible.contains { $0.id == "builtin.summarize" })
    }

    func testAParagraphOffersSummarize() {
        let ranked = ActionRanker().rank(ActionCatalog.builtIns,
                                         for: SelectionContext(text: String(repeating: "word ", count: 60)),
                                         preferences: ActionPreferences())
        XCTAssertTrue(ranked.visible.contains { $0.id == "builtin.summarize" })
    }
}
