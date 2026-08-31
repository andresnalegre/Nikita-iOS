import Foundation
import Combine

// The agent. Owns the conversation, runs a turn against Kimi, executes any tool
// calls it asks for against the device bridge and the memory store, feeds the
// results back, and repeats until the model answers in words. A capable
// hosted model (Kimi) means none of the desktop's small-model scaffolding --
// forced-single-tool retries, primer turns, aggressive context trimming -- is
// needed here; the loop stays simple and honest.
@MainActor
public final class NikitaAgent: ObservableObject {
    @Published public private(set) var messages: [NikitaChatMessage] = []
    @Published public private(set) var thinking = false
    @Published public private(set) var usage = NikitaUsage()
    @Published public private(set) var turnStatus = ""

    private let bridge: NikitaDeviceBridge
    private let memory: NikitaMemory
    private let settings: NikitaSettings

    // OpenAI-shaped wire history (no system message; it is rebuilt each turn).
    private var wire: [[String: Any]] = []
    private var lastSavedPath: String?
    private var currentTask: Task<Void, Never>?

    private let maxToolRounds = 8

    public init(
        bridge: NikitaDeviceBridge,
        memory: NikitaMemory = .init(),
        settings: NikitaSettings = .shared
    ) {
        self.bridge = bridge
        self.memory = memory
        self.settings = settings
    }

    public var isBusy: Bool { thinking }

    public func clear() {
        wire.removeAll()
        messages.removeAll()
        usage = .init()
        lastSavedPath = nil
    }

    public func stop() {
        currentTask?.cancel()
        currentTask = nil
        thinking = false
        turnStatus = ""
    }

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !thinking else { return }

        messages.append(.init(role: .user, text: trimmed))
        wire.append(["role": "user", "content": trimmed])

        currentTask = Task { await runTurn(userText: trimmed) }
    }

    // MARK: Turn

    private func runTurn(userText: String) async {
        thinking = true
        turnStatus = "thinking…"
        defer {
            thinking = false
            turnStatus = ""
        }

        let key = settings.revealApiKey()
        guard !key.isEmpty else {
            emitError(KimiClient.ClientError.noKey.localizedDescription)
            return
        }

        let client = KimiClient(apiKey: key, model: settings.model)
        let connected = await bridge.isConnected
        let needsTools = classifyNeedsTools(userText)

        var turnPromptTokens = 0
        var turnCompletionTokens = 0

        for round in 0..<maxToolRounds {
            if Task.isCancelled { return }

            let system = NikitaPrompt.build(
                needsTools: needsTools,
                needsDevice: needsTools,
                connected: connected,
                memory: memory.all(),
                lastSavedPath: lastSavedPath)

            var msgs: [[String: Any]] = [["role": "system", "content": system]]
            msgs += trimmedWire()

            let tools = NikitaTools.offered(
                needsDevice: needsTools,
                isAllowed: { self.settings.isAllowed($0) })

            let reply: KimiClient.Reply
            do {
                reply = try await client.complete(messages: msgs, tools: tools)
            } catch {
                if Task.isCancelled { return }
                emitError(error.localizedDescription)
                return
            }

            turnPromptTokens += reply.promptTokens
            turnCompletionTokens += reply.completionTokens
            accrueCost(
                prompt: reply.promptTokens,
                completion: reply.completionTokens,
                model: settings.model)

            // Terminal turn: the model answered in words, no tool calls.
            if reply.toolCalls.isEmpty {
                let answer = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
                appendAssistant(answer.isEmpty ? "…" : answer)
                return
            }

            // Record the assistant's tool-call message on the wire verbatim.
            wire.append(assistantToolCallWire(reply.toolCalls, content: reply.content))

            // Show the assistant's optional prose + the tool rows in the UI.
            var invocations: [NikitaToolInvocation] = []
            for call in reply.toolCalls {
                invocations.append(.init(
                    id: call.id,
                    name: call.name,
                    argumentsJSON: call.argumentsJSON))
            }
            let uiIndex = appendAssistant(
                reply.content.trimmingCharacters(in: .whitespacesAndNewlines),
                tools: invocations)

            // Execute each call, feed the result back, update the row.
            for (i, call) in reply.toolCalls.enumerated() {
                if Task.isCancelled { return }
                turnStatus = "running \(call.name)…"
                let (result, ok) = await execute(
                    name: call.name, argumentsJSON: call.argumentsJSON)
                wire.append([
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": result
                ])
                updateToolRow(
                    messageIndex: uiIndex, callIndex: i, result: result, ok: ok)
            }

            _ = round // loop back for the model's next move
        }

        appendAssistant(
            "I stopped after \(maxToolRounds) tool rounds without finishing. "
            + "Tell me the next step and I'll continue.")
    }

    // MARK: Tool execution

    private func execute(
        name: String, argumentsJSON: String
    ) async -> (String, Bool) {
        let args = parseArgs(argumentsJSON)

        // Access filter: a tool whose family the user switched off is refused
        // with an honest message rather than silently dropped.
        if !settings.isAllowed(NikitaTools.family(of: name)) {
            return (jsonError("The \(NikitaTools.family(of: name)) tools are "
                + "switched off in Nikita settings."), false)
        }

        do {
            switch name {
            case "remember":
                let fact = (args["fact"] as? String) ?? ""
                memory.remember(fact)
                return (jsonOK(["saved": fact]), true)
            case "list_memory":
                return (jsonOK(["memory": memory.all()]), true)
            case "forget":
                let match = (args["match"] as? String) ?? ""
                let n = memory.forget(match)
                return (jsonOK(["removed": n]), true)

            case "list_files":
                let path = (args["path"] as? String) ?? "/ext"
                let entries = try await bridge.listFiles(at: path)
                return (jsonOK(["path": path, "entries": entries.map {
                    ["name": $0.name, "type": $0.type, "size": $0.size]
                }]), true)
            case "read_file":
                let path = (args["path"] as? String) ?? ""
                let content = try await bridge.readFile(at: path)
                return (jsonOK(["path": path, "content": content]), true)
            case "save_file":
                let path = (args["path"] as? String) ?? ""
                let content = (args["content"] as? String) ?? ""
                try await bridge.writeFile(at: path, content: content)
                lastSavedPath = path
                return (jsonOK(["saved": path, "bytes": content.utf8.count]), true)
            case "make_dir":
                let path = (args["path"] as? String) ?? ""
                try await bridge.makeDir(at: path)
                return (jsonOK(["created": path]), true)
            case "delete_file":
                let path = (args["path"] as? String) ?? ""
                let recursive = (args["recursive"] as? Bool) ?? false
                try await bridge.deleteFile(at: path, recursive: recursive)
                return (jsonOK(["deleted": path]), true)
            case "rename_file":
                let from = (args["from"] as? String) ?? ""
                let to = (args["to"] as? String) ?? ""
                try await bridge.renameFile(from: from, to: to)
                return (jsonOK(["from": from, "to": to]), true)
            case "file_info":
                let path = (args["path"] as? String) ?? ""
                let info = try await bridge.fileInfo(at: path)
                return (jsonOK([
                    "path": path, "exists": info.exists,
                    "type": info.type, "size": info.size]), true)

            case "read_screen":
                let screen = try await bridge.readScreen()
                return (jsonOK(["screen": screen]), true)
            case "press_button":
                let button = (args["button"] as? String) ?? "ok"
                let times = (args["times"] as? Int) ?? 1
                try await bridge.pressButton(button, times: max(1, times))
                let screen = (try? await bridge.readScreen()) ?? ""
                return (jsonOK(["pressed": button, "times": max(1, times),
                                "screen": screen]), true)
            case "run_app":
                let action = (args["action"] as? String) ?? "open"
                let appName = args["name"] as? String
                try await bridge.runApp(action: action, name: appName)
                return (jsonOK(["action": action, "name": appName ?? ""]), true)

            default:
                return (jsonError("Unknown tool \(name)."), false)
            }
        } catch {
            return (jsonError(error.localizedDescription), false)
        }
    }

    // MARK: Classification

    // A capable hosted model doesn't need the desktop's aggressive tool pruning;
    // the only thing this decides is whether to append the device manual and the
    // "last saved file" anchor. When in doubt, offer tools -- a wrongly-withheld
    // tool is a worse failure than an unused one.
    private func classifyNeedsTools(_ text: String) -> Bool {
        let t = text.lowercased()
        let chatOnly = ["oi", "olá", "ola", "hi", "hello", "hey", "obrigado",
                        "thanks", "thank you", "valeu", "tchau", "bye"]
        if chatOnly.contains(where: { t == $0 || t == $0 + "!" }) { return false }
        return true
    }

    // MARK: Wire helpers

    private func assistantToolCallWire(
        _ calls: [KimiClient.RawToolCall], content: String
    ) -> [String: Any] {
        var msg: [String: Any] = ["role": "assistant"]
        msg["content"] = content
        msg["tool_calls"] = calls.map { c in
            [
                "id": c.id,
                "type": "function",
                "function": ["name": c.name, "arguments": c.argumentsJSON]
            ] as [String: Any]
        }
        return msg
    }

    // Keep a recent, bounded window. Screen reads are collapsed to a note once a
    // newer one exists -- the old framebuffer is stale the moment a button moves.
    private func trimmedWire() -> [[String: Any]] {
        var msgs = wire

        // Collapse all but the most recent screen result.
        var lastScreen = -1
        for (i, m) in msgs.enumerated() where isScreenTool(m) { lastScreen = i }
        if lastScreen >= 0 {
            for i in msgs.indices where i != lastScreen && isScreenTool(msgs[i]) {
                msgs[i]["content"] = "{\"screen\":\"(an earlier screen, no longer "
                    + "current -- call read_screen again to see it now)\"}"
            }
        }

        // Bound by message count, starting at a clean user boundary so a
        // tool_calls -> tool-result pair is never split.
        let window = 20
        if msgs.count > window {
            var start = msgs.count - window
            while start > 0
                && (msgs[start]["role"] as? String) != "user" {
                start -= 1
            }
            msgs = Array(msgs[start...])
        }
        return msgs
    }

    private func isScreenTool(_ m: [String: Any]) -> Bool {
        (m["role"] as? String) == "tool"
            && ((m["content"] as? String)?.contains("\"screen\":") ?? false)
    }

    // MARK: Cost

    private func accrueCost(prompt: Int, completion: Int, model: String) {
        let m = KimiClient.model(for: model)
        let turn = Double(prompt) / 1_000_000 * m.inputPerM
            + Double(completion) / 1_000_000 * m.outputPerM
        usage.promptTokens += prompt
        usage.completionTokens += completion
        usage.turnCostUSD = turn
        usage.sessionCostUSD += turn
    }

    // MARK: UI mutation

    @discardableResult
    private func appendAssistant(
        _ text: String, tools: [NikitaToolInvocation] = []
    ) -> Int {
        messages.append(.init(role: .assistant, text: text, toolCalls: tools))
        return messages.count - 1
    }

    private func updateToolRow(
        messageIndex: Int, callIndex: Int, result: String, ok: Bool
    ) {
        guard messages.indices.contains(messageIndex),
              messages[messageIndex].toolCalls.indices.contains(callIndex)
        else { return }
        messages[messageIndex].toolCalls[callIndex].result = result
        messages[messageIndex].toolCalls[callIndex].ok = ok
    }

    private func emitError(_ text: String) {
        messages.append(.init(role: .error, text: text))
    }

    // MARK: JSON

    private func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private func jsonOK(_ payload: [String: Any]) -> String {
        var p = payload
        p["ok"] = true
        return encode(p)
    }

    private func jsonError(_ message: String) -> String {
        encode(["ok": false, "error": message])
    }

    private func encode(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8)
        else { return "{\"ok\":false,\"error\":\"encode failed\"}" }
        return s
    }
}
