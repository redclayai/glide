//
//  RewriteBackend.swift
//  Proofreading
//
//  Which engine answers the grammar question. The spelling pass is always the on-device dictionary;
//  this is only about the sentence-level rewrite.
//
//  The local model is the default and stays the default. It is free, it is ~90 ms, and it works with
//  the network off — the last of which is the property most worth protecting, since the whole app
//  is otherwise a keylogger-shaped thing that never phones home. A cloud backend is opt-in, needs a
//  key the user pastes themselves, and is labelled as sending text off the machine wherever it is
//  configured.
//
//  Whatever answers, the result goes through `ModelRewriteGate` unchanged. A frontier model is far
//  likelier to produce a *good* sentence, which is precisely why it still has to be checked for
//  being a *correction* — "better writing" is a different feature, and one the user did not ask for
//  when they paused mid-sentence.
//

import Foundation
import Security

public enum RewriteBackend: String, CaseIterable, Sendable, Codable {
    case local
    case anthropic
    case gemini

    public var title: String {
        switch self {
        case .local: return "On this Mac"
        case .anthropic: return "Claude"
        case .gemini: return "Gemini"
        }
    }

    public var sendsTextOffTheMachine: Bool { self != .local }

    /// Sensible starting model. Editable in Settings, because provider model names change more often
    /// than this app ships and a hardcoded name that 404s looks like a broken feature.
    public var defaultModel: String {
        switch self {
        case .local: return ""
        case .anthropic: return "claude-haiku-4-5"
        case .gemini: return "gemini-2.5-flash"
        }
    }

    /// Where to get a key, shown next to the field so the user is not left guessing.
    public var keyURL: URL? {
        switch self {
        case .local: return nil
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        }
    }
}

/// API keys live in the Keychain, never in `UserDefaults` — a preference plist is world-readable by
/// anything running as the user, and this is a credential that can spend money.
public struct APIKeyStore: Sendable {
    private let service: String

    public init(service: String = "app.glide.apikeys") {
        self.service = service
    }

    public func key(for backend: RewriteBackend) -> String? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: backend.rawValue,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        query.removeAll()
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty == false) ? key : nil
    }

    public func setKey(_ key: String?, for backend: RewriteBackend) {
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: backend.rawValue,
        ]
        SecItemDelete(base as CFDictionary)

        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = key.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)
        else { return }

        var add = base
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    public func hasKey(for backend: RewriteBackend) -> Bool {
        key(for: backend) != nil
    }
}
