//
//  PredictionLog.swift
//  KeyType
//
//  A human-readable, append-only log of prediction results and their acceptance status, written to
//  a file that is truncated once per launch. Intended for local evaluation of completion quality —
//  it records the model's own output (the candidates) plus a short context tail; consistent with
//  the "local & opt-in" posture, it lives only on disk under Application Support.
//
//  Location: ~/Library/Application Support/KeyType/Logs/predictions.log
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

    /// Trailing slice of the typed context, with control characters escaped, for log readability.
    static func contextTail(_ text: String, max: Int = 32) -> String {
        escape(String(text.suffix(max)))
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    }

    static func rect(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height)))"
    }
}
