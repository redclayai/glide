import Foundation

/// One model's current download/install lifecycle state, suitable for SwiftUI observation.
public enum ModelDownloadState: Equatable, Sendable {
    case idle
    /// `progress` is `nil` until the server reports a content length.
    case downloading(progress: Double?)
    /// Download was paused by the user; `progress` is the fraction reached so far. Resuming
    /// continues from here when the server supports range requests.
    case paused(progress: Double?)
    case downloaded
    case failed(String)

    public var statusText: String {
        switch self {
        case .idle:
            return "Not installed"
        case let .downloading(progress):
            if let progress {
                return "Downloading \(Int((progress * 100).rounded()))%"
            }
            return "Downloading…"
        case let .paused(progress):
            if let progress {
                return "Paused at \(Int((progress * 100).rounded()))%"
            }
            return "Paused"
        case .downloaded:
            return "Installed"
        case let .failed(message):
            return message
        }
    }

    /// Determinate progress in 0...1, or `nil` for an indeterminate download.
    public var progressFraction: Double? {
        switch self {
        case let .downloading(progress), let .paused(progress):
            guard let progress else { return nil }
            return min(max(progress, 0), 1)
        case .idle, .downloaded, .failed:
            return nil
        }
    }

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }
}
