//
//  ActionRanking.swift
//  SelectionActions
//
//  Which actions to show, and in what order.
//
//  The whole point of a floating callout is that it is short. Thirty-odd actions cannot all be
//  offered, so the ranker's real job is deciding what to *leave out* — `visibleLimit` is the design
//  constraint everything else here serves.
//
//  Four signals, in descending authority:
//
//    1. Pinned. An explicit instruction from the user, and it outranks anything inferred.
//    2. Discriminators. An action that asked for a URL and got one is a better offer than one that
//       asked for nothing. This is what makes "Open link" surface on a link without a special case.
//    3. Recent use, decayed. Yesterday's habit should fade rather than outrank today's context.
//    4. Static priority, as the tie-break, so the ordering is stable and testable.
//
//  Those four are on separate numeric scales rather than blended, because otherwise the ordering
//  above is only an aspiration: with all three terms in the same range, a high enough `priority`
//  beat a perfect content match, and a well-worn habit beat both. A discriminator is worth more than
//  the entire priority range, and the recency term is capped below one discriminator, so the stated
//  authority is arithmetically guaranteed instead of merely intended.
//
//  Deliberately not a learned model. The behaviour has to be explainable — a user who pins something
//  and does not see it first has been lied to — and a linear score over four terms is explainable in
//  a sentence.
//

import Foundation

public struct ActionRanker: Sendable {
    /// How many actions fit in a callout before it stops being a callout. Five text items plus a
    /// dismiss control is already about as wide as a sentence of body text.
    public var visibleLimit: Int
    /// How many top-ranked actions stand alone before the rest are collapsed into groups. Small on
    /// purpose: the point of grouping is that the bar stays scannable, and four standalone buttons
    /// plus two group menus is already a wide bar.
    public var singleLimit: Int
    /// Recent-use weight halves over this interval.
    public var recencyHalfLife: TimeInterval

    public init(
        visibleLimit: Int = 5,
        singleLimit: Int = 3,
        recencyHalfLife: TimeInterval = 60 * 60 * 24 * 3
    ) {
        self.visibleLimit = visibleLimit
        self.singleLimit = singleLimit
        self.recencyHalfLife = recencyHalfLife
    }

    /// The actions to put in the toolbar, best first, already filtered by enablement and conditions.
    public func rank(
        _ actions: [SelectionAction],
        for context: SelectionContext,
        preferences: ActionPreferences,
        usage: ActionUsage = ActionUsage(),
        now: Date = Date()
    ) -> RankedActions {
        let eligible = actions
            .filter { preferences.isEnabled($0.id) }
            .filter { $0.conditions.matches(context) }

        let scored = eligible
            .map { (action: $0, score: score($0, context: context, preferences: preferences, usage: usage, now: now)) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                // Stable and inspectable rather than arbitrary: equal scores fall back to the
                // author's ordering, then to the id.
                if $0.action.priority != $1.action.priority { return $0.action.priority > $1.action.priority }
                return $0.action.id < $1.action.id
            }
            .map(\.action)

        // A pinned action always stands alone and is never collapsed into a group or an overflow.
        // That is what pinning means: the user said "put this where I can click it".
        let pinned = scored.filter { preferences.isPinned($0.id) }
        var rest = scored.filter { !preferences.isPinned($0.id) }

        // The best few stand alone, whatever group they belong to — a perfect match for the current
        // selection should not be one click further away because it happens to be filed under
        // "Writing".
        let singleBudget = max(0, min(singleLimit, visibleLimit - pinned.count))
        let singles = Array(rest.prefix(singleBudget))
        rest = Array(rest.dropFirst(singleBudget))

        var items: [ToolbarItem] = (pinned + singles).map(ToolbarItem.action)

        // Everything still eligible collapses into its named group, in the order the groups' best
        // members ranked. Ungrouped leftovers stay in the unnamed overflow.
        var groupOrder: [String] = []
        var grouped: [String: [SelectionAction]] = [:]
        var ungrouped: [SelectionAction] = []
        for action in rest {
            guard let name = action.group else {
                ungrouped.append(action)
                continue
            }
            if grouped[name] == nil { groupOrder.append(name) }
            grouped[name, default: []].append(action)
        }

        for name in groupOrder {
            guard items.count < visibleLimit, let members = grouped[name], !members.isEmpty else {
                // No slot left: the group's members fall back to the unnamed overflow rather than
                // vanishing.
                ungrouped.append(contentsOf: grouped[name] ?? [])
                continue
            }
            items.append(.group(ActionGroup(
                name: name,
                symbolName: Self.symbol(forGroup: name, members: members),
                actions: members
            )))
        }

        return RankedActions(items: items, overflow: ungrouped)
    }

    /// A group takes the symbol of its best-ranked member, so the icon means something rather than
    /// being a second thing to invent and maintain per group name.
    static func symbol(forGroup name: String, members: [SelectionAction]) -> String {
        members.first?.symbolName ?? "ellipsis"
    }

    /// One discriminator outweighs the whole priority range; the recency term is capped below one
    /// discriminator but above the priority range. See the header for why the scales are separated.
    static let discriminatorWeight: Double = 1000
    static let maximumRecencyBonus: Double = 400
    static let maximumPriority: Double = 100

    func score(
        _ action: SelectionAction,
        context: SelectionContext,
        preferences: ActionPreferences,
        usage: ActionUsage,
        now: Date
    ) -> Double {
        // Priority is the floor: a tie-break within a tier, never a way to climb out of one.
        var score = min(Double(action.priority), Self.maximumPriority)

        score += Double(action.conditions.discriminators) * Self.discriminatorWeight

        // Recent use, halving over the half-life. Capped so a much-used action can outrank a
        // higher-priority one but never a better-matched one — habit informs the order, it does not
        // dictate it.
        if let last = usage.lastUsed[action.id] {
            let age = max(0, now.timeIntervalSince(last))
            let decay = pow(0.5, age / recencyHalfLife)
            score += min(Self.maximumRecencyBonus, Double(usage.counts[action.id] ?? 0) * 80) * decay
        }

        return score
    }
}

/// One slot in the toolbar: either an action the user can click straight away, or a named group that
/// opens a menu.
public enum ToolbarItem: Equatable, Sendable {
    case action(SelectionAction)
    case group(ActionGroup)

    public var title: String {
        switch self {
        case let .action(action): return action.title
        case let .group(group): return group.name
        }
    }

    public var symbolName: String {
        switch self {
        case let .action(action): return action.symbolName
        case let .group(group): return group.symbolName
        }
    }
}

public struct ActionGroup: Equatable, Sendable {
    public var name: String
    public var symbolName: String
    /// In ranked order, so the most relevant member is at the top of the menu.
    public var actions: [SelectionAction]

    public init(name: String, symbolName: String, actions: [SelectionAction]) {
        self.name = name
        self.symbolName = symbolName
        self.actions = actions
    }
}

public struct RankedActions: Equatable, Sendable {
    /// Goes in the toolbar, in order.
    public var items: [ToolbarItem]
    /// Eligible actions that belong to no group and did not earn a slot. The unnamed remainder.
    public var overflow: [SelectionAction]

    public init(items: [ToolbarItem] = [], overflow: [SelectionAction] = []) {
        self.items = items
        self.overflow = overflow
    }

    public var isEmpty: Bool { items.isEmpty && overflow.isEmpty }

    /// Every action reachable from this toolbar, flattened — for tests and for logging.
    public var allActions: [SelectionAction] {
        items.flatMap { item -> [SelectionAction] in
            switch item {
            case let .action(action): return [action]
            case let .group(group): return group.actions
            }
        } + overflow
    }
}

// MARK: - Usage

/// How often and how recently each action has been run. Counts only — never the text it ran on.
public struct ActionUsage: Codable, Equatable, Sendable {
    public var counts: [String: Int]
    public var lastUsed: [String: Date]

    public init(counts: [String: Int] = [:], lastUsed: [String: Date] = [:]) {
        self.counts = counts
        self.lastUsed = lastUsed
    }

    public mutating func record(_ id: String, at date: Date = Date()) {
        counts[id, default: 0] += 1
        lastUsed[id] = date
    }
}
