import Foundation

/// Classifies a download error so the manager can tell a deliberate user cancel apart from a real
/// failure. A cancel must never surface as a `.failed` state (the user pressed Cancel on purpose).
public enum DownloadOutcomeClassifier {
    public static func isUserCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError { return true }
        return false
    }
}
