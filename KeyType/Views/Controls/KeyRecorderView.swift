//
//  KeyRecorderView.swift
//  KeyType
//
//  A small reusable control for recording an acceptance hotkey. While recording it installs a local
//  key-down monitor, captures the next key + modifiers, and reports an `AcceptanceShortcut`. Escape
//  cancels recording without binding it. Reused by the onboarding wizard and the Settings window.
//

import AppKit
import SwiftUI

struct KeyRecorderView: View {
    let title: String
    let subtitle: String?
    let shortcut: AcceptanceShortcut
    let onChange: (AcceptanceShortcut) -> Void
    var onClear: (() -> Void)?
    var onReset: (() -> Void)?

    @State private var isRecording = false
    @State private var monitor: Any?

    init(
        title: String,
        subtitle: String? = nil,
        shortcut: AcceptanceShortcut,
        onChange: @escaping (AcceptanceShortcut) -> Void,
        onClear: (() -> Void)? = nil,
        onReset: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.onChange = onChange
        self.onClear = onClear
        self.onReset = onReset
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)

            Text(isRecording ? "Press keys…" : shortcut.displayString)
                .font(.body.monospaced())
                .frame(minWidth: 56)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isRecording ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
                )

            Button(isRecording ? "Cancel" : "Change") {
                isRecording ? removeMonitor() : startRecording()
            }
            if let onClear, !isRecording, shortcut.isAssigned {
                Button("Clear") {
                    removeMonitor()
                    onClear()
                }
            }
            if let onReset, !isRecording {
                Button("Reset") {
                    removeMonitor()
                    onReset()
                }
            }
        }
        .onDisappear { removeMonitor() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int64(event.keyCode)
            let modifiers = AcceptanceModifierMask(nsFlags: event.modifierFlags)
            // Bare Escape cancels recording rather than binding the key.
            if code == 53, modifiers.isEmpty {
                removeMonitor()
                return nil
            }
            let label = KeyCodeLabels.label(
                forKeyCode: code,
                characters: event.charactersIgnoringModifiers
            )
            onChange(AcceptanceShortcut(keyCode: code, modifiers: modifiers, label: label))
            removeMonitor()
            return nil // swallow the key so recording it never triggers an action
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
