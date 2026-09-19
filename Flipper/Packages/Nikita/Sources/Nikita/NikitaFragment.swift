//
// NikitaFragment.swift
//
// A FRAGMENT of Nikita: the same intelligence, spun off to work one
// self-contained sub-task in PARALLEL with the main chat. It is not a
// different assistant -- it carries Nikita's identity and her memory -- it
// just runs its own small turn loop, on its own, so more than one thing can
// happen at the same time. This is the iPhone half of "N agentes completos",
// mirroring qFlipper's NikitaTaskAgent.
//
// Deliberately narrow: it gets the web (search + fetch) and the bridged
// computer's shell (computer_run), which is all a background research/build
// fragment needs. It does NOT touch the Flipper -- the one physical device is
// the main agent's to drive, and serialising device access through fragments
// would only fight itself.
//

import Foundation

@MainActor
public final class NikitaFragment: ObservableObject, Identifiable {
    public enum State: String { case running, done, failed, stopped }

    public let id: Int
    public let title: String
    public let task: String

    @Published public private(set) var state: State = .running
    @Published public private(set) var status: String = "starting"
    @Published public private(set) var result: String = ""
    @Published public private(set) var rounds: Int = 0

    private let apiKey: String
    private let model: String
    private let braveKey: String
    private let memory: [String]
    private let machine: NikitaMachineBridge?
    private var work: Task<Void, Never>?

    // A fragment is a burst of focused work, not an open-ended session. High
    // enough for real multi-step research or a few file builds; bounded so a
    // fragment that loses the thread cannot run forever in the background.
    private let maxRounds = 40

    private var onChange: (() -> Void)?

    public init(
        id: Int,
        title: String,
        task: String,
        apiKey: String,
        model: String,
        braveKey: String,
        memory: [String],
        machine: NikitaMachineBridge?,
        onChange: (() -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.task = task
        self.apiKey = apiKey
        self.model = model
        self.braveKey = braveKey
        self.memory = memory
        self.machine = machine
        self.onChange = onChange
    }

    public func setOnChange(_ cb: @escaping () -> Void) {
        onChange = cb
    }

    public func start() {
        guard work == nil else { return }
        work = Task { await self.run() }
    }

    public func stop() {
        guard state == .running else { return }
        work?.cancel()
        finish(.stopped, "Stopped by the user.")
    }

    // MARK: identity

    // The fragment is told, plainly, that it IS Nikita -- a piece of her, not a
    // helper -- and handed her memory, so nothing it produces reads as a
    // stranger's work. The task itself is the whole brief; it cannot see the
    // chat, so everything it needs is in `task`.
    private func systemPrompt() -> String {
        var s = """
        You ARE Nikita -- the SAME sharp, low-key hacker intelligence as the \
        main assistant, not a different one. Right now you are running as a \
        FRAGMENT of yourself: split off to work ONE task in the background, in \
        parallel with your main self, so more than one thing gets done at once.

        You cannot see the main conversation -- the task below is your whole \
        brief. Work it end to end on your own and return a complete, useful \
        result. Your tools: web_search, web_fetch, http_request (call any \
        API/webhook), python_run (charts/images/data/PDF/binaries in Nikita's \
        env) and, when a computer is bridged, its shell (computer_run) -- use \
        them; do not claim you cannot. LOOK before you change and VERIFY by \
        running it, not "it should work". Be thorough but tight: deliver the \
        answer, no filler. When the task is genuinely finished, stop calling \
        tools and write the final result as your reply.

        YOUR TASK:
        \(task)
        """
        if !memory.isEmpty {
            s += "\n\nWhat you (Nikita) remember about the user:\n"
            s += memory.map { "- \($0)" }.joined(separator: "\n")
        }
        return s
    }

    private var tools: [[String: Any]] {
        [
            NikitaTools.function(
                "web_search",
                "Search the web; returns top results (title, url, snippet).",
                properties: ["query": NikitaTools.str("What to search for.")],
                required: ["query"]),
            NikitaTools.function(
                "web_fetch",
                "Fetch one web page or text/JSON URL and return its readable "
                + "text. http/https only.",
                properties: ["url": NikitaTools.str("The full URL to fetch.")],
                required: ["url"]),
            NikitaTools.function(
                "computer_run",
                "Run a terminal command on the bridged computer and return its "
                + "output. Only if a computer is bridged.",
                properties: [
                    "command": NikitaTools.str("The shell command to run.")
                ],
                required: ["command"]),
            NikitaTools.function(
                "python_run",
                "Run Python 3 in Nikita's env on the bridged computer "
                + "(matplotlib/pandas/Pillow/cairosvg/pypdf/qrcode). Best for "
                + "charts, images, data, PDF, binaries.",
                properties: ["code": NikitaTools.str("The Python 3 source.")],
                required: ["code"]),
            NikitaTools.function(
                "http_request",
                "HTTP request to any URL (method/headers/body); returns "
                + "status+body. A real API client, works without a bridge.",
                properties: [
                    "url": NikitaTools.str("Full http/https URL."),
                    "method": NikitaTools.str("GET/POST/PUT/PATCH/DELETE."),
                    "body": NikitaTools.str("Optional request body.")
                ],
                required: ["url"])
        ]
    }

    // MARK: loop

    private func run() async {
        guard !apiKey.isEmpty else {
            finish(.failed, "No API key.")
            return
        }
        let client = KimiClient(apiKey: apiKey, model: model)
        var wire: [[String: Any]] = [
            ["role": "system", "content": systemPrompt()],
            ["role": "user", "content": task]
        ]

        while rounds < maxRounds {
            if Task.isCancelled { return }
            rounds += 1
            setStatus("thinking")

            let reply: KimiClient.Reply
            do {
                reply = try await client.complete(messages: wire, tools: tools)
            } catch {
                finish(.failed, "API error: \(error.localizedDescription)")
                return
            }
            if Task.isCancelled { return }

            if reply.toolCalls.isEmpty {
                let text = reply.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                finish(.done, text.isEmpty ? "(done)" : text)
                return
            }

            // Record the assistant turn with its tool calls.
            var assistant: [String: Any] = ["role": "assistant"]
            if !reply.content.isEmpty { assistant["content"] = reply.content }
            assistant["tool_calls"] = reply.toolCalls.map { c in
                [
                    "id": c.id,
                    "type": "function",
                    "function": [
                        "name": c.name,
                        "arguments": c.argumentsJSON
                    ]
                ]
            }
            wire.append(assistant)

            for call in reply.toolCalls {
                if Task.isCancelled { return }
                let out = await runTool(call)
                wire.append([
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": out
                ])
            }
        }
        finish(.failed, "Hit the round limit before finishing.")
    }

    private func runTool(_ call: KimiClient.RawToolCall) async -> String {
        let args = (try? JSONSerialization.jsonObject(
            with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
        switch call.name {
        case "web_search":
            let q = (args["query"] as? String) ?? ""
            setStatus("search: \(q)")
            do {
                let results = try await NikitaWeb.search(
                    q, braveKey: braveKey)
                let list = results.prefix(8).map {
                    ["title": $0.title, "url": $0.url, "snippet": $0.snippet]
                }
                return json(["results": list])
            } catch {
                return json(["error": error.localizedDescription])
            }
        case "web_fetch":
            let url = (args["url"] as? String) ?? ""
            setStatus("fetch: \(url)")
            do {
                let (text, _) = try await NikitaWeb.fetch(url)
                return json(["text": String(text.prefix(20000))])
            } catch {
                return json(["error": error.localizedDescription])
            }
        case "computer_run":
            let command = (args["command"] as? String) ?? ""
            setStatus("run: \(command)")
            guard let machine, await machine.isBridgeConnected else {
                return json(["error": "No computer bridged."])
            }
            do {
                let out = try await machine.send("host \(command)")
                return json(["output": out.isEmpty ? "(no output)" : out])
            } catch {
                return json(["error": error.localizedDescription])
            }
        case "python_run":
            let code = (args["code"] as? String) ?? ""
            setStatus("python")
            guard let machine, await machine.isBridgeConnected else {
                return json(["error": "No computer bridged."])
            }
            let b64 = Data(code.utf8).base64EncodedString()
            let cmd = "PY=\"$HOME/.nikita/venv/bin/python3\"; "
                + "[ -x \"$PY\" ] || PY=\"$HOME/.nikita/venv/bin/python\"; "
                + "[ -x \"$PY\" ] || PY=python3; "
                + "echo \(b64) | base64 -d | \"$PY\" -"
            do {
                let out = try await machine.send("host \(cmd)")
                return json(["output": out.isEmpty ? "(no output)" : out])
            } catch {
                return json(["error": error.localizedDescription])
            }
        case "http_request":
            let urlStr = (args["url"] as? String) ?? ""
            setStatus("http: \(urlStr)")
            guard let url = URL(string: urlStr),
                  let sc = url.scheme?.lowercased(), sc == "http" || sc == "https"
            else { return json(["error": "url must be http/https"]) }
            var req = URLRequest(url: url)
            req.httpMethod = ((args["method"] as? String) ?? "GET").uppercased()
            if let body = args["body"] as? String, !body.isEmpty {
                req.httpBody = body.data(using: .utf8)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            req.timeoutInterval = 30
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let text = String(data: data.prefix(12000), encoding: .utf8) ?? "(binary)"
                return json(["status": status, "body": text])
            } catch {
                return json(["error": error.localizedDescription])
            }
        default:
            return json(["error": "unknown tool \(call.name)"])
        }
    }

    // MARK: helpers

    private func setStatus(_ s: String) {
        status = s
        onChange?()
    }

    private func finish(_ s: State, _ text: String) {
        guard state == .running else { return }
        state = s
        if s == .done { result = text }
        status = s.rawValue
        onChange?()
    }

    private func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
