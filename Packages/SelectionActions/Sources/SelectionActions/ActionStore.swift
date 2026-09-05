//
//  ActionStore.swift
//  SelectionActions
//
//  Persistence for the user's arrangement: which actions are on, which are pinned, what order they
//  sit in, their own custom actions, and how often each gets used.
//
//  The merge is the interesting part. A built-in action's *definition* ships with the app and a
//  user's *arrangement of it* lives on disk, so an upgrade that adds or rewrites built-ins must not
//  discard pins, order or disabled flags — and must not resurrect an action the user turned off.
//  Storing only the preferences, keyed by id, and re-deriving the catalogue from the binary on every
//  launch is what makes that fall out for free. Storing whole action records instead would mean every
//  upgrade either clobbered the user's edits or froze the built-ins at their shipped version.
//
//  Custom actions are the exception: those *are* stored whole, because nothing else knows them.
//

import Foundation

// MARK: - Preferences

public struct ActionPreferences: Codable, Equatable, Sendable {
    /// Ids the user explicitly turned off. Absence means enabled — new built-ins therefore arrive
    /// switched on, which is what a new feature should do.
    public var disabled: Set<String>
    /// Ids the user pinned, in the order they pinned them.
    public var pinned: [String]
    /// Explicit ordering for the settings list. Ids missing from it sort after, by catalogue order.
    public var order: [String]

    public init(disabled: Set<String> = [], pinned: [String] = [], order: [String] = []) {
        self.disabled = disabled
        self.pinned = pinned
        self.order = order
    }

    public func isEnabled(_ id: String) -> Bool { !disabled.contains(id) }
    public func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    public mutating func setEnabled(_ enabled: Bool, for id: String) {
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
    }

    public mutating func setPinned(_ isPinned: Bool, for id: String) {
        pinned.removeAll { $0 == id }
        if isPinned { pinned.append(id) }
    }
}

// MARK: - Persisted document

struct ActionDocument: Codable {
    var catalogVersion: Int
    var preferences: ActionPreferences
    var customActions: [SelectionAction]
    var usage: ActionUsage

    static let empty = ActionDocument(
        catalogVersion: ActionCatalog.version,
        preferences: ActionPreferences(),
        customActions: [],
        usage: ActionUsage()
    )
}

// MARK: - Store

/// Reads and writes the arrangement. Not an `ObservableObject` — the app layer owns observation, and
/// keeping this a plain value type means the whole thing is testable without a run loop.
public final class ActionStore: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "app.glide.selection-actions.store")
    private var document: ActionDocument

    /// One encoder/decoder pair, configured once. Two independently-configured coders with different
    /// date strategies silently lost a whole history once already (ADR-118) — the pairing is the fix.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("KeyType", isDirectory: true)
            .appendingPathComponent("Actions", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("actions.json")
    }

    public init(url: URL = ActionStore.defaultURL()) {
        self.url = url
        self.document = Self.load(from: url)
    }

    private static func load(from url: URL) -> ActionDocument {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        do {
            return try decoder.decode(ActionDocument.self, from: data)
        } catch {
            // Loudly, not silently. A `try?` here is how three separate invisible failures got shipped
            // (ADR-118, ADR-122); a corrupt file should announce itself and then start clean.
            NSLog("[Glide] actions.json could not be decoded (%@) — starting from defaults", "\(error)")
            return .empty
        }
    }

    private func persist() {
        do {
            let data = try Self.encoder.encode(document)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[Glide] actions.json could not be written: %@", "\(error)")
        }
    }

    // MARK: - Reading

    /// Every action the app knows about: the shipped catalogue plus the user's own, in the user's
    /// order.
    public var allActions: [SelectionAction] {
        queue.sync {
            let combined = ActionCatalog.builtIns + document.customActions
            return Self.sorted(combined, by: document.preferences.order)
        }
    }

    public var preferences: ActionPreferences { queue.sync { document.preferences } }
    public var customActions: [SelectionAction] { queue.sync { document.customActions } }
    public var usage: ActionUsage { queue.sync { document.usage } }

    static func sorted(_ actions: [SelectionAction], by order: [String]) -> [SelectionAction] {
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return actions.enumerated().sorted { lhs, rhs in
            let l = index[lhs.element.id]
            let r = index[rhs.element.id]
            switch (l, r) {
            case let (l?, r?): return l < r
            case (nil, _?): return false      // unordered sorts after ordered
            case (_?, nil): return true
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    // MARK: - Writing

    public func update(_ mutate: (inout ActionPreferences) -> Void) {
        queue.sync {
            mutate(&document.preferences)
            persist()
        }
    }

    public func recordUse(of id: String, at date: Date = Date()) {
        queue.sync {
            document.usage.record(id, at: date)
            persist()
        }
    }

    /// Adds a custom action, or replaces the existing one with the same id.
    public func upsertCustom(_ action: SelectionAction) {
        queue.sync {
            var action = action
            action.isBuiltIn = false
            if let existing = document.customActions.firstIndex(where: { $0.id == action.id }) {
                document.customActions[existing] = action
            } else {
                document.customActions.append(action)
            }
            persist()
        }
    }

    /// Removes a custom action. Built-ins are ignored — they can be disabled, never deleted, because
    /// a missing built-in is indistinguishable from a bug.
    public func removeCustom(id: String) {
        queue.sync {
            document.customActions.removeAll { $0.id == id }
            document.preferences.disabled.remove(id)
            document.preferences.pinned.removeAll { $0 == id }
            document.preferences.order.removeAll { $0 == id }
            persist()
        }
    }

    /// A fresh id for a new custom action. Prefixed so it can never collide with a built-in, present
    /// or future.
    public static func newCustomID() -> String { "custom.\(UUID().uuidString.prefix(8).lowercased())" }
}
