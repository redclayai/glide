import Foundation

/// Hugging Face mirror fallback. When the primary `huggingface.co` host can't be reached (common
/// where it is blocked or rate-limited), the same path is retried against `hf-mirror.com`, which
/// mirrors Hugging Face with an identical repo/file layout.
public enum HuggingFaceMirror {
    /// Primary hosts that have an `hf-mirror.com` equivalent.
    public static let primaryHosts: Set<String> = ["huggingface.co", "www.huggingface.co"]
    public static let mirrorHost = "hf-mirror.com"

    /// Returns the same URL with its host swapped to the mirror, or `nil` when `url` isn't a
    /// Hugging Face URL (so callers know there's no fallback to try).
    public static func mirrorURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host,
              primaryHosts.contains(host.lowercased()) else {
            return nil
        }
        components.host = mirrorHost
        return components.url
    }

    /// Whether `error` indicates the host was unreachable (DNS/connection/timeout class), i.e. a
    /// case where retrying against the mirror is worthwhile. A bad HTTP status or a user cancel is
    /// deliberately excluded.
    public static func isUnreachableHostError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorDNSLookupFailed,
             NSURLErrorSecureConnectionFailed,
             NSURLErrorResourceUnavailable:
            return true
        default:
            return false
        }
    }
}
