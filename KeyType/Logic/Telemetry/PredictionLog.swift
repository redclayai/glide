//
//  PredictionLog.swift
//  KeyType
//
//  A human-readable, append-only log of prediction results and their acceptance status, written to
//  a file that is truncated once per launch. Intended for local evaluation of completion quality.
//
//  Location: ~/Library/Application Support/KeyType/Logs/predictions.log
//
//  **Captured text is off by default.** Without that gate this file is a plaintext transcript of
//  everything the user types, sitting next to a writing-history database that is deliberately
//  encrypted at rest — an inconsistency no amount of "it's local" justifies. What stays on always is
//  the *structure*: which suppression fired, which mechanism applied, how long a span was. That is
//  what makes the log worth having, and none of it needs the words themselves. Turning capture on
//  (Settings → Privacy) is for when someone is actively debugging their own machine.
//

import Foundation
import CoreGraphics
import os

@MainActor
final class PredictionLog {
    private let fileURL: URL?
    private let io = DispatchQueue(label: "com.pattonium.KeyType.predictionlog", qos: .utility)
    private let timestamp: DateFormatter
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "prediction-log")

    init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        timestamp = formatter

        let fm = FileManager.default
        guard let base = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            fileURL = nil
            return
        }

        let directory = base.appendingPathComponent("KeyType/Logs", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("predictions.log")

        // Truncate on launch: overwrite with a fresh header.
        let header = "=== KeyType prediction log — \(ISO8601DateFormatter().string(from: Date())) ===\n"
        do {
            try header.data(using: .utf8)?.write(to: url, options: .atomic)
            fileURL = url
            log.info("Prediction log: \(url.path, privacy: .public)")
        } catch {
            fileURL = nil
            log.error("Could not open prediction log: \(error, privacy: .public)")
        }
    }

    /// Append one timestamped line (off the main thread).
    func append(_ line: String) {
        guard let fileURL else { return }
        let entry = "[\(timestamp.string(from: Date()))] \(line)\n"
        io.async {
            guard let data = entry.data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    // MARK: - Formatting helpers

    /// Whether the user's own words are written to the log. Off unless explicitly enabled.
    ///
    /// Every helper that formats captured text routes through here, so a single flag covers the
    /// completion path, the rewrite path and anything added later — rather than each call site
    /// having to remember.
    static var capturesText = false

    /// Trailing slice of the typed context, with control characters escaped, for log readability.
    static func contextTail(_ text: String, max: Int = 32) -> String {
        guard capturesText else { return redacted(text) }
        return escape(String(text.suffix(max)))
    }

    static func escape(_ text: String) -> String {
        guard capturesText else { return redacted(text) }
        return text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Length instead of content. Enough to correlate a log line with what the user was doing —
    /// which span was replaced, how long a candidate was — without recording what they wrote.
    static func redacted(_ text: String) -> String {
        text.isEmpty ? "⟨empty⟩" : "⟨\(text.count) chars⟩"
    }

    static func rect(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height)))"
    }
}
