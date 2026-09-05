//
//  ModelSetupCoordinator.swift
//  KeyType
//
//  Orchestrates model setup for the onboarding wizard and the Model settings pane: it owns the
//  `ModelDownloadManager` (GGUF download/install/delete) and drives ACPF profile generation after a
//  model lands, exposing a single combined `SetupState` per catalog model.
//
//  NOTE: the upstream KeyType repository gitignores this file (it is the author's local glue between
//  the public `ModelManagement` package and the app). This is a faithful reconstruction from its call
//  sites in `AppDelegate`, `ModelSettingsView`, `SettingsView`, and `OnboardingView` — same public
//  surface, same behavior: download → prepare ACPF profile → ready, with pause/resume/cancel and
//  "import your own GGUF".
//

import Foundation
import ModelManagement
import ModelProfileGeneration
import ModelRuntime
import Observation
import os

@MainActor
@Observable
final class ModelSetupCoordinator {

    /// The combined, user-facing state of a catalog model: download progress, profile preparation,
    /// readiness, or failure. This is what the Settings/onboarding rows render.
    enum SetupState: Equatable {
        case idle
        case downloading(Double?)
        case paused(Double?)
        case preparingProfile
        case ready
        case failed(String)
    }

    /// State of an in-progress "import your own GGUF" operation.
    enum ImportState: Equatable {
        case idle
        case preparing(String)
    }

    /// Owns GGUF download/install/delete. `@Observable`, so progress changes flow to SwiftUI.
    let downloads = ModelDownloadManager()

    /// Called with the model filename once a model is fully ready (GGUF + valid ACPF profile). The
    /// app selects it and reloads the completion engine.
    var onModelReady: ((String) -> Void)?
    /// Called with a human-readable message when an *import* fails (shown as a modal alert).
    var onImportFailure: ((String) -> Void)?

    /// In-progress import, surfaced inline in the Model settings pane.
    private(set) var importState: ImportState = .idle

    var catalog: [DownloadableRuntimeModel] { downloads.catalog }

    // Observed bookkeeping (mutations notify SwiftUI via Observation).
    private var preparingFilenames: Set<String> = []
    private var readyFilenames: Set<String> = []
    private var failureMessages: [String: String] = [:]

    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "model-setup")

    init() {
        // When a download finishes, immediately build the ACPF profile so the model becomes usable
        // without a second click.
        downloads.onGGUFInstalled = { [weak self] model in
            self?.prepareProfile(for: model)
        }
        refresh()
    }

    // MARK: - Queries

    /// Re-read on-disk download + profile state. Called on appear and after deletes/imports.
    func refresh() {
        downloads.refreshStates()
        for model in catalog where downloads.isInstalled(filename: model.filename) {
            if profileExists(for: model) {
                readyFilenames.insert(model.filename)
            } else {
                readyFilenames.remove(model.filename)
            }
        }
    }

    func state(for model: DownloadableRuntimeModel) -> SetupState {
        if let message = failureMessages[model.filename] {
            return .failed(message)
        }
        let download = downloads.state(for: model)
        if download.isDownloading {
            return .downloading(download.progressFraction)
        }
        if download.isPaused {
            return .paused(download.progressFraction)
        }
        if preparingFilenames.contains(model.filename) {
            return .preparingProfile
        }
        if downloads.isInstalled(filename: model.filename) {
            return readyFilenames.contains(model.filename) ? .ready : .idle
        }
        return .idle
    }

    /// True when the GGUF is installed *and* its ACPF profile is present — i.e. the model can be
    /// loaded by the completion engine right now. Used by onboarding to enable "Continue".
    func isFullyInstalled(_ model: DownloadableRuntimeModel) -> Bool {
        downloads.isInstalled(filename: model.filename) && readyFilenames.contains(model.filename)
    }

    // MARK: - Actions

    /// Download (if needed) then prepare the model. For an already-downloaded GGUF this just (re)builds
    /// the ACPF profile.
    func beginSetup(for model: DownloadableRuntimeModel) {
        failureMessages[model.filename] = nil
        if downloads.isInstalled(filename: model.filename) {
            prepareProfile(for: model)
        } else {
            downloads.download(model) // `onGGUFInstalled` triggers profile prep when it lands
        }
    }

    func cancel(_ model: DownloadableRuntimeModel) {
        downloads.cancel(filename: model.filename)
        preparingFilenames.remove(model.filename)
    }

    func pause(_ model: DownloadableRuntimeModel) {
        downloads.pause(filename: model.filename)
    }

    func resume(_ model: DownloadableRuntimeModel) {
        downloads.resume(model)
    }

    /// Import a user-provided GGUF: copy it into the Models directory, build its ACPF profile, and on
    /// success make it the active model.
    func importModel(from sourceURL: URL) {
        let filename = sourceURL.lastPathComponent
        importState = .preparing(filename)
        Task { @MainActor in
            do {
                try await downloads.installLocalModel(from: sourceURL)
                _ = try await ProfileGenerator.generateProfileIfNeeded(forModelFilename: filename)
                readyFilenames.insert(filename)
                importState = .idle
                downloads.refreshStates()
                onModelReady?(filename)
            } catch {
                importState = .idle
                let message = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
                log.error("Model import failed: \(message, privacy: .public)")
                onImportFailure?(message)
            }
        }
    }

    // MARK: - Profile preparation

    private func prepareProfile(for model: DownloadableRuntimeModel) {
        guard !preparingFilenames.contains(model.filename) else { return }
        preparingFilenames.insert(model.filename)
        failureMessages[model.filename] = nil
        let filename = model.filename
        Task { @MainActor in
            do {
                _ = try await ProfileGenerator.generateProfileIfNeeded(forModelFilename: filename)
                preparingFilenames.remove(filename)
                readyFilenames.insert(filename)
                onModelReady?(filename)
            } catch {
                preparingFilenames.remove(filename)
                let message = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
                failureMessages[filename] = message
                log.error("Profile preparation failed for \(filename, privacy: .public): \(message, privacy: .public)")
            }
        }
    }

    private func profileExists(for model: DownloadableRuntimeModel) -> Bool {
        guard let url = try? ModelContainer.profileURL(family: model.tokenizerFamily, create: false) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
