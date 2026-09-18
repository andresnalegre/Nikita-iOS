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
        static let mcpEnabled = "nikita.mcp.enabled"
        static let mcpServers = "nikita.mcp.servers"
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

    // One switch per family, in the order the settings screen shows them.
    // Mirrors the desktop's groups so the same question is asked the same way
    // in both places: reading, changing and deleting are separate permissions,
    // because they are separate risks.
    public struct Family: Sendable {
        public let id: String
        public let label: String
        public let blurb: String
        // Off unless the user turns it on. Reserved for the ones that reach
        // past the Flipper -- the computer, and running commands.
        public let defaultsOff: Bool

        public init(
            id: String, label: String, blurb: String, defaultsOff: Bool = false
        ) {
            self.id = id
            self.label = label
            self.blurb = blurb
            self.defaultsOff = defaultsOff
        }
    }

    public static let families: [Family] = [
        .init(id: "memory", label: "Memory",
              blurb: "Remember and forget facts about you."),
        .init(id: "files", label: "Flipper: read",
              blurb: "List folders and read files on the Flipper."),
        .init(id: "files_write", label: "Flipper: create and change",
              blurb: "Write files, create folders and rename on the Flipper."),
        .init(id: "files_delete", label: "Flipper: delete",
              blurb: "Delete files and folders on the Flipper."),
        .init(id: "screen", label: "Flipper: screen",
              blurb: "Read what is on the Flipper's display."),
        .init(id: "buttons", label: "Flipper: buttons",
              blurb: "Press the Flipper's buttons."),
        .init(id: "apps", label: "Flipper: apps",
              blurb: "Open and close apps on the Flipper."),
        .init(id: "web", label: "Web search",
              blurb: "Search the web and read pages."),
        .init(id: "serial", label: "Flipper: serial CLI",
              blurb: "Run the Flipper's own text commands through a bridge on "
              + "your computer. Reaches sub-GHz, NFC, GPIO and infrared.",
              defaultsOff: true),
        .init(id: "computer_read", label: "Computer: read",
              blurb: "List folders and read files on the bridged computer.",
              defaultsOff: true),
        .init(id: "computer_write", label: "Computer: create and change",
              blurb: "Write files and create folders on the bridged computer.",
              defaultsOff: true),
        .init(id: "computer_delete", label: "Computer: delete",
              blurb: "Delete files and folders on the bridged computer.",
              defaultsOff: true),
        .init(id: "computer_run", label: "Computer: run commands",
              blurb: "Run terminal commands on the bridged computer. The "
              + "widest access on this list.",
              defaultsOff: true)
    ]

    public static let filterableTools: [String] = families.map(\.id)

    public func isAllowed(_ family: String) -> Bool {
        let key = Keys.filterPrefix + family
        if defaults.object(forKey: key) == nil {
            // Never asked: the Flipper families are on, anything that reaches
            // the computer is off until it is switched on deliberately.
            return !(Self.families.first { $0.id == family }?.defaultsOff ?? false)
        }
        return defaults.bool(forKey: key)
    }

    public func setAllowed(_ family: String, _ on: Bool) {
        defaults.set(on, forKey: Keys.filterPrefix + family)
    }

    public func setAllFilters(_ on: Bool) {
        for f in Self.filterableTools { setAllowed(f, on) }
    }

    // MARK: MCP servers
    //
    // The list itself is ordinary configuration and lives in UserDefaults. The
    // per-server token does not: it is a credential, so it goes in the Keychain
    // beside the API key, and nothing hands it back to the UI except a
    // deliberate reveal.

    public var mcpEnabled: Bool {
        get {
            // On by default. A configured server the user has to remember to
            // switch on is a server that silently does nothing.
            if defaults.object(forKey: Keys.mcpEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.mcpEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.mcpEnabled) }
    }

    public var mcpServers: [NikitaMcp.Server] {
        get {
            guard let data = defaults.data(forKey: Keys.mcpServers),
                  let list = try? JSONDecoder().decode(
                    [NikitaMcp.Server].self, from: data)
            else { return [] }
            return list
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.mcpServers)
        }
    }

    public func addOrUpdateMcpServer(
        _ server: NikitaMcp.Server, token: String?
    ) {
        var list = mcpServers
        if let i = list.firstIndex(where: { $0.name == server.name }) {
            list[i] = server
        } else {
            list.append(server)
        }
        mcpServers = list
        if let token { setMcpToken(token, for: server.name) }
    }

    public func removeMcpServer(named name: String) {
        mcpServers = mcpServers.filter { $0.name != name }
        setMcpToken("", for: name)
    }

    public func mcpToken(for server: String) -> String {
        readKeychain(account: mcpAccount(server))
    }

    public func setMcpToken(_ token: String, for server: String) {
        let account = mcpAccount(server)
        deleteKeychain(account: account)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        writeKeychain(trimmed, account: account)
    }

    private func mcpAccount(_ server: String) -> String {
        "one.flipper.nikita.mcp.\(server)"
    }

    // MARK: API key (Keychain)

    public var hasApiKey: Bool { !revealApiKey().isEmpty }

    public func setApiKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        deleteKeychain(account: keychainAccount)
        guard !trimmed.isEmpty else { return }
        writeKeychain(trimmed, account: keychainAccount)
    }

    public func revealApiKey() -> String {
        readKeychain(account: keychainAccount)
    }

    public func clearApiKey() { deleteKeychain(account: keychainAccount) }

    // MARK: Brave Search key (optional; enables robust ranked web search)

    private var braveAccount: String { "one.flipper.nikita.bravekey" }
    public var braveKey: String { readKeychain(account: braveAccount) }
    public var hasBraveKey: Bool { !braveKey.isEmpty }
    public func setBraveKey(_ key: String) {
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        deleteKeychain(account: braveAccount)
        if !t.isEmpty { writeKeychain(t, account: braveAccount) }
    }
    public func clearBraveKey() { deleteKeychain(account: braveAccount) }

    // One set of Keychain calls, used by the API key and by every MCP token.

    private func writeKeychain(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func readKeychain(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else { return "" }
        return value
    }

    private func deleteKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Wipe everything (erase == disconnect, like the desktop)

    public func wipe() {
        clearApiKey()
        for server in mcpServers { setMcpToken("", for: server.name) }
        clearBraveKey()
        defaults.removeObject(forKey: Keys.mcpServers)
        defaults.removeObject(forKey: Keys.mcpEnabled)
        enabled = false
        setAllFilters(false)
        defaults.removeObject(forKey: Keys.model)
    }
}
