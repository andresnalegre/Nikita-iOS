import Foundation
import Security

// API key, chosen model, and the per-tool access filters. The key lives in the
// Keychain (there is no MOONSHOT_API_KEY env var on iOS), and like the desktop
// it is write-only to the UI: revealApiKey exists for a deliberate "show", but
// the normal getter the agent uses returns presence, not the value in the view.
public final class NikitaSettings {
    public static let shared = NikitaSettings()

    private let keychainAccount = "one.flipper.nikita.apikey"
    private let keychainService = "one.flipper.nikita"
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let model = "nikita.model"
        static let enabled = "nikita.enabled"
        static let filterPrefix = "nikita.filter."
    }

    private init() {}

    // MARK: Model

    public var model: String {
        get { defaults.string(forKey: Keys.model) ?? KimiClient.models[0].id }
        set { defaults.set(newValue, forKey: Keys.model) }
    }

    // MARK: Enabled (assistant off until the user turns it on)

    public var enabled: Bool {
        get { defaults.bool(forKey: Keys.enabled) }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    // MARK: Access filters -- one switch per tool family, all default on.

    public static let filterableTools: [String] = [
        "files", "screen", "buttons", "apps", "memory"
    ]

    public func isAllowed(_ family: String) -> Bool {
        let key = Keys.filterPrefix + family
        if defaults.object(forKey: key) == nil { return true }
        return defaults.bool(forKey: key)
    }

    public func setAllowed(_ family: String, _ on: Bool) {
        defaults.set(on, forKey: Keys.filterPrefix + family)
    }

    public func setAllFilters(_ on: Bool) {
        for f in Self.filterableTools { setAllowed(f, on) }
    }

    // MARK: API key (Keychain)

    public var hasApiKey: Bool { !revealApiKey().isEmpty }

    public func setApiKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        deleteKey()
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    public func revealApiKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let key = String(data: data, encoding: .utf8)
        else { return "" }
        return key
    }

    public func clearApiKey() { deleteKey() }

    private func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Wipe everything (erase == disconnect, like the desktop)

    public func wipe() {
        clearApiKey()
        enabled = false
        setAllFilters(false)
        defaults.removeObject(forKey: Keys.model)
    }
}
