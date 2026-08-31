import Foundation

// The chat as the UI sees it. The wire history the model sees is a separate,
// richer structure (NikitaWireMessage) so tool_calls / tool results round-trip
// correctly; a ChatMessage is only what a human reads.
public struct NikitaChatMessage: Identifiable, Equatable {
    public enum Role: String { case user, assistant, tool, error, system }
    public let id = UUID()
    public var role: Role
    public var text: String
    public var toolCalls: [NikitaToolInvocation]
    public var date: Date

    public init(
        role: Role,
        text: String,
        toolCalls: [NikitaToolInvocation] = [],
        date: Date = .init()
    ) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.date = date
    }
}

// One tool the assistant asked to run this turn, plus how it went -- rendered as
// an expandable row under the answer, exactly like the desktop chat.
public struct NikitaToolInvocation: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var argumentsJSON: String
    public var result: String
    public var ok: Bool

    public init(
        id: String,
        name: String,
        argumentsJSON: String,
        result: String = "",
        ok: Bool = true
    ) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.result = result
        self.ok = ok
    }

    // A compact, human label like `save_file(path=/ext/badusb/x.txt)`.
    public var pretty: String {
        guard
            let data = argumentsJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            !obj.isEmpty
        else { return "\(name)()" }
        let parts = obj.keys.sorted().map { key -> String in
            let v = obj[key]
            var s = "\(v ?? "")"
            if s.count > 40 { s = String(s.prefix(40)) + "…" }
            return "\(key)=\(s)"
        }
        return "\(name)(\(parts.joined(separator: ", ")))"
    }
}

// Token/cost accounting for the footer line. Prices are per-million tokens.
public struct NikitaUsage: Equatable {
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0
    public var turnCostUSD: Double = 0
    public var sessionCostUSD: Double = 0
}
