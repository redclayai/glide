import Foundation

/// Neutral, decoder-agnostic adjustments derived from local telemetry. The app maps these onto its
/// `DecodingConfiguration` (relative cutoff + min-branch-probability) when building the engine, so
/// `Personalization` need not depend on the decoder package. `neutral` is a no-op.
///
/// - `relativeCutoffDelta` is *added* to the base relative cutoff (a larger cutoff keeps more
///   branches alive → more candidates, fewer suppressions).
/// - `minBranchProbabilityScale` *multiplies* the base per-step probability floor (a smaller scale
///   lowers the floor → admits weaker-but-valid continuations).
public struct ThresholdAdjustments: Equatable, Sendable {
    public var relativeCutoffDelta: Float
    public var minBranchProbabilityScale: Float

    public init(relativeCutoffDelta: Float, minBranchProbabilityScale: Float) {
        self.relativeCutoffDelta = relativeCutoffDelta
        self.minBranchProbabilityScale = minBranchProbabilityScale
    }

    public static let neutral = ThresholdAdjustments(
        relativeCutoffDelta: 0,
        minBranchProbabilityScale: 1
    )
}

/// Maps observed telemetry to *bounded, conservative* decoder nudges. The intent is to gently widen
/// the search when the user is seeing almost nothing they accept (very high suppression + very low
/// acceptance), and to tighten slightly when acceptance is already strong (saving latency/noise).
/// Adjustments are clamped so a noisy session can never push the decoder somewhere wild, and the
/// tuner stays inert until enough data has accumulated. See ADR-023.
public enum ThresholdTuner {
    /// Clamp bounds, exposed for tests.
    public static let maxCutoffDelta: Float = 2
    public static let minProbabilityScale: Float = 0.25
    public static let maxProbabilityScale: Float = 2

    public static func adjustments(
        for snapshot: TelemetrySnapshot,
        minimumSamples: Int = 30
    ) -> ThresholdAdjustments {
        guard snapshot.generatedCount >= minimumSamples else { return .neutral }

        var cutoffDelta: Float = 0
        var probabilityScale: Float = 1

        if snapshot.suppressionRate > 0.85, snapshot.acceptanceRate < 0.2 {
            // Almost nothing is getting through and what does isn't accepted — widen the search.
            cutoffDelta = 2
            probabilityScale = 0.5
        } else if snapshot.suppressionRate > 0.7, snapshot.acceptanceRate < 0.35 {
            cutoffDelta = 1
            probabilityScale = 0.75
        } else if snapshot.acceptanceRate > 0.6 {
            // Working well — tighten a touch to trim latency and marginal candidates.
            cutoffDelta = -1
            probabilityScale = 1.25
        }

        return ThresholdAdjustments(
            relativeCutoffDelta: min(maxCutoffDelta, max(-maxCutoffDelta, cutoffDelta)),
            minBranchProbabilityScale: min(maxProbabilityScale, max(minProbabilityScale, probabilityScale))
        )
    }
}
