import Foundation

/// Identifies the `CGEvent`s KeyType posts itself (paste / typed-text injection during completion
/// acceptance) so the app's own key taps can recognise and ignore them.
///
/// Without this, a synthesized `⌘V` (or injected character) looks to the acceptance key tap like the
/// user pressing a divergent key, which would dismiss the held suggestion mid-acceptance and break
/// word-by-word Tab. The synthesizer stamps `userData` into the `eventSourceUserData` field of every
/// event it posts (via `CGEventSourceSetUserData`); taps compare against it and pass such events
/// straight through with no side effects. See ADR-039.
public enum SynthesizedEventMarker {
    /// Sentinel written to `eventSourceUserData`. Arbitrary but unlikely-to-collide ("KTPE").
    public static let userData: Int64 = 0x4B54_5045
}
