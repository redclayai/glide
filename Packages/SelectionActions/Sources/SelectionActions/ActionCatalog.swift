//
//  ActionCatalog.swift
//  SelectionActions
//
//  The actions that ship with the app.
//
//  Weighted towards offline transforms rather than AI. Every prompt action costs a network round
//  trip, a key the user had to paste, and text leaving the machine; every transform is instant, free
//  and works on a plane. A menu that is mostly transforms *feels* faster and asks for less trust,
//  which matters more than the headline count.
//
//  Conditions are set so the toolbar stays short. `Summarize` on four words is noise, `Base64 decode`
//  on prose is noise, and a menu that offers everything all the time is the thing this design is
//  trying not to be. The ranker uses the same conditions to order what survives.
//

import Foundation

public enum ActionCatalog {
    /// Bumped whenever the built-in set changes in a way that should reach existing installs. The
    /// store uses it to merge new built-ins into a user's saved arrangement without discarding their
    /// pins, order or disabled flags.
    public static let version = 1

    public static let builtIns: [SelectionAction] = writing + textTransforms + coding + lookups

    // MARK: - Writing (AI)

    static let writing: [SelectionAction] = [
        SelectionAction(
            id: "builtin.grammar",
            title: "Grammar",
            symbolName: "text.badge.checkmark",
            kind: .prompt("Correct only the spelling, grammar and punctuation of the text below. Keep the wording, tone and meaning exactly as they are. Reply with the corrected text and nothing else."),
            conditions: ActionConditions(minimumWords: 2),
            group: "Writing", isBuiltIn: true,
            priority: 100
        ),
        SelectionAction(
            id: "builtin.polish",
            title: "Polish",
            symbolName: "wand.and.stars",
            kind: .prompt("Rewrite the text below to be clearer and more polished, keeping the original meaning and a natural tone. Reply with the rewritten text and nothing else."),
            conditions: ActionConditions(minimumWords: 3),
            group: "Writing", isBuiltIn: true,
            priority: 95
        ),
        SelectionAction(
            id: "builtin.shorten",
            title: "Make shorter",
            symbolName: "arrow.down.right.and.arrow.up.left",
            kind: .prompt("Rewrite the text below to be meaningfully shorter while keeping every substantive point. Reply with the rewritten text and nothing else."),
            conditions: ActionConditions(minimumWords: 12),
            group: "Writing", fewShot: FewShotPrompt(
                header: "Rewrite each sentence to be shorter while keeping the meaning.",
                examples: [
                    PromptExample("We were unable to complete the migration before the deadline arrived.", "We missed the migration deadline."),
                    PromptExample("I wanted to reach out and see whether you had any availability next week.", "Are you free next week?"),
                    PromptExample("The report that you sent over yesterday contained a number of errors.", "Yesterday's report had several errors."),
                ]
            ),
            isBuiltIn: true,
            priority: 80
        ),
        SelectionAction(
            id: "builtin.lengthen",
            title: "Expand",
            symbolName: "arrow.up.left.and.arrow.down.right",
            kind: .prompt("Expand the text below with relevant detail, keeping the original voice. Do not invent facts. Reply with the rewritten text and nothing else."),
            conditions: ActionConditions(minimumWords: 3, maximumWords: 60),
            group: "Writing", fewShot: FewShotPrompt(
                header: "Rewrite each sentence with more supporting detail, keeping the same voice.",
                examples: [
                    PromptExample("Are you free next week?", "Are you free at any point next week? Happy to work around whatever suits you."),
                    PromptExample("The build is broken.", "The build is broken — it started failing after the most recent change and nothing is getting through CI."),
                    PromptExample("Sending the notes now.", "Sending the notes over now, so you have them before the meeting starts."),
                ]
            ),
            isBuiltIn: true,
            priority: 55
        ),
        SelectionAction(
            id: "builtin.summarize",
            title: "Summarize",
            symbolName: "text.line.first.and.arrowtriangle.forward",
            kind: .prompt("Summarize the text below in one short paragraph. Reply with the summary and nothing else."),
            conditions: ActionConditions(minimumWords: 25),
            group: "AI", isBuiltIn: true,
            priority: 85
        ),
        SelectionAction(
            id: "builtin.bullets",
            title: "To bullets",
            symbolName: "list.bullet",
            kind: .prompt("Rewrite the text below as a concise bulleted list, one point per line, each line starting with \"- \". Reply with the list and nothing else."),
            conditions: ActionConditions(minimumWords: 20),
            group: "Writing", isBuiltIn: true,
            priority: 60
        ),
        SelectionAction(
            id: "builtin.professional",
            title: "More formal",
            symbolName: "briefcase",
            kind: .prompt("Rewrite the text below in a professional register, keeping the meaning and length roughly the same. Reply with the rewritten text and nothing else."),
            conditions: ActionConditions(minimumWords: 3),
            group: "Writing", fewShot: FewShotPrompt(
                header: "Rewrite each sentence in a professional tone.",
                examples: [
                    PromptExample("Does that time work for you?", "Please confirm whether that time is convenient."),
                    PromptExample("Heads up — the meeting moved.", "Please note that the meeting has been rescheduled."),
                    PromptExample("Can you take a look at this?", "Could you please review this at your convenience?"),
                ]
            ),
            isBuiltIn: true,
            priority: 50
        ),
        SelectionAction(
            id: "builtin.friendly",
            title: "More casual",
            symbolName: "bubble.left",
            kind: .prompt("Rewrite the text below in a warm, casual register, keeping the meaning. Reply with the rewritten text and nothing else."),
            conditions: ActionConditions(minimumWords: 3),
            group: "Writing", fewShot: FewShotPrompt(
                header: "Rewrite each sentence in a warm, casual tone.",
                examples: [
                    PromptExample("Please advise whether the proposed time is acceptable.", "Does that time work for you?"),
                    PromptExample("I am writing to inform you that the meeting has been rescheduled.", "Heads up — the meeting moved."),
                    PromptExample("Kindly review the attached document at your earliest convenience.", "Mind taking a look at this when you get a sec?"),
                ]
            ),
            isBuiltIn: true,
            priority: 45
        ),
        SelectionAction(
            id: "builtin.translate.english",
            title: "To English",
            symbolName: "character.book.closed",
            kind: .prompt("Translate the text below into English. If it is already English, reply with it unchanged. Reply with the translation and nothing else."),
            conditions: ActionConditions(minimumWords: 1, requiresURL: false),
            group: "AI", fewShot: FewShotPrompt(
                header: "Translate each sentence into English.",
                examples: [
                    PromptExample("Je serai en retard de dix minutes.", "I'll be ten minutes late."),
                    PromptExample("¿Puedes enviarme el archivo?", "Can you send me the file?"),
                    PromptExample("Das Treffen wurde auf morgen verschoben.", "The meeting has been moved to tomorrow."),
                ]
            ),
            isBuiltIn: true,
            priority: 40
        ),
        SelectionAction(
            id: "builtin.explain",
            title: "Explain",
            symbolName: "questionmark.circle",
            kind: .prompt("Explain the text below in plain language, briefly. Reply with the explanation and nothing else."),
            output: .preview,
            conditions: ActionConditions(minimumWords: 2),
            group: "AI", isBuiltIn: true,
            priority: 35
        ),
        SelectionAction(
            id: "builtin.reply",
            title: "Draft reply",
            symbolName: "arrowshape.turn.up.left",
            kind: .prompt("Draft a brief, natural reply to the message below. Reply with the draft and nothing else."),
            output: .copyToClipboard,
            conditions: ActionConditions(minimumWords: 8),
            group: "AI", isBuiltIn: true,
            priority: 30
        ),
    ]

    // MARK: - Text transforms (offline)

    static let textTransforms: [SelectionAction] = [
        SelectionAction(id: "builtin.copy", title: "Copy", symbolName: "doc.on.doc",
                        kind: .transform(.trimWhitespace), output: .copyToClipboard,
                        isBuiltIn: true, priority: 90),
        SelectionAction(id: "builtin.uppercase", title: "UPPERCASE", symbolName: "textformat.size.larger",
                        kind: .transform(.uppercase), conditions: ActionConditions(maximumWords: 40),
                        group: "Text", isBuiltIn: true, priority: 20),
        SelectionAction(id: "builtin.lowercase", title: "lowercase", symbolName: "textformat.size.smaller",
                        kind: .transform(.lowercase), conditions: ActionConditions(maximumWords: 40),
                        group: "Text", isBuiltIn: true, priority: 20),
        SelectionAction(id: "builtin.titlecase", title: "Title Case", symbolName: "textformat",
                        kind: .transform(.titleCase), conditions: ActionConditions(maximumWords: 25),
                        group: "Text", isBuiltIn: true, priority: 22),
        SelectionAction(id: "builtin.sentencecase", title: "Sentence case", symbolName: "textformat.abc",
                        kind: .transform(.sentenceCase), conditions: ActionConditions(minimumWords: 2),
                        group: "Text", isBuiltIn: true, priority: 18),
        SelectionAction(id: "builtin.trim", title: "Trim", symbolName: "scissors",
                        kind: .transform(.trimWhitespace), group: "Text", isBuiltIn: true, priority: 15),
        SelectionAction(id: "builtin.collapse", title: "Collapse spaces", symbolName: "arrow.right.and.line.vertical.and.arrow.left",
                        kind: .transform(.collapseWhitespace), group: "Text", isBuiltIn: true, priority: 14),
        SelectionAction(id: "builtin.joinlines", title: "Join lines", symbolName: "arrow.turn.up.right",
                        kind: .transform(.removeLineBreaks),
                        conditions: ActionConditions(requiresMultipleLines: true),
                        group: "Lines", isBuiltIn: true, priority: 42),
        SelectionAction(id: "builtin.sortlines", title: "Sort lines", symbolName: "arrow.up.arrow.down",
                        kind: .transform(.sortLines),
                        conditions: ActionConditions(requiresMultipleLines: true),
                        group: "Lines", isBuiltIn: true, priority: 38),
        SelectionAction(id: "builtin.reverselines", title: "Reverse lines", symbolName: "arrow.uturn.up",
                        kind: .transform(.reverseLines),
                        conditions: ActionConditions(requiresMultipleLines: true),
                        group: "Lines", isBuiltIn: true, priority: 12),
        SelectionAction(id: "builtin.dedupe", title: "Remove duplicates", symbolName: "line.3.horizontal.decrease",
                        kind: .transform(.deduplicateLines),
                        conditions: ActionConditions(requiresMultipleLines: true),
                        group: "Lines", isBuiltIn: true, priority: 36),
        SelectionAction(id: "builtin.count", title: "Count", symbolName: "number",
                        kind: .transform(.countCharactersAndWords), output: .preview,
                        isBuiltIn: true, priority: 25),
    ]

    // MARK: - Coding / encoding (offline)

    static let coding: [SelectionAction] = [
        SelectionAction(id: "builtin.slugify", title: "Slugify", symbolName: "link",
                        kind: .transform(.slugify), conditions: ActionConditions(maximumWords: 20),
                        group: "Text", isBuiltIn: true, priority: 16),
        SelectionAction(id: "builtin.base64encode", title: "Base64 encode", symbolName: "lock.doc",
                        kind: .transform(.base64Encode), conditions: ActionConditions(maximumCharacters: 4000),
                        group: "Encode", isBuiltIn: true, priority: 10),
        SelectionAction(id: "builtin.base64decode", title: "Base64 decode", symbolName: "lock.open.doc",
                        kind: .transform(.base64Decode), conditions: ActionConditions(requiresMultipleLines: false),
                        group: "Encode", isBuiltIn: true, priority: 10),
        SelectionAction(id: "builtin.urlencode", title: "URL encode", symbolName: "percent",
                        kind: .transform(.urlEncode), conditions: ActionConditions(maximumWords: 30),
                        group: "Encode", isBuiltIn: true, priority: 10),
        SelectionAction(id: "builtin.urldecode", title: "URL decode", symbolName: "percent",
                        kind: .transform(.urlDecode), conditions: ActionConditions(maximumWords: 30),
                        group: "Encode", isBuiltIn: true, priority: 10),
        SelectionAction(
            id: "builtin.explaincode",
            title: "Explain code",
            symbolName: "curlybraces",
            kind: .prompt("Explain what the code below does, briefly and in plain language. Reply with the explanation and nothing else."),
            output: .preview,
            conditions: ActionConditions(requiresCodeLike: true),
            group: "Code", isBuiltIn: true, priority: 88
        ),
        SelectionAction(
            id: "builtin.commentcode",
            title: "Add comments",
            symbolName: "text.bubble",
            kind: .prompt("Add brief explanatory comments to the code below, in its own language's comment syntax. Change nothing else. Reply with the commented code and nothing else."),
            conditions: ActionConditions(requiresCodeLike: true),
            group: "Code", isBuiltIn: true, priority: 70
        ),
        SelectionAction(
            id: "builtin.json",
            title: "Format JSON",
            symbolName: "curlybraces.square",
            kind: .javaScript("JSON.stringify(JSON.parse(text), null, 2)"),
            conditions: ActionConditions(requiresCodeLike: true),
            group: "Code", isBuiltIn: true, priority: 65
        ),
    ]

    // MARK: - Lookups (open a URL)

    static let lookups: [SelectionAction] = [
        SelectionAction(id: "builtin.open", title: "Open link", symbolName: "arrow.up.right.square",
                        kind: .url("{{text|raw}}"), output: .openURL,
                        conditions: ActionConditions(requiresURL: true, requiresMultipleLines: false),
                        isBuiltIn: true, priority: 98),
        SelectionAction(id: "builtin.search", title: "Search", symbolName: "magnifyingglass",
                        kind: .url("https://duckduckgo.com/?q={{text}}"), output: .openURL,
                        conditions: ActionConditions(maximumWords: 12),
                        isBuiltIn: true, priority: 44),
        SelectionAction(id: "builtin.define", title: "Define", symbolName: "character.book.closed.fill",
                        kind: .url("dict://{{text}}"), output: .openURL,
                        // `requiresURL: false` is a guard, not a signal — a bare URL is one "word"
                        // and would otherwise be offered to the dictionary.
                        conditions: ActionConditions(maximumWords: 2, requiresURL: false),
                        isBuiltIn: true, priority: 75),
        SelectionAction(id: "builtin.email", title: "Email", symbolName: "envelope",
                        kind: .url("mailto:{{text}}"), output: .openURL,
                        conditions: ActionConditions(requiresEmail: true),
                        isBuiltIn: true, priority: 96),
        SelectionAction(id: "builtin.maps", title: "Map", symbolName: "map",
                        kind: .url("https://maps.apple.com/?q={{text}}"), output: .openURL,
                        conditions: ActionConditions(minimumWords: 2, maximumWords: 12),
                        group: "Links", isBuiltIn: true, priority: 8),
    ]
}
