//
//  SetupSettingsView.swift
//  KeyType
//
//  The "Setup" Settings pane: a shortcut back into the onboarding wizard. Split out of SettingsView
//  so each sidebar category lives in its own file.
//

import SwiftUI

struct SetupSettingsView: View {
    let runSetupAgain: () -> Void

    var body: some View {
        Form {
            Section("Setup") {
                Button("Run setup again…") { runSetupAgain() }
            }
        }
        .formStyle(.grouped)
    }
}
