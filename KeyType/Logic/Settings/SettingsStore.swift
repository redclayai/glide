//
//  SettingsStore.swift
//  KeyType
//
//  User-facing settings backed by UserDefaults: model selection, completion length, per-app
//  toggles, and the privacy switches that gate sensitive context (writing history, clipboard,
//  screen/OCR). History/clipboard/OCR default to OFF — KeyType only uses sensitive context the
//  user has explicitly opted into. The pipeline (CompletionController / WritingHistoryRecorder /
//  AppCompatibility wiring) reads these; SettingsView writes them. See ADR-023.
//

import AutocompleteCore
import Foundation
import Proofreading
import Observation

/// Completion length presets, mapped to the decoder's token/width budget.
enum CompletionLength: String, CaseIterable, Identifiable {
    case short
    case medium
    case long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: return "Short"
        case .medium: return "Medium"
        case .long: return "Long"
        }
    }

    /// Base `maxCompletionTokens` for a request (token-healing may widen this at runtime).
    var maxCompletionTokens: Int {
        switch self {
        case .short: return 4
        case .medium: return 8
        case .long: return 16
        }
    }

    /// Base `maxDisplayWidth` (characters) for a candidate.
    var maxDisplayWidth: Int {
        switch self {
        case .short: return 30
        case .medium: return 60
        case .long: return 120
        }
    }
}

/// OS-derived English spelling/phrasing preference. This stays as a small prompt-side style signal,
/// not a user-facing setting or a regional prompt template.
enum EnglishVariant {
    case british

    static func promptInstruction(
        systemLocaleIdentifier: String = Locale.autoupdatingCurrent.identifier,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String? {
        switch systemVariant(
            systemLocaleIdentifier: systemLocaleIdentifier,
            preferredLanguages: preferredLanguages
        ) {
        case .british:
            return "When writing English, prefer British English spelling and phrasing. Preserve the spelling convention already present in the surrounding text."
        case nil:
            return nil
        }
    }

    private static func systemVariant(
        systemLocaleIdentifier: String,
        preferredLanguages: [String]
    ) -> EnglishVariant? {
        for identifier in preferredLanguages + [systemLocaleIdentifier] {
            if let variant = variant(forLocaleIdentifier: identifier) {
                return variant
            }
        }
        return nil
    }

    private static func variant(forLocaleIdentifier identifier: String) -> EnglishVariant? {
        let parts = identifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map { $0.uppercased() }
        guard parts.first == "EN" else { return nil }
        guard parts.count >= 2 else { return nil }

        switch parts[1] {
        case "US":
            return nil
        case "GB", "UK", "AU", "NZ", "IE", "ZA":
            return .british
        default:
            return nil
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    private enum Key {
        static let historyEnabled = "KeyType.settings.historyEnabled"
        static let clipboardEnabled = "KeyType.settings.clipboardEnabled"
        static let ocrEnabled = "KeyType.settings.ocrEnabled"
        static let screenshotCalibrationEnabled = "KeyType.settings.screenshotCalibrationEnabled"
        static let fullPromptLoggingEnabled = "KeyType.settings.fullPromptLoggingEnabled"
        static let developerOverrideTuningEnabled = "KeyType.settings.developerOverrideTuningEnabled"
        static let selectionActionsEnabled = "KeyType.settings.selectionActionsEnabled"
        static let proofreadEnabled = "Glide.settings.proofreadEnabled"
        static let aiGrammarEnabled = "Glide.settings.aiGrammarEnabled"
        static let grammarBackend = "Glide.settings.grammarBackend"
        static let logsCapturedText = "Glide.settings.logsCapturedText"
        static let grammarModel = "Glide.settings.grammarModel"
        static let completionLength = "KeyType.settings.completionLength"
        static let selectedModelFilename = "KeyType.settings.selectedModelFilename"
        static let perAppDisabled = "KeyType.settings.perAppDisabledBundleIDs"
        static let manualPerAppDisplayNames = "KeyType.settings.manualPerAppDisplayNames"
        static let acceptWordKeyCode = "KeyType.settings.acceptWordKeyCode"
        static let acceptWordModifiers = "KeyType.settings.acceptWordModifiers"
        static let acceptWordLabel = "KeyType.settings.acceptWordLabel"
        static let acceptFullKeyCode = "KeyType.settings.acceptFullKeyCode"
        static let acceptFullModifiers = "KeyType.settings.acceptFullModifiers"
        static let acceptFullLabel = "KeyType.settings.acceptFullLabel"
    }

    private let defaults: UserDefaults

    /// Opt-in: persist recent typing locally (encrypted) to personalize completions. OFF by default.
    var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled) }
    }

    /// Opt-in: include clipboard text in the prompt. OFF by default.
    var clipboardEnabled: Bool {
        didSet { defaults.set(clipboardEnabled, forKey: Key.clipboardEnabled) }
    }

    /// Opt-in: include on-screen / OCR context in the prompt. OFF by default.
    var ocrEnabled: Bool {
        didSet { defaults.set(ocrEnabled, forKey: Key.ocrEnabled) }
    }

    /// Opt-in: use screenshots to calibrate overlay font size/vertical alignment. OFF by default.
    var screenshotCalibrationEnabled: Bool {
        didSet { defaults.set(screenshotCalibrationEnabled, forKey: Key.screenshotCalibrationEnabled) }
    }

    /// Developer opt-in: write full prompts and candidate details to a shareable local log.
    var fullPromptLoggingEnabled: Bool {
        didSet { defaults.set(fullPromptLoggingEnabled, forKey: Key.fullPromptLoggingEnabled) }
    }

    /// Developer opt-in: hot-load local per-app compatibility overrides from Application Support.
    var developerOverrideTuningEnabled: Bool {
        didSet { defaults.set(developerOverrideTuningEnabled, forKey: Key.developerOverrideTuningEnabled) }
    }

    /// Show the Polish / Grammar popover over selected text. ON by default.
    /// Spelling fix for the word just typed, offered under the caret and applied with Tab.
    var proofreadEnabled: Bool {
        didSet { defaults.set(proofreadEnabled, forKey: Key.proofreadEnabled) }
    }

    /// Model-backed grammar fix for the sentence just finished. Separate from `proofreadEnabled`
    /// because it costs local inference where the spell check costs nothing.
    var aiGrammarEnabled: Bool {
        didSet { defaults.set(aiGrammarEnabled, forKey: Key.aiGrammarEnabled) }
    }

    /// Whether the diagnostic logs record the user's own words, or just lengths. Off by default:
    /// otherwise the log is a plaintext transcript of everything typed, which sits badly beside a
    /// writing-history database that is encrypted at rest. Structural lines are written either way.
    var logsCapturedText: Bool {
        didSet {
            defaults.set(logsCapturedText, forKey: Key.logsCapturedText)
            PredictionLog.capturesText = logsCapturedText
        }
    }

    /// Which engine answers the grammar question. Local by default and stays that way unless the
    /// user picks otherwise — a cloud backend sends their writing off the machine.
    var grammarBackend: RewriteBackend {
        didSet {
            defaults.set(grammarBackend.rawValue, forKey: Key.grammarBackend)
            // A model name belongs to a provider, so switching provider resets it rather than
            // carrying a name the new one will 404 on.
            if grammarBackend != oldValue { grammarModel = grammarBackend.defaultModel }
        }
    }

    /// Editable, because provider model names change more often than this app ships.
    var grammarModel: String {
        didSet { defaults.set(grammarModel, forKey: Key.grammarModel) }
    }

    var selectionActionsEnabled: Bool {
        didSet { defaults.set(selectionActionsEnabled, forKey: Key.selectionActionsEnabled) }
    }

    var completionLength: CompletionLength {
        didSet { defaults.set(completionLength.rawValue, forKey: Key.completionLength) }
    }

    /// Chosen GGUF filename in the Models directory, or `nil` to use the app default.
    var selectedModelFilename: String? {
        didSet { defaults.set(selectedModelFilename, forKey: Key.selectedModelFilename) }
    }

    /// Bundle identifiers the user has turned completions off for.
    var perAppDisabled: Set<String> {
        didSet { defaults.set(Array(perAppDisabled).sorted(), forKey: Key.perAppDisabled) }
    }

    /// Apps the user explicitly added to the per-app Settings list, keyed by bundle identifier.
    var manualPerAppDisplayNames: [String: String] {
        didSet { defaults.set(manualPerAppDisplayNames, forKey: Key.manualPerAppDisplayNames) }
    }

    /// Hotkey that accepts the next word of the visible suggestion. Defaults to Tab.
    var acceptWordShortcut: AcceptanceShortcut {
        didSet { persist(acceptWordShortcut, keyCode: Key.acceptWordKeyCode, modifiers: Key.acceptWordModifiers, label: Key.acceptWordLabel) }
    }

    /// Hotkey that accepts the entire visible suggestion. Defaults to Shift+Tab.
    var acceptFullShortcut: AcceptanceShortcut {
        didSet { persist(acceptFullShortcut, keyCode: Key.acceptFullKeyCode, modifiers: Key.acceptFullModifiers, label: Key.acceptFullLabel) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.historyEnabled = defaults.bool(forKey: Key.historyEnabled)
        self.clipboardEnabled = defaults.bool(forKey: Key.clipboardEnabled)
        self.ocrEnabled = defaults.bool(forKey: Key.ocrEnabled)
        self.screenshotCalibrationEnabled = defaults.bool(forKey: Key.screenshotCalibrationEnabled)
        self.fullPromptLoggingEnabled = defaults.bool(forKey: Key.fullPromptLoggingEnabled)
        self.developerOverrideTuningEnabled = defaults.bool(forKey: Key.developerOverrideTuningEnabled)
        // Default ON: absent key reads as enabled.
        self.selectionActionsEnabled = defaults.object(forKey: Key.selectionActionsEnabled) as? Bool ?? true
        self.proofreadEnabled = defaults.object(forKey: Key.proofreadEnabled) as? Bool ?? true
        self.aiGrammarEnabled = defaults.object(forKey: Key.aiGrammarEnabled) as? Bool ?? true
        self.logsCapturedText = defaults.object(forKey: Key.logsCapturedText) as? Bool ?? false
        let backend = (defaults.string(forKey: Key.grammarBackend))
            .flatMap(RewriteBackend.init(rawValue:)) ?? .local
        self.grammarBackend = backend
        self.grammarModel = defaults.string(forKey: Key.grammarModel) ?? backend.defaultModel
        self.completionLength = (defaults.string(forKey: Key.completionLength))
            .flatMap(CompletionLength.init(rawValue:)) ?? .medium
        self.selectedModelFilename = defaults.string(forKey: Key.selectedModelFilename)
        self.perAppDisabled = Set(defaults.stringArray(forKey: Key.perAppDisabled) ?? [])
        self.manualPerAppDisplayNames =
            defaults.dictionary(forKey: Key.manualPerAppDisplayNames) as? [String: String] ?? [:]
        self.acceptWordShortcut = Self.loadShortcut(
            defaults: defaults,
            keyCodeKey: Key.acceptWordKeyCode,
            modifiersKey: Key.acceptWordModifiers,
            labelKey: Key.acceptWordLabel,
            fallback: .defaultAcceptWord
        )
        self.acceptFullShortcut = Self.loadShortcut(
            defaults: defaults,
            keyCodeKey: Key.acceptFullKeyCode,
            modifiersKey: Key.acceptFullModifiers,
            labelKey: Key.acceptFullLabel,
            fallback: .defaultAcceptFull
        )
    }

    func addManualApp(bundleIdentifier: String, name: String) {
        let trimmedBundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundleIdentifier.isEmpty else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var updatedApps = manualPerAppDisplayNames
        updatedApps[trimmedBundleIdentifier] = trimmedName.isEmpty ? trimmedBundleIdentifier : trimmedName
        manualPerAppDisplayNames = updatedApps
    }

    private func persist(_ shortcut: AcceptanceShortcut, keyCode: String, modifiers: String, label: String) {
        defaults.set(Int(shortcut.keyCode), forKey: keyCode)
        defaults.set(Int(shortcut.modifiers.rawValue), forKey: modifiers)
        defaults.set(shortcut.label, forKey: label)
    }

    private static func loadShortcut(
        defaults: UserDefaults,
        keyCodeKey: String,
        modifiersKey: String,
        labelKey: String,
        fallback: AcceptanceShortcut
    ) -> AcceptanceShortcut {
        // An unset key code reads as 0 from UserDefaults; treat that as "never customized" and use
        // the factory default rather than binding acceptance to key code 0.
        guard defaults.object(forKey: keyCodeKey) != nil else { return fallback }
        let keyCode = Int64(defaults.integer(forKey: keyCodeKey))
        guard keyCode >= 0 else { return .unassigned }
        let modifiers = AcceptanceModifierMask(rawValue: UInt8(truncatingIfNeeded: defaults.integer(forKey: modifiersKey)))
        let label = defaults.string(forKey: labelKey) ?? fallback.label
        return AcceptanceShortcut(keyCode: keyCode, modifiers: modifiers, label: label)
    }

    func setApp(_ bundleIdentifier: String, enabled: Bool) {
        if enabled {
            perAppDisabled.remove(bundleIdentifier)
        } else {
            perAppDisabled.insert(bundleIdentifier)
        }
    }

    func isAppEnabled(_ bundleIdentifier: String) -> Bool {
        !perAppDisabled.contains(bundleIdentifier)
    }

    func promptCustomInstructions(
        appInstructions: [String],
        systemLocaleIdentifier: String = Locale.autoupdatingCurrent.identifier,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [String] {
        var instructions = appInstructions
        if let instruction = EnglishVariant.promptInstruction(
            systemLocaleIdentifier: systemLocaleIdentifier,
            preferredLanguages: preferredLanguages
        ) {
            instructions.append(instruction)
        }
        return instructions
    }
}
