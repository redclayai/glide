//
//  ActionsSettingsView.swift
//  KeyType
//
//  The Actions pane: everything the selection toolbar can do, and the editor for the ones the user
//  writes.
//
//  Two halves, deliberately. The list is about *arrangement* — what appears, what is pinned, what
//  order — and works identically for built-in and custom actions, because they are the same type
//  underneath (ADR-137). The editor is about *authorship*, and only custom actions have it: a
//  built-in can be turned off or reordered but never rewritten, because a corrupted built-in is a
//  support problem where a corrupted custom action is the user's own to fix.
//
//  The trust story is carried in the UI, not just in the engine. Every action shows what it can do
//  beyond changing text, and the two kinds that run arbitrary code are behind a switch that is off
//  until the user reads a sentence explaining it.
//

import SelectionActions
import SwiftUI

struct ActionsSettingsView: View {
    @ObservedObject var model: ActionsSettingsModel

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 320)
            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedID) {
                Section("Actions") {
                    ForEach(model.actions) { action in
                        ActionRow(
                            action: action,
                            isEnabled: model.isEnabled(action),
                            isPinned: model.isPinned(action),
                            toggleEnabled: { model.setEnabled($0, for: action) },
                            togglePinned: { model.setPinned($0, for: action) }
                        )
                        .tag(action.id as String?)
                    }
                    .onMove(perform: model.move)
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 28)

            Divider()
            HStack(spacing: 6) {
                Menu {
                    ForEach(ActionsSettingsModel.NewActionKind.allCases, id: \.self) { kind in
                        Button(kind.title) { model.addCustomAction(kind) }
                    }
                } label: {
                    Label("New Action", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button {
                    model.deleteSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canDeleteSelection)
                .help(model.canDeleteSelection
                      ? "Delete this action"
                      : "Built-in actions can be turned off but not deleted")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            selectedDetail
            Divider()
            // Always visible, whatever is selected. It was originally written as a section for the
            // editor and then never placed anywhere, which left shell and AppleScript actions
            // permanently unreachable — a switch that exists in the code and not on screen is the
            // same as no switch.
            Form {
                CodeExecutionSettingsSection(model: model)
                Section("Anywhere") {
                    Label("⌃⌥A opens these actions for whatever you have selected, in any app.",
                          systemImage: "keyboard")
                        .font(.callout)
                    Text("The toolbar appears on its own where an app tells macOS what you have selected. Many do not — this shortcut asks the app directly instead, so your actions are reachable everywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 250)
        }
    }

    @ViewBuilder
    private var selectedDetail: some View {
        if let action = model.selectedAction {
            if action.isBuiltIn {
                BuiltInActionDetail(action: action)
            } else {
                CustomActionEditor(model: model, action: action)
            }
        } else {
            VStack(spacing: 14) {
                Text("Select an action")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Or create one to run your own transformation, prompt, command or link on whatever you have selected.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }
}

// MARK: - Row

private struct ActionRow: View {
    let action: SelectionAction
    let isEnabled: Bool
    let isPinned: Bool
    let toggleEnabled: (Bool) -> Void
    let togglePinned: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { isEnabled }, set: toggleEnabled))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(isEnabled ? "Turn this action off" : "Turn this action on")

            Image(systemName: action.symbolName)
                .frame(width: 16)
                .foregroundStyle(isEnabled ? .primary : .tertiary)

            Text(action.title)
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if action.sideEffects == .runsCode {
                Image(systemName: "terminal")
                    .foregroundStyle(.orange)
                    .help("Runs a command on your Mac")
            }

            Button {
                togglePinned(!isPinned)
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(isPinned ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.borderless)
            .help(isPinned ? "Unpin — stop always showing this first" : "Pin — always show this first")
        }
    }
}

// MARK: - Built-in detail

private struct BuiltInActionDetail: View {
    let action: SelectionAction

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: action.title)
                LabeledContent("Type", value: action.kind.label)
                LabeledContent("Result", value: action.output.title)
                LabeledContent("Shown for", value: ActionsSettingsModel.describe(action.conditions))
            }

            Section {
                Text(ActionsSettingsModel.describe(action.sideEffects))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Built-in actions can be turned off, pinned and reordered, but not edited. To change how one behaves, create your own alongside it.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Editor

private struct CustomActionEditor: View {
    @ObservedObject var model: ActionsSettingsModel
    let action: SelectionAction

    var body: some View {
        Form {
            Section {
                TextField("Name", text: model.binding(for: action, \.title))
                Picker("Icon", selection: model.binding(for: action, \.symbolName)) {
                    ForEach(ActionsSettingsModel.iconChoices, id: \.self) { name in
                        Label(name, systemImage: name).tag(name)
                    }
                }
                Picker("Result", selection: model.binding(for: action, \.output)) {
                    ForEach(ActionOutput.allCases, id: \.self) { output in
                        Text(output.title).tag(output)
                    }
                }
            }

            Section(action.kind.label) {
                bodyEditor
                if let hint = ActionsSettingsModel.hint(for: action.kind) {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if action.sideEffects == .runsCode, !model.allowsCodeExecution {
                    Label("Turn on “Allow commands and scripts” below to run this.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Try it") {
                TextField("Sample text", text: $model.sampleText, axis: .vertical)
                    .lineLimit(1...4)
                HStack {
                    Button("Run") { model.test(action) }
                        .disabled(model.isTesting)
                    if model.isTesting { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let result = model.testResult {
                    Text(result.text)
                        .font(.callout)
                        .foregroundStyle(result.isFailure ? .red : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var bodyEditor: some View {
        switch action.kind {
        case .transform:
            Picker("Transformation", selection: model.transformBinding(for: action)) {
                ForEach(TextTransform.allCases, id: \.self) { transform in
                    Text(transform.title).tag(transform)
                }
            }
        case .prompt, .javaScript, .shell, .appleScript, .url:
            TextEditor(text: model.bodyBinding(for: action))
                .font(.system(.body, design: ActionsSettingsModel.isCode(action.kind) ? .monospaced : .default))
                .frame(minHeight: 96)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        }
    }
}

// MARK: - Code execution

struct CodeExecutionSettingsSection: View {
    @ObservedObject var model: ActionsSettingsModel

    var body: some View {
        Section("Commands and scripts") {
            Toggle("Allow commands and scripts", isOn: $model.allowsCodeExecution)
            Text("Shell and AppleScript actions run on your Mac with your own permissions. Only actions you write yourself can run — Glide never imports one from anywhere — but leave this off unless you use them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
