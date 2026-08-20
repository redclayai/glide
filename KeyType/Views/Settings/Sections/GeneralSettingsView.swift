//
//  GeneralSettingsView.swift
//  Glide
//
//  The "General" Settings pane: completion length. Split out of SettingsView so each sidebar
//  category lives in its own file.
//

import LaunchAtLogin
import Proofreading
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("Startup") {
                LaunchAtLogin.Toggle()
                Text("Start Glide automatically when you log in to your Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Completion length") {
                Picker("Length", selection: $settings.completionLength) {
                    ForEach(CompletionLength.allCases) { length in
                        Text(length.title).tag(length)
                    }
                }
                .pickerStyle(.segmented)
                Text("Shorter completions are more conservative; longer ones suggest more at once.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Rewrite") {
                Toggle("Fix the word I just typed", isOn: $settings.proofreadEnabled)
                Text("When you finish a misspelled word, the correction appears under the cursor — press Tab to take it. Instant, offline, no model.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("Fix the grammar of the sentence I just finished", isOn: $settings.aiGrammarEnabled)
                Text("At the end of a sentence, the local model proposes a grammar fix the same way. Only runs if you pause, only when the spelling pass found nothing, and only if the result is a correction rather than a rewrite.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            GrammarBackendSettingsView(settings: settings, keys: APIKeyStore())

            Section("Selection actions") {
                Toggle("Polish & Grammar on selected text", isOn: $settings.selectionActionsEnabled)
                Text("Select text, then press ⌃⌥P to polish or ⌃⌥G to fix grammar — works in any app. In apps that expose their selection (TextEdit, Mail, Pages…) a popover also appears with the same actions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
