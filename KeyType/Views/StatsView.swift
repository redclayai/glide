//
//  StatsView.swift
//  Glide
//
//  What Glide has actually done for you: corrections you kept, where, and when.
//
//  Every number here counts *accepted* rewrites. Suggestions that were offered and ignored are
//  deliberately absent — a count of what the app tried to do would go up when it got noisier, which
//  is the opposite of the thing worth measuring.
//

import Charts
import Personalization
import SwiftUI

struct StatsView: View {
    let store: RewriteStatsStore

    @State private var window: RewriteStatsWindow = .week
    @State private var summary: RewriteStatsSummary = .empty

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                headline
                if summary.total > 0 {
                    overTime
                    HStack(alignment: .top, spacing: 18) {
                        byApp
                        byKind
                    }
                }
            }
            .padding(22)
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reload)
        .onChange(of: window) { _, _ in reload() }
    }

    private func reload() {
        summary = store.summary(for: window)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Glide").font(.largeTitle.bold())
                Text("Corrections you kept").foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $window) {
                ForEach(RewriteStatsWindow.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
        }
    }

    private var headline: some View {
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(summary.total)")
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .contentTransition(.numericText())
                    Text(summary.total == 1 ? "correction taken" : "corrections taken")
                        .foregroundStyle(.secondary)

                    HStack(spacing: 26) {
                        Metric(value: "\(summary.wordsRefined)", label: "words fixed")
                        Metric(value: "\(summary.appCount)", label: summary.appCount == 1 ? "app" : "apps")
                        Metric(value: durationText, label: "typing saved")
                    }
                    .padding(.top, 4)
                }
                Spacer()
                if summary.currentStreakDays > 0 {
                    VStack(spacing: 2) {
                        Text("🔥 \(summary.currentStreakDays)-day streak").font(.callout.weight(.medium))
                        Text("best \(summary.bestStreakDays)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06)))
                }
            }
        }
    }

    private var overTime: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Corrections over time")
                Chart(summary.overTime, id: \.date) { bucket in
                    BarMark(
                        x: .value("When", bucket.date, unit: summary.bucketsAreHourly ? .hour : .day),
                        y: .value("Corrections", bucket.count)
                    )
                    .foregroundStyle(Color.accentColor)
                    .cornerRadius(3)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 180)
            }
        }
    }

    private var byApp: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("By app")
                if summary.byApp.isEmpty {
                    Text("—").foregroundStyle(.secondary)
                } else {
                    // Capped so one heavy day in one app cannot push the rest off the card.
                    ForEach(summary.byApp.prefix(6), id: \.name) { tally in
                        BarRow(
                            name: tally.name,
                            count: tally.count,
                            fraction: Double(tally.count) / Double(max(summary.byApp.first?.count ?? 1, 1))
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var byKind: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Spelling vs grammar")
                ForEach(summary.byOrigin, id: \.name) { tally in
                    BarRow(
                        name: Self.originLabel(tally.name),
                        count: tally.count,
                        fraction: Double(tally.count) / Double(max(summary.total, 1))
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Formatting

    /// Estimated, and labelled as such in the tooltip — it is characters you did not retype divided
    /// by a typing speed, not a measurement.
    private var durationText: String {
        let seconds = summary.secondsSaved
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded()))m" }
        return String(format: "%.1fh", seconds / 3600)
    }

    static func originLabel(_ origin: String) -> String {
        switch origin {
        case "proofreader": return "Spelling"
        case "model": return "Grammar"
        default: return origin.capitalized
        }
    }
}

// MARK: - Pieces

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

private struct Metric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct BarRow: View {
    let name: String
    let count: Int
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.callout)
            HStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(6, geometry.size.width * min(max(fraction, 0), 1)))
                    }
                }
                .frame(height: 8)
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}
