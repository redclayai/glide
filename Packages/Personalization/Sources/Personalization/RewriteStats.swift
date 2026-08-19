//
//  RewriteStats.swift
//  Personalization
//
//  Counts what the rewrite path has actually done for you: how many corrections you took, in which
//  apps, and when.
//
//  Unlike `CompletionTelemetryStore` next door — which keeps aggregate counters to tune the decoder —
//  this keeps one record per *accepted* rewrite, because the questions it answers are per-app and
//  over-time and aggregates cannot reconstruct either. Rejected and ignored suggestions are not
//  recorded: the interesting number is what you kept, and counting what Glide offered would flatter
//  it for being noisy.
//
//  Local, plain JSON in Application Support, no text captured — only counts, an app name, and a
//  timestamp. Bounded so a long-lived install cannot grow the file without limit.
//

import Foundation

public struct RewriteEvent: Codable, Equatable, Sendable {
    public let date: Date
    public let appName: String
    public let bundleIdentifier: String
    /// `proofreader` for a spelling fix, `model` for a grammar rewrite.
    public let origin: String
    public let charactersChanged: Int
    public let wordsChanged: Int

    public init(
        date: Date,
        appName: String,
        bundleIdentifier: String,
        origin: String,
        charactersChanged: Int,
        wordsChanged: Int
    ) {
        self.date = date
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.origin = origin
        self.charactersChanged = charactersChanged
        self.wordsChanged = wordsChanged
    }
}

public enum RewriteStatsWindow: String, CaseIterable, Sendable {
    case week
    case month
    case allTime

    public var title: String {
        switch self {
        case .week: return "This Week"
        case .month: return "This Month"
        case .allTime: return "All Time"
        }
    }
}

public struct RewriteStatsSummary: Equatable, Sendable {
    public struct Bucket: Equatable, Sendable {
        public let date: Date
        public let count: Int
        public init(date: Date, count: Int) { self.date = date; self.count = count }
    }

    public struct Tally: Equatable, Sendable {
        public let name: String
        public let count: Int
        public init(name: String, count: Int) { self.name = name; self.count = count }
    }

    public let total: Int
    public let wordsRefined: Int
    public let charactersFixed: Int
    public let appCount: Int
    public let secondsSaved: Double
    public let byApp: [Tally]
    public let byOrigin: [Tally]
    /// Hourly buckets for a single day's window, daily buckets otherwise.
    public let overTime: [Bucket]
    public let bucketsAreHourly: Bool
    public let currentStreakDays: Int
    public let bestStreakDays: Int

    public static let empty = RewriteStatsSummary(
        total: 0, wordsRefined: 0, charactersFixed: 0, appCount: 0, secondsSaved: 0,
        byApp: [], byOrigin: [], overTime: [], bucketsAreHourly: false,
        currentStreakDays: 0, bestStreakDays: 0
    )
}

public final class RewriteStatsStore: @unchecked Sendable {
    /// Characters a competent typist produces per second — 60 wpm at 5 characters a word. Used to
    /// turn "characters you did not have to retype" into a duration. It is an estimate and is
    /// labelled as one wherever it is shown; the alternative is showing nothing, and the number is
    /// the only one here that answers "was this worth installing".
    public static let charactersPerSecond = 5.0

    /// Enough history for a year of heavy use, bounded so the file cannot grow forever.
    static let maximumEvents = 5000

    private let url: URL?
    private let lock = NSLock()
    private var events: [RewriteEvent]

    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = support.appendingPathComponent("KeyType/Telemetry", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("rewrite-stats.json", isDirectory: false)
    }

    /// A nil URL keeps everything in memory — used by tests, and as the fallback when the path
    /// cannot be resolved, so a storage failure never breaks accepting a rewrite.
    public init(url: URL? = (try? RewriteStatsStore.defaultURL())) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? Self.decoder.decode([RewriteEvent].self, from: data) {
            self.events = decoded
        } else {
            self.events = []
        }
    }

    // MARK: - Recording

    public func record(_ event: RewriteEvent) {
        lock.lock()
        events.append(event)
        if events.count > Self.maximumEvents {
            events.removeFirst(events.count - Self.maximumEvents)
        }
        let snapshot = events
        lock.unlock()
        persist(snapshot)
    }

    public func clearAll() {
        lock.lock()
        events = []
        lock.unlock()
        persist([])
    }

    public var allEvents: [RewriteEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    /// Encoder and decoder must agree on the date strategy. They did not at first, and the failure
    /// mode is silent: the write succeeds, the read throws, `try?` swallows it, and the whole history
    /// is quietly discarded on the next launch.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func persist(_ snapshot: [RewriteEvent]) {
        guard let url else { return }
        guard let data = try? Self.encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Summarising

    public func summary(
        for window: RewriteStatsWindow,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> RewriteStatsSummary {
        Self.summarize(allEvents, window: window, now: now, calendar: calendar)
    }

    static func summarize(
        _ events: [RewriteEvent],
        window: RewriteStatsWindow,
        now: Date,
        calendar: Calendar
    ) -> RewriteStatsSummary {
        let start = windowStart(window, now: now, calendar: calendar)
        let inWindow = events.filter { event in
            guard let start else { return true }
            return event.date >= start
        }

        guard !inWindow.isEmpty else {
            // Streaks are a property of the whole history, not the window, so they survive an empty
            // week — otherwise a quiet Monday would read as "streak lost" when it is not.
            let streaks = streakDays(events, now: now, calendar: calendar)
            return RewriteStatsSummary(
                total: 0, wordsRefined: 0, charactersFixed: 0, appCount: 0, secondsSaved: 0,
                byApp: [], byOrigin: [], overTime: [], bucketsAreHourly: window == .week,
                currentStreakDays: streaks.current, bestStreakDays: streaks.best
            )
        }

        let charactersFixed = inWindow.reduce(0) { $0 + $1.charactersChanged }
        let wordsRefined = inWindow.reduce(0) { $0 + $1.wordsChanged }

        let byApp = tally(inWindow.map(\.appName))
        let byOrigin = tally(inWindow.map(\.origin))
        let streaks = streakDays(events, now: now, calendar: calendar)

        // A week reads best hour-by-hour on the current day's scale; longer windows by day.
        let hourly = window == .week
        let buckets = timeBuckets(inWindow, hourly: hourly, now: now, calendar: calendar)

        return RewriteStatsSummary(
            total: inWindow.count,
            wordsRefined: wordsRefined,
            charactersFixed: charactersFixed,
            appCount: Set(inWindow.map(\.bundleIdentifier)).count,
            secondsSaved: Double(charactersFixed) / charactersPerSecond,
            byApp: byApp,
            byOrigin: byOrigin,
            overTime: buckets,
            bucketsAreHourly: hourly,
            currentStreakDays: streaks.current,
            bestStreakDays: streaks.best
        )
    }

    static func windowStart(_ window: RewriteStatsWindow, now: Date, calendar: Calendar) -> Date? {
        switch window {
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .month:
            return calendar.dateInterval(of: .month, for: now)?.start
        case .allTime:
            return nil
        }
    }

    static func tally(_ values: [String]) -> [RewriteStatsSummary.Tally] {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts
            .map { RewriteStatsSummary.Tally(name: $0.key, count: $0.value) }
            // Ties broken by name so the order is stable between renders rather than dictionary order.
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    static func timeBuckets(
        _ events: [RewriteEvent],
        hourly: Bool,
        now: Date,
        calendar: Calendar
    ) -> [RewriteStatsSummary.Bucket] {
        let component: Calendar.Component = hourly ? .hour : .day
        var counts: [Date: Int] = [:]
        for event in events {
            guard let bucket = calendar.dateInterval(of: component, for: event.date)?.start else { continue }
            counts[bucket, default: 0] += 1
        }
        return counts
            .map { RewriteStatsSummary.Bucket(date: $0.key, count: $0.value) }
            .sorted { $0.date < $1.date }
    }

    /// Consecutive days ending today (or yesterday — a streak is not broken until a day is missed
    /// entirely, and it is still morning somewhere in the user's day).
    static func streakDays(
        _ events: [RewriteEvent],
        now: Date,
        calendar: Calendar
    ) -> (current: Int, best: Int) {
        guard !events.isEmpty else { return (0, 0) }

        let days = Set(events.compactMap { calendar.dateInterval(of: .day, for: $0.date)?.start })
        let sorted = days.sorted()

        var best = 1
        var run = 1
        for index in 1..<max(sorted.count, 1) where sorted.count > 1 {
            let previous = sorted[index - 1]
            let day = sorted[index]
            if let next = calendar.date(byAdding: .day, value: 1, to: previous), next == day {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
        }

        guard let today = calendar.dateInterval(of: .day, for: now)?.start else { return (0, best) }
        var current = 0
        var cursor = today
        if !days.contains(today) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  days.contains(yesterday) else { return (0, best) }
            cursor = yesterday
        }
        while days.contains(cursor) {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        return (current, max(best, current))
    }
}
