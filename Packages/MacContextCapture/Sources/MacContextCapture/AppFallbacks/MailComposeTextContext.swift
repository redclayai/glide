import AppKit
import ApplicationServices
import AutocompleteCore
import CoreGraphics
import Foundation

@MainActor
enum MailComposeTextContext {
    static let bundleIdentifier = "com.apple.mail"

    static func snapshot(
        of element: AXUIElement,
        target: AppTarget,
        caretGeometry: AXCaretGeometryResult?
    ) -> FocusedFieldSnapshot? {
        guard target.bundleIdentifier == bundleIdentifier,
              isComposeBody(element) else {
            return nil
        }

        let text = textContent(in: element)
        let fieldRect = fieldRect(for: element)
        let cursorRect = caretGeometry?.rect
            ?? fieldRect.map { estimatedCursorRect(beforeCursor: text, in: $0) }

        let context = TextFieldContext(
            beforeCursor: text,
            geometry: TextFieldGeometry(
                cursorRect: cursorRect,
                fieldRect: fieldRect,
                isAtEndOfLine: true,
                isRightToLeft: WritingDirection.isRightToLeft(text),
                cursorRectQuality: caretGeometry.map { FocusedFieldReader.caretQuality(from: $0.qualityLabel) } ?? .estimated
            ),
            target: target,
            labels: ["message body"],
            detectedLanguage: LanguageDetector.detectLanguage(in: text),
            typingContext: "Apple Mail compose body"
        )

        return FocusedFieldSnapshot(
            context: context,
            caretRect: cursorRect,
            caretSource: caretGeometry?.source ?? "mailComposeEstimated",
            caretQuality: caretGeometry?.qualityLabel ?? "estimated"
        )
    }

    static func isComposeBody(_ element: AXUIElement) -> Bool {
        let description = AXCaretHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: element)?
            .lowercased()
        guard description == "message body" else { return false }

        guard let url = urlString(for: element)?.lowercased() else {
            return true
        }
        return url == "about:blank"
    }

    static func textContent(in element: AXUIElement) -> String {
        if let value = AXCaretHelper.stringValue(for: kAXValueAttribute as CFString, on: element),
           !value.isEmpty {
            return normalizedBodyText(value)
        }

        var parts: [String] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(element, 0)]
        var seen = Set<String>()
        var visited = 0
        let maxDepth = 6
        let maxNodes = 160
        let rootIdentity = AXCaretHelper.elementIdentity(for: element)

        while !queue.isEmpty, visited < maxNodes {
            let (candidate, depth) = queue.removeFirst()
            let identity = AXCaretHelper.elementIdentity(for: candidate)
            guard seen.insert(identity).inserted else { continue }
            visited += 1

            if identity != rootIdentity,
               let value = AXCaretHelper.stringValue(for: kAXValueAttribute as CFString, on: candidate),
               !value.isEmpty {
                parts.append(value)
            }

            guard depth < maxDepth else { continue }
            queue.append(contentsOf: AXCaretHelper.childElements(of: candidate).map { ($0, depth + 1) })
        }

        return normalizedBodyText(parts.joined(separator: "\n"))
    }

    static func estimatedCursorRect(beforeCursor: String, in fieldRect: CGRect) -> CGRect {
        let lines = beforeCursor.split(separator: "\n", omittingEmptySubsequences: false)
        let currentLine = lines.last.map(String.init) ?? ""
        let lineIndex = max(0, lines.count - 1)

        let horizontalPadding: CGFloat = 24
        let topPadding: CGFloat = 14
        let averageCharacterWidth: CGFloat = 7.2
        let lineHeight: CGFloat = 18
        let cursorHeight: CGFloat = 18

        let textWidth = min(
            CGFloat(currentLine.count) * averageCharacterWidth,
            max(0, fieldRect.width - horizontalPadding * 2)
        )
        let y = max(
            fieldRect.minY + 4,
            fieldRect.maxY - topPadding - cursorHeight - CGFloat(lineIndex) * lineHeight
        )

        return CGRect(
            x: fieldRect.minX + horizontalPadding + textWidth,
            y: y,
            width: 2,
            height: cursorHeight
        )
    }

    private static func fieldRect(for element: AXUIElement) -> CGRect? {
        guard let axFrame = AXCaretHelper.rectValue(for: "AXFrame" as CFString, on: element),
              !axFrame.isEmpty else {
            return nil
        }
        return AXCaretHelper.cocoaRect(fromAccessibilityRect: axFrame)
    }

    private static func urlString(for element: AXUIElement) -> String? {
        guard let value = AXCaretHelper.copyAttributeValue("AXURL" as CFString, on: element) else {
            return nil
        }
        if let url = value as? URL { return url.absoluteString }
        if let url = value as? NSURL { return url.absoluteString }
        return value as? String
    }

    private static func normalizedBodyText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00a0}", with: " ")
    }
}
