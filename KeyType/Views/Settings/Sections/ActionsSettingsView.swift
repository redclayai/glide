//
//  ActionsSettingsView.swift
//  KeyType
//
//  The Actions pane: everything the selection toolbar can do, and the editor for the ones the user
//  writes.
//
//  Two halves. The list is about *arrangement* — what appears, what is pinned, what order — and works
//  identically for built-in and custom actions, because they are the same type underneath (ADR-137).
//  The editor is about *authorship*, and only custom actions have it: a built-in can be turned off or
//  reordered but never rewritten, because a corrupted built-in is a support problem where a corrupted
//  custom action is the user's own to fix.
//
//  On the visual design (ADR-142). The first version of this pane was thirty-five identical rows with
//  a checkbox column, a ghost pin on every one, and no hierarchy — a list you scan without reading.
//  Four things fixed it, none of them decoration:
//
//    * **Sections.** The grouping already existed in the data and the toolbar already used it; the
//      list simply was not reading it. Thirty-five rows became seven short ones.
//    * **A second line.** Each row says what kind of action it is, so the list can be read rather
//      than only scanned.
//    * **Affordances on hover.** A pin is shown when it is set or when the pointer is on the row.
//      Thirty-five permanent ghost pins is noise that teaches nothing.
//    * **A footer, not a second form.** The global switches were a `Form` stacked under the detail
//      pane with its own background, which read as a different app bolted on. They belong to the pane,
//      not to the selected action, so they sit in a quiet strip across the bottom of it.
//
//  Deliberately *not* borrowed from the web-gallery references that prompted this: dark gradient
//  surfaces, display-weight type, card grids. This is a macOS Settings window, and the thing that
//  makes one look unfinished is missing hierarchy and rhythm, not missing ornament.
//

import SelectionActions
import SwiftUI

struct ActionsSettingsView: View {
    @ObservedObject var model: ActionsSettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                list
                    .frame(minWidth: 260, idealWidth: 290, maxWidth: 360)
                detail
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedID) {
                ForEach(model.sections) { section in
                    Section {
                        ForEach(section.actions) { action in
                            ActionRow(
                                action: action,
                                isEnabled: model.isEnabled(action),
                                isPinned: model.isPinned(action),
                                toggleEnabled: { model.setEnabled($0, for: action) },
                                togglePinned: { model.setPinned($0, for: action) }
                            )
                            .tag(action.id as String?)
                        }
                    } header: {
                        Text(section.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 38)

            Divider()
            listToolbar
        }
    }

    private var listToolbar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(ActionsSettingsModel.NewActionKind.allCases, id: \.self) { kind in
                    Button(kind.title) { model.addCustomAction(kind) }
                }
            } label: {
                Label("New Action", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button {
                model.deleteSelected()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(!model.canDeleteSelection)
            .help(model.canDeleteSelection
                  ? "Delete this action"
                  : "Built-in actions can be turned off but not deleted")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let action = model.selectedAction {
            if action.isBuiltIn {
                BuiltInActionDetail(action: action)
            } else {
                CustomActionEditor(model: model, action: action)
            }
        } else {
            EmptyStateView()
        }
    }

    // MARK: - Footer

    /// Belongs to the pane rather than to any one action, so it sits across the bottom of both
    /// columns rather than inside the detail.
    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Toggle(isOn: $model.allowsCodeExecution) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Allow commands and scripts")
                        .font(.system(size: 12, weight: .medium))
                    Text("Shell and AppleScript run with your permissions. Only actions you write yourself can run.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider().frame(height: 26)

            HStack(spacing: 6) {
                KeyCapView(keys: ["⌃", "⌥", "A"])
                Text("Open these anywhere")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .help("Works in every app, including ones that don't tell macOS what you have selected.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Row

private struct ActionRow: View {
    let action: SelectionAction
    let isEnabled: Bool
    let isPinned: Bool
    let toggleEnabled: (Bool) -> Void
    let togglePinned: (Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            // A fixed tile rather than a bare glyph, because SF Symbols differ wildly in optical
            // weight and width — "Aa" and "scissors" set next to each other in a list do not line up
            // on anything without one.
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.secondary.opacity(isEnabled ? 0.18 : 0.08))
                Image(systemName: action.symbolName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isEnabled ? Color.primary.opacity(0.9) : Color.secondary)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isEnabled ? .primary : .tertiary)
                    .lineLimit(1)
                Text(ActionsSettingsModel.subtitle(for: action))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if action.sideEffects == .runsCode {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Runs a command on your Mac")
            }

            // Shown when it is set, or when the pointer is here. A permanent ghost pin on every row
            // is noise that teaches nothing.
            if isPinned || isHovering {
                Button { togglePinned(!isPinned) } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(isPinned ? "Unpin" : "Pin — always show this first")
            }

            Toggle("", isOn: Binding(get: { isEnabled }, set: toggleEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

// MARK: - Key cap

/// The shortcut set as keys rather than as a run of symbols in a sentence, which is how the system
/// draws one and the only way ⌃⌥A reads as something you press.
private struct KeyCapView: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, weight: .medium))
                    .frame(minWidth: 16, minHeight: 16)
                    .padding(.horizontal, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.14))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
                    )
            }
        }
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.10)).frame(width: 52, height: 52)
                Image(systemName: "bolt")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text("No action selected")
                .font(.system(size: 14, weight: .medium))
            Text("Pick one to see what it does, or create your own to run a transformation, prompt, command or link on whatever you have selected.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

// MARK: - Built-in detail

private struct BuiltInActionDetail: View {
    let action: SelectionAction

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(action: action)
                Divider().padding(.vertical, 16)

                DetailRow(label: "Type", value: action.kind.label)
                DetailRow(label: "Result", value: action.output.title)
                DetailRow(label: "Shown for", value: ActionsSettingsModel.describe(action.conditions))
                DetailRow(label: "Privacy", value: ActionsSettingsModel.describe(action.sideEffects))

                Divider().padding(.vertical, 16)

                Text("Built-in actions can be turned off, pinned and reordered, but not edited. To change how one behaves, create your own alongside it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DetailHeader: View {
    let action: SelectionAction

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: action.symbolName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 17, weight: .semibold))
                Text(ActionsSettingsModel.subtitle(for: action))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Editor

private struct CustomActionEditor: View {
    @ObservedObject var model: ActionsSettingsModel
    let action: SelectionAction

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DetailHeader(action: action)

                FieldGroup("Name") {
                    TextField("", text: model.binding(for: action, \.title))
                        .textFieldStyle(.roundedBorder)
                }

                HStack(alignment: .top, spacing: 14) {
                    FieldGroup("Icon") {
                        Picker("", selection: model.binding(for: action, \.symbolName)) {
                            ForEach(ActionsSettingsModel.iconChoices, id: \.self) { name in
                                Image(systemName: name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 84)
                    }
                    FieldGroup("Result") {
                        Picker("", selection: model.binding(for: action, \.output)) {
                            ForEach(ActionOutput.allCases, id: \.self) { output in
                                Text(output.title).tag(output)
                            }
                        }
                        .labelsHidden()
                    }
                }

                FieldGroup(action.kind.label) {
                    bodyEditor
                    if let hint = ActionsSettingsModel.hint(for: action.kind) {
                        Text(hint)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if action.sideEffects == .runsCode, !model.allowsCodeExecution {
                        Label("Turn on “Allow commands and scripts” below to run this.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                    }
                }

                FieldGroup("Try it") {
                    TextField("Sample text", text: $model.sampleText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    HStack(spacing: 8) {
                        Button("Run") { model.test(action) }
                            .controlSize(.small)
                            .disabled(model.isTesting)
                        if model.isTesting { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if let result = model.testResult {
                        Text(result.text)
                            .font(.system(size: 12))
                            .foregroundStyle(result.isFailure ? Color.red : Color.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.secondary.opacity(0.08))
                            )
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var bodyEditor: some View {
        switch action.kind {
        case .transform:
            Picker("", selection: model.transformBinding(for: action)) {
                ForEach(TextTransform.allCases, id: \.self) { transform in
                    Text(transform.title).tag(transform)
                }
            }
            .labelsHidden()
        case .prompt, .javaScript, .shell, .appleScript, .url:
            TextEditor(text: model.bodyBinding(for: action))
                .font(.system(size: 12, design: ActionsSettingsModel.isCode(action.kind) ? .monospaced : .default))
                .frame(minHeight: 92)
                .scrollContentBackground(.hidden)
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 0.5)
                )
        }
    }
}

/// A label above its control, with the label set small and secondary. One spacing rule for every
/// field is most of what a form needs to stop looking assembled.
private struct FieldGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
