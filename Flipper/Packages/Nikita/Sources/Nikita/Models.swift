import Foundation

// Something the user attached to a message for Nikita to look at: an image
// (sent to Kimi as a vision part -- K2.6+ are natively multimodal), or a file
// whose text is folded into the prompt. `dataURL` is a base64 data: URL used
// both to show a thumbnail and, for images, as the vision payload.
public struct NikitaAttachment: Identifiable, Equatable {
    public enum Kind: String { case image, text, file }
    public let id = UUID()
    public var kind: Kind
    public var filename: String
    public var mime: String
    // For images: a data:<mime>;base64,<...> URL. Empty for pure-text files.
    public var dataURL: String
    // For text files: the readable contents, inlined into the prompt.
    public var textContent: String
    // Raw bytes count, for the "file (12 KB)" label on non-image files.
    public var byteCount: Int

    public init(
        kind: Kind,
        filename: String,
        mime: String,
        dataURL: String = "",
        textContent: String = "",
        byteCount: Int = 0
    ) {
        self.kind = kind
        self.filename = filename
        self.mime = mime
        self.dataURL = dataURL
        self.textContent = textContent
        self.byteCount = byteCount
    }
}

// The chat as the UI sees it. The wire history the model sees is a separate,
// richer structure (NikitaWireMessage) so tool_calls / tool results round-trip
// correctly; a ChatMessage is only what a human reads.
public struct NikitaChatMessage: Identifiable, Equatable {
    public enum Role: String { case user, assistant, tool, error, system }
    public let id = UUID()
    public var role: Role
    public var text: String
    public var toolCalls: [NikitaToolInvocation]
    public var attachments: [NikitaAttachment]
    public var date: Date

    public init(
        role: Role,
        text: String,
        toolCalls: [NikitaToolInvocation] = [],
        attachments: [NikitaAttachment] = [],
        date: Date = .init()
    ) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.attachments = attachments
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
