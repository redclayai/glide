import AppKit
import AutocompleteCore
import CoreGraphics
import Foundation

enum WeChatFallbackTextContext {
    static let bundleIdentifier = "com.tencent.xinWeChat"
    private static let maxBufferedCharacters = 500

    static func isTarget(_ target: AppTarget) -> Bool {
        target.bundleIdentifier == bundleIdentifier
    }

    static func isSparseSnapshot(_ snapshot: FocusedFieldSnapshot?) -> Bool {
        guard let snapshot, isTarget(snapshot.context.target) else { return false }
        return snapshot.context.beforeCursor.isEmpty
            && snapshot.context.afterCursor.isEmpty
            && snapshot.caretRect == nil
    }

    static func snapshot(
        beforeCursor: String,
        target: AppTarget,
        windowFrame: CGRect?
    ) -> FocusedFieldSnapshot? {
        let trimmed = beforeCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fieldRect = (windowFrame ?? NSScreen.main?.visibleFrame).map(estimatedComposeField(in:))
        let cursorRect = fieldRect.map { estimatedCursorRect(beforeCursor: beforeCursor, in: $0) }

        let context = TextFieldContext(
            beforeCursor: String(beforeCursor.suffix(maxBufferedCharacters)),
            geometry: TextFieldGeometry(
                cursorRect: cursorRect,
                fieldRect: fieldRect,
                isAtEndOfLine: true,
                isRightToLeft: WritingDirection.isRightToLeft(beforeCursor),
                cursorRectQuality: .estimated
            ),
            target: target,
            detectedLanguage: LanguageDetector.detectLanguage(in: beforeCursor),
            typingContext: "WeChat message composer (keystroke fallback)"
        )

        return FocusedFieldSnapshot(
            context: context,
            caretRect: cursorRect,
            caretSource: "wechatKeystrokeFallback",
            caretQuality: "estimated"
        )
    }

    static func estimatedComposeField(in windowFrame: CGRect) -> CGRect {
        let sidebarWidth = min(max(windowFrame.width * 0.25, 280), 340)
        let horizontalInset: CGFloat = 16
        let bottomInset: CGFloat = 18
        let height = min(max(windowFrame.height * 0.11, 82), 118)
        return CGRect(
            x: windowFrame.minX + sidebarWidth + horizontalInset,
            y: windowFrame.minY + bottomInset,
            width: max(160, windowFrame.width - sidebarWidth - horizontalInset * 2),
            height: height
        )
    }

    static func estimatedCursorRect(beforeCursor: String, in fieldRect: CGRect) -> CGRect {
        let currentLine = beforeCursor
            .split(separator: "\n", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? ""
        let horizontalPadding: CGFloat = 18
        let verticalPadding: CGFloat = 18
        let averageCharacterWidth: CGFloat = 7.4
        let cursorHeight: CGFloat = 18
        let textWidth = min(
            CGFloat(currentLine.count) * averageCharacterWidth,
            max(0, fieldRect.width - horizontalPadding * 2)
        )
        return CGRect(
            x: fieldRect.minX + horizontalPadding + textWidth,
            y: fieldRect.maxY - verticalPadding - cursorHeight,
            width: 2,
            height: cursorHeight
        )
    }
}

struct KeystrokeFallbackTextBuffer {
    private(set) var beforeCursor = ""
    private let maxCharacters: Int

    init(maxCharacters: Int = 500) {
        self.maxCharacters = maxCharacters
    }

    var isEmpty: Bool {
        beforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func append(_ text: String) {
        let printable = text.filter { character in
            !character.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
            }
        }
        guard !printable.isEmpty else { return }
        beforeCursor.append(contentsOf: printable)
        if beforeCursor.count > maxCharacters {
            beforeCursor = String(beforeCursor.suffix(maxCharacters))
        }
    }

    mutating func deleteBackward() {
        guard !beforeCursor.isEmpty else { return }
        beforeCursor.removeLast()
    }

    mutating func reset() {
        beforeCursor.removeAll()
    }
}
