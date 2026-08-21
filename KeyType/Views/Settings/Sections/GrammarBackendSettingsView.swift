//
//  GrammarBackendSettingsView.swift
//  Glide
//
//  Chooses which engine answers the grammar question, and holds the key for it.
//
//  The privacy note is not decoration. Until you pick a hosted model, Glide reads everything you
//  type and sends none of it anywhere; afterwards it sends finished sentences to a third party. That
//  is a real change in what the app is, and the person making the change should be told plainly
//  rather than discovering it later.
//

import Proofreading
import SwiftUI

struct GrammarBackendSettingsView: View {
    @Bindable var settings: SettingsStore
    let keys: APIKeyStore

    @State private var keyField = ""
    @State private var checkResult: CheckResult?
    @State private var isChecking = false

    private enum CheckResult: Equatable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        Section("Rewrite engine") {
            Picker("Answered by", selection: $settings.grammarBackend) {
                ForEach(RewriteBackend.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .onChange(of: settings.grammarBackend) { _, backend in
                keyField = keys.key(for: backend) ?? ""
                checkResult = nil
            }

            switch settings.grammarBackend {
            case .local:
                Text("Runs on this Mac. Free, works offline, and nothing you type leaves the machine. Used for grammar fixes and for Polish & Grammar on a selection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case .anthropic, .gemini:
                Text("Better corrections, but each one is a paid request and the text is sent to \(settings.grammarBackend.title). Used for grammar fixes and for Polish & Grammar on a selection. Password fields are never sent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                LabeledContent("Model") {
                    TextField("Model", text: $settings.grammarModel, prompt: Text(settings.grammarBackend.defaultModel))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }

                LabeledContent("API key") {
                    HStack(spacing: 8) {
                        SecureField("Paste your key", text: $keyField)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey)
                            .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                HStack(spacing: 10) {
                    Button(isChecking ? "Testing…" : "Test") { Task { await runCheck() } }
                        .disabled(isChecking || !keys.hasKey(for: settings.grammarBackend))
                    if let url = settings.grammarBackend.keyURL {
                        Link("Get a key", destination: url).font(.footnote)
                    }
                }

                // The provider's own error text, verbatim: a wrong key and a renamed model both
                // present as "nothing happens" otherwise, and they need different fixes.
                switch checkResult {
                case let .success(text):
                    Label("Working — returned \u{201C}\(text)\u{201D}", systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.green)
                case let .failure(message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                case nil:
                    EmptyView()
                }
            }
        }
        .onAppear { keyField = keys.key(for: settings.grammarBackend) ?? "" }
    }

    private func saveKey() {
        keys.setKey(keyField, for: settings.grammarBackend)
        checkResult = nil
    }

    private func runCheck() async {
        isChecking = true
        defer { isChecking = false }

        let backend = settings.grammarBackend
        let model = settings.grammarModel
        let keys = keys
        let rewriter = CloudSentenceRewriter(
            backend: backend,
            model: { model },
            apiKey: { keys.key(for: backend) },
            debounceNanoseconds: 0,
            unterminatedDebounceNanoseconds: 0
        )
        do {
            checkResult = .success(try await rewriter.check())
        } catch {
            checkResult = .failure(error.localizedDescription)
        }
    }
}
