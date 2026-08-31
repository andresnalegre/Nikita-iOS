import Foundation

// The Moonshot Kimi client. OpenAI-compatible /chat/completions, non-streamed --
// same decision as the desktop: a tool call assembled from a half-received SSE
// stream is the exact failure that is not worth the typing effect. One request,
// one JSON reply, parsed whole.
public struct KimiClient {
    public struct Model: Identifiable, Hashable {
        public let id: String
        public let label: String
        // Published Kimi rates, US dollars per million tokens.
        public let inputPerM: Double
        public let outputPerM: Double
    }

    // The account's GA default first; k3 is the preview flagship (rate-limited).
    public static let models: [Model] = [
        .init(id: "kimi-k2.6", label: "Kimi K2.6", inputPerM: 0.60, outputPerM: 2.50),
        .init(id: "kimi-k2.7", label: "Kimi K2.7", inputPerM: 0.60, outputPerM: 2.50),
        .init(id: "kimi-k3",   label: "Kimi K3",   inputPerM: 1.20, outputPerM: 5.00)
    ]

    public static func model(for id: String) -> Model {
        models.first { $0.id == id } ?? models[0]
    }

    static let endpoint = URL(string: "https://api.moonshot.ai/v1/chat/completions")!
    static let maxTokens = 4096

    public struct Reply {
        public var content: String
        public var toolCalls: [RawToolCall]
        public var promptTokens: Int
        public var completionTokens: Int
    }

    public struct RawToolCall {
        public var id: String
        public var name: String
        public var argumentsJSON: String
    }

    public enum ClientError: LocalizedError {
        case noKey
        case http(Int, String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .noKey:
                return "No API key. Add your Moonshot key in Nikita settings."
            case .http(let code, let body):
                return "Kimi API error \(code): \(body)"
            case .malformed(let why):
                return "Unexpected reply from Kimi: \(why)"
            }
        }
    }

    let apiKey: String
    let model: String
    let session: URLSession

    public init(apiKey: String, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public func complete(
        messages: [[String: Any]],
        tools: [[String: Any]]
    ) async throws -> Reply {
        guard !apiKey.isEmpty else { throw ClientError.noKey }

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
            "max_tokens": Self.maxTokens
        ]
        if !tools.isEmpty {
            body["tools"] = tools
        }
        // No temperature/top_p: k3 rejects any explicit value ("only 1 allowed"),
        // and hardcoding the one value it accepts today only goes stale. Let the
        // server use the value the model was tuned with.

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.malformed("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.http(http.statusCode, String(text.prefix(400)))
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ClientError.malformed("not a JSON object")
        }

        let usage = root["usage"] as? [String: Any]
        let promptTokens = (usage?["prompt_tokens"] as? Int) ?? 0
        let completionTokens = (usage?["completion_tokens"] as? Int) ?? 0

        guard
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            throw ClientError.malformed("no choices")
        }

        let content = (message["content"] as? String) ?? ""

        var calls: [RawToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for (i, c) in rawCalls.enumerated() {
                let fn = c["function"] as? [String: Any]
                let name = (fn?["name"] as? String) ?? ""
                let args = (fn?["arguments"] as? String) ?? "{}"
                let id = (c["id"] as? String) ?? "call_\(i)"
                guard !name.isEmpty else { continue }
                calls.append(.init(id: id, name: name, argumentsJSON: args))
            }
        }

        return Reply(
            content: content,
            toolCalls: calls,
            promptTokens: promptTokens,
            completionTokens: completionTokens)
    }
}
