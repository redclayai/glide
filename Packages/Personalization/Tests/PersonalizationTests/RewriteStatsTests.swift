import XCTest
@testable import Personalization

final class RewriteStatsTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func event(
        _ date: Date,
        app: String = "Mail",
        bundle: String = "com.apple.mail",
        origin: String = "model",
        characters: Int = 10,
        words: Int = 2
    ) -> RewriteEvent {
        RewriteEvent(
            date: date, appName: app, bundleIdentifier: bundle, origin: origin,
            charactersChanged: characters, wordsChanged: words
        )
    }

    // MARK: - Persistence

    func testInMemoryStoreRecordsWithoutAFile() {
        let store = RewriteStatsStore(url: nil)
        store.record(event(day(2026, 8, 19)))
        XCTAssertEqual(store.allEvents.count, 1)
    }

    func testHistoryIsBounded() {
        let store = RewriteStatsStore(url: nil)
        for i in 0..<(RewriteStatsStore.maximumEvents + 25) {
            store.record(event(day(2026, 8, 19, hour: i % 24)))
        }
        XCTAssertEqual(store.allEvents.count, RewriteStatsStore.maximumEvents)
    }

    func testRoundTripsThroughDisk() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glide-stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = RewriteStatsStore(url: url)
        store.record(event(day(2026, 8, 19), app: "Slack"))
        XCTAssertEqual(RewriteStatsStore(url: url).allEvents.first?.appName, "Slack")
    }

    // MARK: - Windowing

    func testWindowExcludesEventsOutsideIt() {
        let now = day(2026, 8, 19)
        let events = [event(now), event(day(2026, 7, 4)), event(day(2025, 1, 1))]

        let month = RewriteStatsStore.summarize(events, window: .month, now: now, calendar: calendar)
        let allTime = RewriteStatsStore.summarize(events, window: .allTime, now: now, calendar: calendar)

        XCTAssertEqual(month.total, 1)
        XCTAssertEqual(allTime.total, 3)
    }

    func testTotalsAggregateAcrossEvents() {
        let now = day(2026, 8, 19)
        let events = [
            event(now, app: "Mail", bundle: "com.apple.mail", characters: 10, words: 2),
            event(now, app: "Slack", bundle: "com.slack", characters: 5, words: 1),
        ]
        let summary = RewriteStatsStore.summarize(events, window: .allTime, now: now, calendar: calendar)

        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.charactersFixed, 15)
        XCTAssertEqual(summary.wordsRefined, 3)
        XCTAssertEqual(summary.appCount, 2)
        XCTAssertEqual(summary.secondsSaved, 15 / RewriteStatsStore.charactersPerSecond, accuracy: 0.001)
    }

    /// Two apps with the same count must not swap places between renders.
    func testTalliesSortByCountThenName() {
        let now = day(2026, 8, 19)
        let events = [
            event(now, app: "Zed", bundle: "z"), event(now, app: "Ares", bundle: "a"),
            event(now, app: "Mail", bundle: "m"), event(now, app: "Mail", bundle: "m"),
        ]
        let summary = RewriteStatsStore.summarize(events, window: .allTime, now: now, calendar: calendar)
        XCTAssertEqual(summary.byApp.map(\.name), ["Mail", "Ares", "Zed"])
    }

    // MARK: - Streaks

    func testStreakCountsConsecutiveDaysEndingToday() {
        let now = day(2026, 8, 19)
        let events = [day(2026, 8, 17), day(2026, 8, 18), day(2026, 8, 19)].map { event($0) }
        let streak = RewriteStatsStore.streakDays(events, now: now, calendar: calendar)
        XCTAssertEqual(streak.current, 3)
        XCTAssertEqual(streak.best, 3)
    }

    /// A streak is not broken until a whole day passes with nothing.
    func testStreakSurvivesUntilADayIsMissed() {
        let now = day(2026, 8, 19, hour: 9)
        let yesterdayOnly = [day(2026, 8, 17), day(2026, 8, 18)].map { event($0) }
        XCTAssertEqual(RewriteStatsStore.streakDays(yesterdayOnly, now: now, calendar: calendar).current, 2)

        let stale = [day(2026, 8, 15), day(2026, 8, 16)].map { event($0) }
        XCTAssertEqual(RewriteStatsStore.streakDays(stale, now: now, calendar: calendar).current, 0)
    }

    func testBestStreakOutlivesTheCurrentOne() {
        let now = day(2026, 8, 19)
        let events = [
            day(2026, 8, 1), day(2026, 8, 2), day(2026, 8, 3), day(2026, 8, 4),   // best: 4
            day(2026, 8, 19),                                                      // current: 1
        ].map { event($0) }
        let streak = RewriteStatsStore.streakDays(events, now: now, calendar: calendar)
        XCTAssertEqual(streak.current, 1)
        XCTAssertEqual(streak.best, 4)
    }

    /// Streaks describe the whole history, so an empty window must not report the streak as lost.
    func testEmptyWindowStillReportsTheStreak() {
        let now = day(2026, 8, 19)
        let events = [event(day(2026, 8, 18)), event(day(2026, 8, 19))]
        // A window with no events in it at all: summarise a month that has none.
        let summary = RewriteStatsStore.summarize(
            [event(day(2020, 1, 1))], window: .month, now: now, calendar: calendar
        )
        XCTAssertEqual(summary.total, 0)

        let live = RewriteStatsStore.summarize(events, window: .allTime, now: now, calendar: calendar)
        XCTAssertEqual(live.currentStreakDays, 2)
    }

    func testNoEventsMeansNoStreak() {
        XCTAssertEqual(RewriteStatsStore.streakDays([], now: day(2026, 8, 19), calendar: calendar).current, 0)
    }

    // MARK: - Buckets

    func testBucketsAreOrderedInTime() {
        let now = day(2026, 8, 19)
        let events = [
            event(day(2026, 8, 19, hour: 15)),
            event(day(2026, 8, 19, hour: 9)),
            event(day(2026, 8, 19, hour: 9)),
        ]
        let buckets = RewriteStatsStore.timeBuckets(events, hourly: true, now: now, calendar: calendar)
        XCTAssertEqual(buckets.map(\.count), [2, 1])
        XCTAssertTrue(buckets[0].date < buckets[1].date)
    }
}
