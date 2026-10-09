//
//  CompletionAcceptanceController.swift
//  KeyType
//
//  Global acceptance hotkeys (M6 / ADR-016). A session-level CGEvent tap consumes the configured
//  accept keys only while a completion is visible and the app's CompletionPolicy allows Tab
//  acceptance; otherwise every key passes straight through so native behaviour is untouched.
//
//  The accept-word and accept-full hotkeys are user-configurable (SettingsStore), can be
//  unassigned, and default to Tab and Shift+Tab respectively.
//

import AppKit
import AutocompleteCore
import CoreGraphics
import os

@MainActor
final class CompletionAcceptanceController {
    weak var completionController: CompletionController?
    /// The rewrite path. Which of the two owns the accept key depends on how long the user paused:
    /// a post-pause model fix is offered the key first, a spelling fix only after completion has
    /// declined it. See ADR-110 / ADR-112.
    weak var proofreadController: ProofreadController?
    /// Source of the configurable acceptance hotkeys. Read on every matching key-down.
    weak var settings: SettingsStore?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var defaultsObserver: NSObjectProtocol?
    /// The two shortcuts, readable from the tap's thread without touching the main actor.
    private let shortcuts = ShortcutBox()

    /// How long an accept key may wait for the main thread before giving up and behaving natively.
    ///
    /// Only an accept key ever waits. Ordinary typing — letters, Backspace — is decided entirely
    /// from `shortcuts` on the tap's own thread and never blocks, which is the whole point of the
    /// change: those keys were waiting on a main thread measured stalling for as long as 2.5
    /// seconds, so Backspace appeared not to work and had to be pressed repeatedly (ADR-164).
    private static let decisionBudget: TimeInterval = 0.15
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "acceptance")

    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<CompletionAcceptanceController>.fromOpaque(refcon).takeUnretainedValue()
                // `nonisolated`, and deliberately not `MainActor.assumeIsolated`: this runs on the
                // tap's thread now, where that call is a precondition failure rather than a hop.
                return controller.processOffMain(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            log.error("Failed to create acceptance event tap (Accessibility not granted?)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        // Its own thread, never the main one. A head-inserted `.defaultTap` on `keyDown` holds up
        // every keystroke in every application until its callback returns; hanging that off the
        // main run loop meant each key waited behind the Accessibility poll and the card's layout.
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
        }
        thread.name = "app.glide.acceptance-tap"
        thread.qualityOfService = .userInteractive
        thread.start()

        refreshShortcuts()
        // The bindings live in `UserDefaults`, so this catches every route that can change them —
        // the settings pane, a reset, a sync — without each having to remember to call it. A
        // snapshot that silently goes stale would mean Tab quietly ceasing to accept, which is
        // precisely the class of failure this project keeps finding (ADR-135, ADR-159).
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshShortcuts() }
        }
        eventTap = tap
        runLoopSource = source
        tapThread = thread
        isRunning = true
        log.debug("Completion acceptance tap installed")
    }

    func stop() {
        guard isRunning else { return }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        // The thread's run loop ends within a second of cancelling and takes the source with it.
        tapThread?.cancel()
        eventTap = nil
        runLoopSource = nil
        tapThread = nil
        isRunning = false
    }

    /// Runs on the tap's thread, for every keystroke in every application.
    ///
    /// Everything decided here is decided without the main actor: the event's own fields, and the
    /// two shortcuts out of `shortcuts`. A key that is not an accept key — which is to say almost
    /// every key the user presses — returns immediately, and whatever the main actor needs to know
    /// about it is posted asynchronously behind it.
    nonisolated func processOffMain(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in
                guard let tap = self?.eventTap else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // Ignore the keystrokes KeyType synthesizes for insertion (⌘V / injected text). They flow back
        // up through this session tap and would otherwise look like the user diverging — dismissing the
        // held suggestion mid word-by-word acceptance. See ADR-039.
        if event.getIntegerValueField(.eventSourceUserData) == SynthesizedEventMarker.userData {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Screen capture is observation, not editing. Let macOS handle the reserved shortcuts and
        // preserve the visible suggestion for the capture instead of treating the command as a
        // divergent non-text key. This check intentionally runs before user-configurable accept
        // shortcuts so KeyType can never steal Shift-Command-3/4/5 from the system.
        if Self.isScreenCaptureShortcut(keyCode: keyCode, flags: flags) {
            DispatchQueue.main.async { [weak self] in
                self?.completionController?.prepareForScreenCaptureShortcut()
            }
            return Unmanaged.passUnretained(event)
        }

        let pair = shortcuts.current
        let matchesFull = pair.full.matches(keyCode: keyCode, flags: flags)
        let matchesWord = pair.word.matches(keyCode: keyCode, flags: flags)

        // The ordinary path, and the one that matters for how typing feels: not an accept key, so
        // there is nothing to decide and nothing to wait for. The suggestion-invalidating work is
        // posted to the main actor and this returns at once.
        guard matchesFull || matchesWord else {
            let mutation = Self.textMutation(keyCode: keyCode, flags: flags, event: event)
            DispatchQueue.main.async { [weak self] in
                self?.completionController?.dismissStaleCompletion(mutation: mutation)
            }
            return Unmanaged.passUnretained(event)
        }

        // An accept key, and only now is the main actor's answer needed: whether anything is
        // actually waiting to be accepted. Bounded, because a key must not hang behind a stalled
        // main thread — past the budget it does what it would natively have done.
        let decision = Decision()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [weak self] in
            defer { semaphore.signal() }
            guard let self, decision.claim() else { return }
            decision.consumed = self.performAcceptance(matchesFull: matchesFull)
        }
        if semaphore.wait(timeout: .now() + Self.decisionBudget) == .timedOut, decision.claim() {
            return Unmanaged.passUnretained(event)
        }
        return decision.consumed ? nil : Unmanaged.passUnretained(event)
    }

    /// The precedence between the rewrite and the completion, unchanged — only its caller moved.
    /// Returns whether the key was used and should therefore be swallowed.
    private func performAcceptance(matchesFull: Bool) -> Bool {

        // A rewrite that only exists because the user paused outranks a predicted continuation: by
        // then they have stopped composing, and correcting what they wrote beats guessing what comes
        // next. Checked before the completion path because the completion re-shows itself in the
        // second it takes to reach for the key.
        if let proofread = proofreadController, proofread.rewriteOwnsAcceptKey {
            proofread.acceptRewrite()
            return true
        }

        if let controller = completionController, controller.canAcceptCompletion {
            if matchesFull {
                controller.acceptFullCompletion()
            } else {
                controller.acceptNextWord()
            }
            return true
        }

        // No completion to accept: offer the key to a spelling fix before treating it as a key that
        // invalidates whatever is on screen.
        if let proofread = proofreadController, proofread.canAcceptRewrite {
            proofread.acceptRewrite()
            return true
        }

        // An accept key with nothing to accept is just another key that makes a visible suggestion
        // stale. See ADR-037.
        completionController?.dismissStaleCompletion(mutation: .nonText)
        return false
    }

    /// Mirrors the settings into `shortcuts`, which is what the tap thread reads. Called at start
    /// and whenever the bindings change — they are the only main-actor state the hot path needs.
    func refreshShortcuts() {
        shortcuts.set(
            word: settings?.acceptWordShortcut ?? .defaultAcceptWord,
            full: settings?.acceptFullShortcut ?? .defaultAcceptFull
        )
    }

    nonisolated private static func textMutation(keyCode: Int64, flags: CGEventFlags, event: CGEvent) -> CompletionTextMutation {
        if let text = typedText(keyCode: keyCode, flags: flags, event: event) {
            return .inserted(text)
        }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            return .nonText
        }
        switch keyCode {
        case 51:
            return .deleteBackward
        case 117:
            return .deleteForward
        default:
            return .nonText
        }
    }

    /// The plain text a key inserts, used to tell "the user is typing the suggestion" from a divergent
    /// key. Returns `nil` for keys that don't insert plain text — ⌘/⌃-modified combos and control or
    /// navigation keys (return, tab, delete, escape, arrows/function keys) — so those always dismiss
    /// rather than accidentally matching the suggestion's first character.
    nonisolated private static func typedText(keyCode: Int64, flags: CGEventFlags, event: CGEvent) -> String? {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return nil
        }
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        event.keyboardGetUnicodeString(
            maxStringLength: chars.count,
            actualStringLength: &length,
            unicodeString: &chars
        )
        guard length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length)
        guard let scalar = text.unicodeScalars.first else { return nil }
        // C0 controls (return, tab, delete, escape…), the DEL byte, and AppKit's private-use range for
        // arrow/function keys are not real text input.
        if scalar.value < 0x20 || scalar.value == 0x7F || (0xF700...0xF8FF).contains(scalar.value) {
            return nil
        }
        return text
    }

    nonisolated static func isScreenCaptureShortcut(keyCode: Int64, flags: CGEventFlags) -> Bool {
        ReservedSystemShortcut.isScreenCapture(
            keyCode: keyCode,
            shift: flags.contains(.maskShift),
            control: flags.contains(.maskControl),
            option: flags.contains(.maskAlternate),
            command: flags.contains(.maskCommand)
        )
    }
}

/// The accept-key bindings, shared between the main actor that owns them and the tap thread that
/// reads them on every keystroke.
///
/// A lock rather than an actor, because the reader cannot await: it is inside a `CGEventTap`
/// callback holding up a keystroke, and must answer now. `AcceptanceShortcut` is `Sendable` and
/// the pair changes only when the user edits the bindings, so the lock is essentially never
/// contended.
private final class ShortcutBox: @unchecked Sendable {
    private let lock = NSLock()
    private var word: AcceptanceShortcut = .defaultAcceptWord
    private var full: AcceptanceShortcut = .defaultAcceptFull

    var current: (word: AcceptanceShortcut, full: AcceptanceShortcut) {
        lock.lock()
        defer { lock.unlock() }
        return (word, full)
    }

    func set(word: AcceptanceShortcut, full: AcceptanceShortcut) {
        lock.lock()
        self.word = word
        self.full = full
        lock.unlock()
    }
}

/// Settles the race between the tap thread's deadline and the main actor's answer.
///
/// Exactly one side gets to act. Without this, a main actor that replied just after the deadline
/// would accept the completion *and* let the key through natively — a Tab that both completed the
/// word and inserted a tab character.
private final class Decision: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var _consumed = false

    /// True for whichever side gets here first; false for the other.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if settled { return false }
        settled = true
        return true
    }

    var consumed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _consumed }
        set { lock.lock(); _consumed = newValue; lock.unlock() }
    }
}
