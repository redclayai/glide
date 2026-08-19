import Foundation

/// Source of the `[Screen context]` prompt section: the most recent OCR of the focused app
/// window's on-screen text. Kept as a protocol so the app target can inject a real capture
/// engine (ScreenCaptureKit + Vision) without `Prompting`/`CompletionController` depending on
/// those frameworks.
///
/// The getter is intentionally a cheap, synchronous read of a *cached* value: OCR is far too slow
/// to run on the per-keystroke completion path, so the engine refreshes the cache out of band (on
/// focus/window change plus a periodic timer) and the completion controller only reads whatever was
/// last captured. Returns `nil` when OCR is disabled, no capture has happened yet, or the last
/// capture produced no usable text.
public protocol ScreenTextProviding {
    var latestScreenText: String? { get }
}

/// Always-empty provider — the default wiring before a real OCR engine is injected, and a
/// convenient stand-in for tests that don't exercise screen context.
public struct NullScreenTextProvider: ScreenTextProviding {
    public init() {}
    public var latestScreenText: String? { nil }
}

/// Returns a fixed string. Useful for unit-testing the consumer (e.g. asserting the controller
/// forwards the cached text into the prompt) without standing up ScreenCaptureKit/Vision.
public struct StaticScreenTextProvider: ScreenTextProviding {
    public var latestScreenText: String?

    public init(latestScreenText: String? = nil) {
        self.latestScreenText = latestScreenText
    }
}
