import Foundation
import Combine

// The agent. Owns the conversation, runs a turn against Kimi, executes any tool
// calls it asks for against the device bridge and the memory store, feeds the
// results back, and repeats until the model answers in words. A capable
// hosted model (Kimi) means none of the desktop's small-model scaffolding --
// forced-single-tool retries, primer turns, aggressive context trimming -- is
// needed here; the loop stays simple and honest.
//
// Three things make this a loop an agent can live in rather than a request/
// response pair:
//
//   The plan. The model keeps its own list of steps, it is stored on disk, and
//   this loop reads it to decide whether the turn is actually over. A turn that
//   has run its tools but still has open items gets handed back to the model to
//   keep going, and a plan that outlives the process means closing the app
//   pauses the work instead of ending it.
//
//   A tool surface that does not move. Every turn is offered the same tools and
//   the same prompt prefix, with only the plan block changing at the end. What
//   Nikita can do never depends on how the sentence was phrased, and the
//   provider's prefix cache hits on nearly every round -- which is most of why
//   a reply lands in seconds instead of half a minute.
//
//   Independent reads run together. Three lookups the model asked for in one
//   breath are three lookups, not three waits.
@MainActor
public final class NikitaAgent: ObservableObject {
    @Published public private(set) var messages: [NikitaChatMessage] = []
    @Published public private(set) var thinking = false
    @Published public private(set) var usage = NikitaUsage()
    @Published public private(set) var turnStatus = ""
    // The live footer, mirroring qFlipper: seconds ticking, tokens so far this
    // turn, and the running cost. turnElapsed is driven by a 1s ticker while a
    // turn is in flight; turnTokens accumulates across the turn's rounds.
    @Published public private(set) var turnElapsed = 0
    @Published public private(set) var turnTokens = 0
    private var turnStartedAt: Date?
    private var ticker: Task<Void, Never>?

    // ---- Nikita Buddy relay ------------------------------------------------
    // The Flipper leaves a question in /ext/nikita/buddy/req.json; this phone's
    // Kimi link is what lets it be answered. A poll picks up a new request, runs
    // it as a normal turn (so it shows in the chat), and the reply is written
    // back to res.json for the Flipper to display.
    private var buddyReqId: UInt32?
    private var buddyLastHandled: UInt32 = 0
    private var buddyPoll: Task<Void, Never>?

    // The plan the model maintains, and what the UI shows of it.
    @Published public private(set) var planItems: [NikitaPlanItem] = []
    @Published public private(set) var planNote = ""

    // ---- parallel agents (Nikita fragments) --------------------------------
    // Fragments spun off with spawn_task, each working a sub-task in the
    // background. The UI shows them as a strip; runningFragmentCount is what a
    // "running task +N" badge reads. Kept until cleared so a finished result
    // stays visible.
    @Published public private(set) var fragments: [NikitaFragment] = []
    private var nextFragmentId = 1
    public var runningFragmentCount: Int {
        fragments.filter { $0.state == .running }.count
    }

    private let bridge: NikitaDeviceBridge
    // Optional: no bridge means no shell and no computer tools, which is the
    // normal state until one is running and connected.
    private let machine: NikitaMachineBridge?
    private let memory: NikitaMemory
    private let settings: NikitaSettings
    private let plan: NikitaPlan
    // Whether THIS agent owns the Flipper->Nikita relay poll. Only one agent
    // should (the app-level one), or a request would be answered twice. The
    // chat view's agent leaves this off; the app-level NikitaBuddyService turns
    // it on so the relay works no matter which screen is open -- matching
    // qFlipper, whose watcher lives in the always-on backend.
    private let relayEnabled: Bool
    // MCP tool servers. Public so the settings screen can show their state and
    // ask for a reconnect.
    public let mcp: NikitaMcp

    // OpenAI-shaped wire history (no system message; it is rebuilt each turn).
    private var wire: [[String: Any]] = []
    private var lastSavedPath: String?
    private var currentTask: Task<Void, Never>?

    // Rounds inside ONE turn. Eight was a cliff: a genuinely multi-step job hit
    // it, got a canned "I stopped" line, and the work was abandoned half done.
    // This is a high ceiling rather than a budget -- it exists to stop a
    // runaway, not to decide when the job is finished. The plan decides that.
    private let maxToolRounds = 40

    // How many times one turn may be handed back to the model purely because
    // its own plan still has open items. Bounded so a step the model never
    // ticks off cannot spin forever; hitting the bound is not a failure, since
    // the plan is kept and the next message resumes from it.
    private let maxPlanContinuations = 12

    public init(
        bridge: NikitaDeviceBridge,
        machine: NikitaMachineBridge? = nil,
        memory: NikitaMemory = .init(),
        settings: NikitaSettings = .shared,
        plan: NikitaPlan = .init(),
        relayEnabled: Bool = false
    ) {
        self.bridge = bridge
        self.machine = machine
        self.memory = memory
        self.settings = settings
        self.plan = plan
        self.relayEnabled = relayEnabled
        self.mcp = NikitaMcp(settings: settings)
        // Whatever was left open last time. Published before anything else can
        // look at it: an open item here is the difference between an assistant
        // that greets you and one that says what it was in the middle of.
        publishPlan()
    }

    // Bring the MCP servers up. Called when the assistant screen appears, so
    // the tools are known before the first message rather than discovered
    // halfway through one.
    public func connectMcp() async {
        // Which Flipper the servers are being asked on behalf of, before the
        // first call rather than after.
        mcp.setDeviceIdentity(await bridge.deviceIdentity)
        await mcp.reload()
        if relayEnabled { startBuddyPoll() }
    }

    private func startBuddyPoll() {
        guard buddyPoll == nil else { return }
        buddyPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await self?.pollBuddyMailbox()
            }
        }
    }

    // Read the Flipper's question, and if it is new and we are idle, answer it
    // through the normal turn. Quiet and best-effort: no Flipper, nothing to do.
    private func pollBuddyMailbox() async {
        guard !thinking, buddyReqId == nil else { return }
        guard await bridge.isConnected else { return }
        guard let json = try? await bridge.readFile(
            at: "/ext/nikita/buddy/req.json"), !json.isEmpty,
            let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return }
        let id = UInt32((obj["id"] as? Double) ?? 0)
        let text = ((obj["text"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard id != 0, id != buddyLastHandled, !text.isEmpty,
              !thinking, buddyReqId == nil else { return }
        buddyReqId = id
        buddyLastHandled = id
        // The Buddy is English-only and shows on a tiny screen, so the relayed
        // turn is told to keep the answer short and in English.
        let relayed = text
            + " (Reply in English only, in a few short lines suitable for a "
            + "tiny screen.)"
        messages.append(.init(role: .user, text: text))
        wire.append(["role": "user", "content": relayed])
        currentTask = Task { await runTurn(userText: relayed) }
    }

    private func writeBuddyReply(_ id: UInt32, _ text: String) async {
        let obj: [String: Any] = [
            "id": Double(id),
            "text": text.isEmpty ? "Done." : text,
            "done": true
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return }
        try? await bridge.makeDir(at: "/ext/nikita/buddy")
        try? await bridge.writeFile(
            at: "/ext/nikita/buddy/res.json", content: json)
    }

    // MARK: parallel agents (Nikita fragments)

    // Spin off a fragment of Nikita to work `task` in the background. Returns a
    // short note the tool call hands back to the model, so it knows the work is
    // running and does not sit waiting for it.
    @discardableResult
    public func spawnFragment(title: String, task: String) -> String {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "{\"error\":\"no task given\"}"
        }
        let key = settings.revealApiKey()
        guard !key.isEmpty else {
            return "{\"error\":\"no API key for the fragment\"}"
        }
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let frag = NikitaFragment(
            id: nextFragmentId,
            title: label.isEmpty ? String(trimmed.prefix(40)) : label,
            task: trimmed,
            apiKey: key,
            model: settings.model,
            braveKey: settings.braveKey,
            memory: memory.all(),
            machine: machine)
        nextFragmentId += 1
        // Republish on every change so the strip tracks status/state live.
        frag.setOnChange { [weak self] in
            self?.objectWillChange.send()
        }
        fragments.append(frag)
        frag.start()
        objectWillChange.send()
        return "{\"ok\":true,\"spawned\":true,\"note\":\"A fragment is now "
            + "working this in parallel. Its result arrives on its own -- do "
            + "not wait for it here; continue with anything else, or tell the "
            + "user it is running.\"}"
    }

    public func stopFragment(id: Int) {
        fragments.first { $0.id == id }?.stop()
        objectWillChange.send()
    }

    public func clearFinishedFragments() {
        fragments.removeAll { $0.state != .running }
        objectWillChange.send()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let started = self.turnStartedAt else { return }
                self.turnElapsed = Int(Date().timeIntervalSince(started))
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
        turnStartedAt = nil
    }

    // "8s", "1m 20s" -- the same compact shape qFlipper shows.
    public var turnElapsedText: String {
        let s = turnElapsed
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    private func publishPlan() {
        planItems = plan.items
        planNote = plan.note
    }

    // The plan lives on the SD card at /ext/nikita/plan.json too, so a job
    // started in qFlipper shows up here and vice versa -- the same card the
    // three clients already share. The local file is the cache; the card is the
    // shared copy. Both are best-effort and silent: no Flipper, no sync, and
    // the local plan still works.
    private func pullPlanFromCard() async {
        guard await bridge.isConnected else { return }
        guard let text = try? await bridge.readFile(
            at: "/ext/nikita/plan.json"), !text.isEmpty else { return }
        if plan.adoptFromJSON(text) { publishPlan() }
    }

    private func pushPlanToCard() async {
        guard await bridge.isConnected else { return }
        try? await bridge.makeDir(at: "/ext/nikita")
        try? await bridge.writeFile(
            at: "/ext/nikita/plan.json", content: plan.exportJSON())
    }

    public var planOpenCount: Int { plan.openCount }

    public func clearPlan() {
        plan.clear()
        publishPlan()
        Task { await pushPlanToCard() }
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
        stopTicker()
        thinking = false
        turnStatus = ""
        turnElapsed = 0
    }

    public func send(_ text: String, attachments: [NikitaAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // With attachments the text may be empty ("look at this") -- an image
        // alone is a valid turn. Without any, empty text is a no-op.
        guard (!trimmed.isEmpty || !attachments.isEmpty), !thinking else {
            return
        }

        messages.append(.init(
            role: .user, text: trimmed, attachments: attachments))
        wire.append(userWireMessage(text: trimmed, attachments: attachments))

        currentTask = Task { await runTurn(userText: trimmed) }
    }

    // Build the wire user message. With no attachments it is the plain string
    // content the API has always taken. With attachments it becomes the
    // OpenAI/Kimi multimodal array: a text part (the user's words plus any
    // inlined text files) followed by an image_url part per image. K2.6+ read
    // these natively -- no model switch needed.
    private func userWireMessage(
        text: String, attachments: [NikitaAttachment]
    ) -> [String: Any] {
        guard !attachments.isEmpty else {
            return ["role": "user", "content": text]
        }
        var promptText = text
        let textFiles = attachments.filter { $0.kind != .image }
        for f in textFiles {
            if !f.textContent.isEmpty {
                promptText += "\n\n--- Attached file: \(f.filename) ---\n"
                    + f.textContent
            } else {
                promptText += "\n\n[Attached file: \(f.filename), "
                    + "\(f.byteCount) bytes -- binary, cannot read as text]"
            }
        }
        var parts: [[String: Any]] = []
        if !promptText.isEmpty {
            parts.append(["type": "text", "text": promptText])
        }
        for img in attachments where img.kind == .image && !img.dataURL.isEmpty {
            parts.append([
                "type": "image_url",
                "image_url": ["url": img.dataURL]
            ])
        }
        return ["role": "user", "content": parts]
    }

    // MARK: Turn

    private func runTurn(userText: String) async {
        thinking = true
        turnStatus = "thinking…"
        turnStartedAt = Date()
        turnElapsed = 0
        turnTokens = 0
        usage.turnCostUSD = 0
        startTicker()
        defer {
            stopTicker()
            thinking = false
            turnStatus = ""
            // If this turn answered a Flipper request, hand the reply back to
            // the card. The last assistant message is the model's own words.
            if let id = buddyReqId {
                buddyReqId = nil
                let reply = messages.last { $0.role == .assistant }?.text ?? ""
                Task { await writeBuddyReply(id, reply) }
            }
        }

        let key = settings.revealApiKey()
        guard !key.isEmpty else {
            emitError(KimiClient.ClientError.noKey.localizedDescription)
            return
        }

        let client = KimiClient(apiKey: key, model: settings.model)
        let connected = await bridge.isConnected
        // Re-read every turn: a Flipper can be disconnected and another
        // connected while the app stays open, and a server keeping per-device
        // state must see that rather than a stale identity.
        mcp.setDeviceIdentity(await bridge.deviceIdentity)
        // Adopt a newer plan the card may hold (e.g. one qFlipper just wrote)
        // before this turn reads the plan into its prompt.
        await pullPlanFromCard()
        // Always on. classifyNeedsTools is still called -- see its own comment
        // -- but only to label the turn: an assistant whose abilities come and
        // go by keyword cannot be relied on, and a prompt that changes shape
        // every turn is a prompt the provider never caches.
        _ = classifyNeedsTools(userText)
        let needsTools = true

        var turnPromptTokens = 0
        var turnCompletionTokens = 0
        var planContinuations = 0
        var ranAnyTool = false
        var incapacityNudged = false
        var promisedMoreCount = 0

        var round = 0
        while round < maxToolRounds {
            round += 1
            if Task.isCancelled { return }

            let hasBridge = await (machine?.isBridgeConnected ?? false)
            let system = NikitaPrompt.build(
                needsTools: needsTools,
                needsDevice: needsTools,
                connected: connected,
                hasBridge: hasBridge,
                memory: memory.all(),
                lastSavedPath: lastSavedPath)
                // Learned skills + registered plugins from the "+" menu.
                + NikitaExtras.shared.promptSection()
                // Last, after everything else, so the bytes before it never
                // move and the cached prefix keeps hitting. The plan is the one
                // part of this prompt that legitimately changes every round.
                + plan.promptBlock()

            var msgs: [[String: Any]] = [["role": "system", "content": system]]
            msgs += trimmedWire()
            var tools = NikitaTools.offered(
                needsDevice: needsTools,
                hasBridge: hasBridge,
                isAllowed: { self.settings.isAllowed($0) })
            // MCP tools, appended after the access filter: their names come
            // from the servers at runtime, so they are not in the static
            // family table and are gated by the MCP switch instead.
            tools += mcp.toolSchemas()
            // The call_plugin tool, only when the user has registered a plugin.
            if !NikitaExtras.shared.plugins.isEmpty {
                tools.append(NikitaTools.callPluginTool)
            }

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
            // Published so the footer shows the count climbing round by round,
            // the way qFlipper's does, instead of only at the very end.
            turnTokens = turnPromptTokens + turnCompletionTokens
            accrueCost(
                prompt: reply.promptTokens,
                completion: reply.completionTokens,
                model: settings.model)

            // The model answered in words. Whether that ends the turn is not
            // its call alone: if its own plan still has open items and it has
            // actually been working, the job is not over, and stopping here is
            // the assistant dying with the work half done. So it gets the turn
            // back, with the next item named.
            if reply.toolCalls.isEmpty {
                let answer = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)

                if plan.openCount > 0, ranAnyTool,
                   planContinuations < maxPlanContinuations {
                    planContinuations += 1
                    // Anything it did say is kept on screen -- it is usually
                    // "next I'll do X", which is worth reading while X happens.
                    if !answer.isEmpty { appendAssistant(answer) }
                    wire.append(["role": "assistant", "content": answer])
                    wire.append([
                        "role": "user",
                        "content": "[the app] Your plan still has "
                            + "\(plan.openCount) open item(s); the next one "
                            + "is \"\(plan.current)\". Keep going now — call "
                            + "the tool for it. Mark items done with "
                            + "update_plan as they land. Only answer in words "
                            + "when the plan is clear, or when you genuinely "
                            + "need something from the user that you cannot "
                            + "find out yourself."
                    ])
                    turnStatus = plan.current.isEmpty
                        ? "carrying on…" : "\(plan.current.prefix(40))…"
                    continue
                }

                // Dying halfway: it ran tools, then signed off announcing a
                // next step ("let me...", "I'll open...", "vou...") instead of
                // taking it. Push it to actually continue. Bounded.
                if ranAnyTool, promisedMoreCount < 6,
                   NikitaAgent.looksLikePromiseToContinue(answer) {
                    promisedMoreCount += 1
                    if !answer.isEmpty { appendAssistant(answer) }
                    wire.append(["role": "assistant", "content": answer])
                    wire.append([
                        "role": "user",
                        "content": "[the app] You announced a next step and "
                            + "then stopped. Take it NOW with a tool -- do not "
                            + "describe it. Keep going until the task is truly "
                            + "finished, then answer. If it IS finished, say so "
                            + "plainly."
                    ])
                    turnStatus = "continuing…"
                    continue
                }

                // False incapacity: the model refused (no tool ran, and the
                // reply reads as "I can't / I don't have / unable to") while it
                // actually has web_search and web_fetch. Nudge it once, naming
                // only tools it truly has, and let it try again. Bounded by the
                // same round ceiling so it can't loop.
                if !ranAnyTool, !incapacityNudged,
                   NikitaAgent.looksLikeFalseRefusal(answer) {
                    incapacityNudged = true
                    if !answer.isEmpty { appendAssistant(answer) }
                    wire.append(["role": "assistant", "content": answer])
                    wire.append([
                        "role": "user",
                        "content": "[the app] That is not right -- you were "
                            + "handed real tools this turn. You can always "
                            + "search the web with web_search and read pages "
                            + "with web_fetch, through this phone's connection. "
                            + "Do not say you can't search or lack internet. "
                            + "Call the right tool now for what was asked -- "
                            + "just the call."
                    ])
                    turnStatus = "trying again…"
                    continue
                }

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

            // Execute them, feed the results back in the order they were
            // asked for, and update each row as it lands.
            ranAnyTool = true
            let results = await executeBatch(reply.toolCalls, uiIndex: uiIndex)
            if Task.isCancelled { return }
            for (i, call) in reply.toolCalls.enumerated() {
                wire.append([
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": results[i].0
                ])
                _ = i
                _ = call
            }
            publishPlan()
        }

        // Out of rounds. The plan is the honest account of where that leaves
        // things, and it is still on disk -- so this is a pause, not a loss.
        publishPlan()
        if plan.openCount > 0 {
            let left = plan.items
                .filter { $0.status != .done }
                .map { "• \($0.text)" }
                .joined(separator: "\n")
            appendAssistant(
                "I've been going for \(maxToolRounds) rounds on this, so I'm "
                + "pausing here rather than spinning. Still open:\n\(left)\n\n"
                + "Say \"continue\" and I'll pick it straight back up — "
                + "the plan is saved, so it survives closing the app too.")
        } else {
            appendAssistant(
                "I stopped after \(maxToolRounds) tool rounds without "
                + "finishing. Tell me the next step and I'll continue.")
        }
    }

    // MARK: Running a round's tool calls

    // Which tools only LOOK. A read cannot be disturbed by another read, so a
    // round that asked for several of them should take as long as the slowest
    // one, not the sum -- and over a Bluetooth link or a bridge to another
    // machine that difference is seconds, every round. Anything that changes
    // something stays strictly in order, on its own: two writes to the same
    // path, or a write and the read that checks it, are not independent, and
    // reordering them would be a bug nobody could reproduce.
    private static let readOnlyTools: Set<String> = [
        "list_memory",
        "list_files", "read_file", "file_info",
        "computer_list", "computer_read", "computer_find",
        "scan_viewer",
        "web_search", "web_fetch"
    ]

    // A reply that refuses with an incapacity claim, and nothing was done.
    // Kept deliberately narrow: phrases people only use to say "I can't",
    // in English and Portuguese.
    static func looksLikeFalseRefusal(_ text: String) -> Bool {
        let t = text.lowercased()
        let needles = [
            "i can't", "i cant", "i cannot", "i don't have", "i dont have",
            "i do not have", "i'm unable", "i am unable", "unable to",
            "i lack", "no access", "not able to", "no web search",
            "no internet", "can't search", "cannot search", "can't reach",
            "don't support", "nao consigo", "não consigo", "nao posso",
            "não posso", "nao tenho", "não tenho", "sem acesso"
        ]
        return needles.contains { t.contains($0) }
    }

    // A reply that announces a next action instead of taking it, after real
    // work happened. Action-intent phrases only (not "let me know").
    static func looksLikePromiseToContinue(_ text: String) -> Bool {
        let t = text.lowercased()
        let needles = [
            "let me try", "let me search", "let me open", "let me check",
            "let me pull", "let me get", "let me look", "let me fetch",
            "let me run", "i'll try", "i'll search", "i'll open", "i'll check",
            "i'll pull", "i'll get", "i'll look", "i'll fetch", "i'll run",
            "next i'll", "now i'll", "still working", "continuing",
            "one moment", "vou tentar", "vou buscar", "vou abrir",
            "vou procurar", "deixa eu", "agora vou", "ainda estou"
        ]
        return needles.contains { t.contains($0) }
    }

    private static func isParallelSafe(_ name: String) -> Bool {
        // An MCP tool is never assumed safe to run alongside anything: the
        // server decides what its tools do, and a name is not a promise.
        if NikitaMcp.isMcpTool(name) { return false }
        return readOnlyTools.contains(name)
    }

    private func executeBatch(
        _ calls: [KimiClient.RawToolCall], uiIndex: Int
    ) async -> [(String, Bool)] {
        var results = [(String, Bool)](
            repeating: ("", false), count: calls.count)
        var i = 0

        while i < calls.count {
            if Task.isCancelled { return results }

            // The longest run of read-only calls starting here.
            var j = i
            while j < calls.count, Self.isParallelSafe(calls[j].name) { j += 1 }

            if j - i >= 2 {
                turnStatus = "reading \(j - i) things…"
                await withTaskGroup(of: (Int, (String, Bool)).self) { group in
                    for k in i..<j {
                        let call = calls[k]
                        group.addTask {
                            let r = await self.execute(
                                name: call.name,
                                argumentsJSON: call.argumentsJSON)
                            return (k, r)
                        }
                    }
                    for await (k, r) in group {
                        results[k] = r
                        updateToolRow(
                            messageIndex: uiIndex, callIndex: k,
                            result: r.0, ok: r.1)
                    }
                }
                i = j
            } else {
                let call = calls[i]
                turnStatus = Self.actionPhrase(
                    name: call.name, argumentsJSON: call.argumentsJSON)
                let r = await execute(
                    name: call.name, argumentsJSON: call.argumentsJSON)
                results[i] = r
                updateToolRow(
                    messageIndex: uiIndex, callIndex: i, result: r.0, ok: r.1)
                i += 1
            }
        }
        return results
    }

    // A Claude-Code-style live status line: an action verb plus the thing it is
    // acting on ("read config.txt", "ran `ls -la`", "searched the web for X"),
    // so the footer reads like a running command rather than a raw tool name.
    static func actionPhrase(name: String, argumentsJSON: String) -> String {
        let args = (try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        func s(_ k: String) -> String {
            let v = "\(args[k] ?? "")"
            return v.count > 40 ? String(v.prefix(40)) + "…" : v
        }
        func base(_ p: String) -> String {
            (p as NSString).lastPathComponent
        }
        switch name {
        case "web_search": return "searching the web · \(s("query"))"
        case "web_fetch": return "reading \(s("url"))"
        case "spawn_task": return "spinning up a fragment · \(s("title"))"
        case "update_plan": return "updating the plan"
        case "remember": return "remembering that"
        case "list_memory": return "checking memory"
        case "forget": return "forgetting that"
        case "run_cli": return "running on the Flipper · \(s("command"))"
        case "computer_run": return "ran a command · \(s("command"))"
        case "computer_read", "read_file":
            return "read \(base(s("path")))"
        case "computer_write", "save_file", "write_file":
            return "writing \(base(s("path")))"
        case "computer_edit": return "editing \(base(s("path")))"
        case "computer_grep", "computer_find":
            return "searching files · \(s("pattern"))\(s("query"))"
        case "computer_list", "list_files":
            return "listing \(s("path"))"
        case "computer_mkdir", "make_dir": return "making \(base(s("path")))"
        case "computer_delete", "delete_file":
            return "deleting \(base(s("path")))"
        case "transfer": return "copying files"
        case "download": return "downloading \(s("url"))"
        case "press_button": return "pressing \(s("button"))"
        case "run_app": return "opening \(s("name"))"
        default:
            return name.hasPrefix("mcp__")
                ? "using a tool · \(name)"
                : "running \(name)…"
        }
    }

    // MARK: Machine bridge

    // Call a registered plugin (external HTTP API). Base URL + auth header come
    // from the stored plugin; the model only supplies path/method/body.
    private func callPlugin(_ args: [String: Any]) async throws -> String {
        let name = (args["name"] as? String) ?? ""
        guard let p = NikitaExtras.shared.plugin(named: name) else {
            return jsonOK(["error": "no plugin named '\(name)'"])
        }
        var base = p.baseUrl
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        var path = (args["path"] as? String) ?? ""
        if !path.isEmpty, !path.hasPrefix("/") { path = "/" + path }
        guard let url = URL(string: base + path) else {
            return jsonOK(["error": "bad url"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = ((args["method"] as? String) ?? "GET").uppercased()
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !p.authHeader.isEmpty {
            req.setValue(p.authValue, forHTTPHeaderField: p.authHeader)
        }
        if let body = args["body"] as? String, !body.isEmpty,
           req.httpMethod != "GET" {
            req.httpBody = body.data(using: .utf8)
        }
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(
            data: data.prefix(8000), encoding: .utf8) ?? "(binary)"
        return jsonOK(["status": status, "body": text])
    }

    private func machineRun(_ command: String) async throws -> String {
        guard let machine, await machine.isBridgeConnected else {
            throw NikitaDeviceError.failed(
                "No machine bridge. Run nikita-flipper-bridge on the computer "
                + "holding the Flipper, and connect to it from the CLI screen.")
        }
        let output = try await machine.send(command)
        return output.isEmpty ? "(no output)" : output
    }

    // Single-quote a path for the shell. Everything the model supplies is
    // treated as data, never as syntax: a name with a space or a semicolon in
    // it must not turn into a second command.
    private func quoted(_ value: String) -> String {
        func q(_ v: String) -> String {
            "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        // A leading ~ must stay unquoted so the shell expands it to $HOME;
        // quoting it makes "ls '~'" look for a directory literally named ~.
        if value == "~" { return "~" }
        if value.hasPrefix("~/") { return "~/" + q(String(value.dropFirst(2))) }
        return q(value)
    }

    private func b64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    // An exact-string edit of a file on the bridged computer.
    //
    // The replacement happens HERE, on the phone, not in a shell command: the
    // file comes back, the match is checked and applied in Swift, and the
    // result is written through the same heredoc computer_write uses. Doing it
    // with sed instead would mean escaping the model's text into a regular
    // expression, and any text containing a slash, a bracket or an ampersand
    // would quietly change meaning -- which is the one thing an exact-string
    // edit exists to prevent.
    private func editRemoteFile(
        path: String, oldString: String, newString: String, replaceAll: Bool
    ) async throws -> (String, Bool) {
        guard !path.isEmpty else { return (jsonError("No path given."), false) }
        guard !oldString.isEmpty else {
            return (jsonError(
                "old_string is empty. To create a file use computer_write; to "
                + "insert, anchor on an existing line."), false)
        }
        guard oldString != newString else {
            return (jsonError(
                "old_string and new_string are identical — nothing to do."),
                    false)
        }

        let before = try await machineRun("host cat \(quoted(path))")
        let hits = before.components(separatedBy: oldString).count - 1
        if hits == 0 {
            return (jsonError(
                "old_string was not found in \(path). It must match the file "
                + "EXACTLY, including indentation and whitespace — read the "
                + "file and copy the text rather than retyping it."), false)
        }
        if hits > 1 && !replaceAll {
            return (jsonError(
                "old_string appears \(hits) times in \(path), so this edit is "
                + "ambiguous and was NOT applied. Include more surrounding "
                + "lines to make it unique, or pass replace_all if you really "
                + "mean every occurrence."), false)
        }

        let after: String
        if replaceAll {
            after = before.replacingOccurrences(of: oldString, with: newString)
        } else if let range = before.range(of: oldString) {
            after = before.replacingCharacters(in: range, with: newString)
        } else {
            return (jsonError("Could not locate old_string to replace."), false)
        }

        let script = "cat > \(quoted(path)) <<'NIKITA_EOF'\n"
            + after + "\nNIKITA_EOF"
        _ = try await machineRun("host \(script)")
        lastSavedPath = path
        return (jsonOK([
            "edited": path,
            "replacements": replaceAll ? hits : 1,
            "bytes": after.utf8.count
        ]), true)
    }

    // MARK: Tool execution

    private func execute(
        name: String, argumentsJSON: String
    ) async -> (String, Bool) {
        let args = parseArgs(argumentsJSON)

        // Access filter: a tool whose family the user switched off is refused
        // with an honest message rather than silently dropped. MCP tools are
        // gated by their own switch inside the client, not by a family here.
        if !NikitaMcp.isMcpTool(name),
           !settings.isAllowed(NikitaTools.family(of: name)) {
            return (jsonError("The \(NikitaTools.family(of: name)) tools are "
                + "switched off in Nikita settings."), false)
        }

        // An MCP tool. Routed first: the name is namespaced, so it cannot
        // collide with a built-in, and the client handles connecting, timing
        // out and shaping the result.
        if NikitaMcp.isMcpTool(name) {
            return await mcp.call(name, args: args)
        }

        do {
            switch name {
            case "update_plan":
                let items = (args["items"] as? [[String: Any]]) ?? []
                let result = plan.apply(
                    items: items, note: args["note"] as? String)
                publishPlan()
                await pushPlanToCard()   // mirror so qFlipper sees it too
                return (result, true)

            case "spawn_task":
                let note = spawnFragment(
                    title: (args["title"] as? String) ?? "",
                    task: (args["task"] as? String) ?? "")
                return (note, true)

            case "call_plugin":
                return (try await callPlugin(args), true)

            case "web_search":
                let query = (args["query"] as? String) ?? ""
                let hits = try await NikitaWeb.search(
                    query, braveKey: settings.braveKey)
                return (jsonOK([
                    "query": query,
                    "results": hits.map {
                        ["title": $0.title, "url": $0.url,
                         "snippet": $0.snippet]
                    }
                ]), true)

            case "web_fetch":
                let url = (args["url"] as? String) ?? ""
                let (text, truncated) = try await NikitaWeb.fetch(url)
                var payload: [String: Any] = [
                    "url": url,
                    "content": text.isEmpty ? "(no readable text)" : text
                ]
                if truncated {
                    payload["truncated"] = true
                    payload["note"] = "Page was longer than the cap and cut here."
                }
                return (jsonOK(payload), true)

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

            case "run_cli":
                let command = (args["command"] as? String) ?? ""
                return (jsonOK(["output": try await machineRun(command)]), true)

            case "scan_viewer":
                let raw = try await machineRun("nikita host")
                return (jsonOK(HostScan.parse(raw).toolPayload), true)

            case "computer_list":
                let path = (args["path"] as? String) ?? "~"
                return (jsonOK(["path": path,
                    "listing": try await machineRun("host ls -la \(quoted(path))")]),
                    true)
            case "computer_read":
                let path = (args["path"] as? String) ?? ""
                return (jsonOK(["path": path,
                    "content": try await machineRun("host cat \(quoted(path))")]),
                    true)
            case "computer_find":
                let path = (args["path"] as? String) ?? "~"
                let pattern = (args["pattern"] as? String) ?? "*"
                return (jsonOK(["matches": try await machineRun(
                    "host find \(quoted(path)) -name \(quoted(pattern)) "
                    + "-maxdepth 4")]), true)
            case "computer_write":
                let path = (args["path"] as? String) ?? ""
                let content = (args["content"] as? String) ?? ""
                // Through a heredoc so the content is never parsed as shell.
                let script = "cat > \(quoted(path)) <<'NIKITA_EOF'\n"
                    + content + "\nNIKITA_EOF"
                _ = try await machineRun("host \(script)")
                return (jsonOK(["written": path]), true)
            case "computer_edit":
                let path = (args["path"] as? String) ?? ""
                let oldStr = (args["old_string"] as? String) ?? ""
                let newStr = (args["new_string"] as? String) ?? ""
                let all = (args["replace_all"] as? Bool) ?? false
                return try await editRemoteFile(
                    path: path, oldString: oldStr,
                    newString: newStr, replaceAll: all)

            case "computer_grep":
                let path = (args["path"] as? String) ?? "~"
                let pattern = (args["pattern"] as? String) ?? ""
                guard !pattern.isEmpty else {
                    return (jsonError("No pattern given."), false)
                }
                let glob = (args["glob"] as? String) ?? ""
                let icase = ((args["ignore_case"] as? Bool) ?? false) ? "i" : ""
                // -I skips binaries, -n numbers the lines, -r walks the tree,
                // and the include filter is what keeps a repo-wide search from
                // returning the build directory. head bounds the output at the
                // far end, because the model pays for every line of it.
                var cmd = "grep -rn\(icase)IE"
                if !glob.isEmpty { cmd += " --include=\(quoted(glob))" }
                cmd += " --exclude-dir=.git --exclude-dir=node_modules"
                cmd += " --exclude-dir=.build --exclude-dir=DerivedData"
                cmd += " -e \(quoted(pattern)) \(quoted(path)) | head -200"
                let out = try await machineRun("host \(cmd)")
                return (jsonOK([
                    "pattern": pattern,
                    "matches": out.isEmpty ? "(no line matched)" : out
                ]), true)

            case "computer_mkdir":
                let path = (args["path"] as? String) ?? ""
                _ = try await machineRun("host mkdir -p \(quoted(path))")
                return (jsonOK(["created": path]), true)
            case "computer_delete":
                let path = (args["path"] as? String) ?? ""
                let recursive = (args["recursive"] as? Bool) ?? false
                _ = try await machineRun(
                    "host rm \(recursive ? "-r " : "")\(quoted(path))")
                return (jsonOK(["deleted": path]), true)
            case "computer_run":
                let command = (args["command"] as? String) ?? ""
                return (jsonOK(["output": try await machineRun("host \(command)")]),
                    true)

            case "transfer":
                let src = (args["src"] as? String) ?? ""
                let dst = (args["dst"] as? String) ?? ""
                let flags = ((args["recursive"] as? Bool) ?? false) ? " -r" : ""
                let out = try await machineRun(
                    "xcp \(b64(src)) \(b64(dst)) \(b64("~"))\(flags)")
                return (jsonOK(["result": out]), true)

            case "download":
                let url = (args["url"] as? String) ?? ""
                let dst = (args["dst"] as? String) ?? ""
                let out = try await machineRun(
                    "xwget \(b64(url)) \(b64(dst)) \(b64("~"))")
                return (jsonOK(["result": out]), true)

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

            case "press_button":
                let button = (args["button"] as? String) ?? "ok"
                let times = (args["times"] as? Int) ?? 1
                try await bridge.pressButton(button, times: max(1, times))
                return (jsonOK(["pressed": button, "times": max(1, times)]), true)
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

    // Kept for the label it produces, and load-bearing for nothing: the tools
    // are offered on every turn now. A wrongly-withheld tool is the worst
    // failure here -- the model can then only apologise -- and a tool list that
    // changes with the phrasing also throws away the cached prompt prefix on
    // every round, which is most of the latency the user actually feels.
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
        // Accumulate across the turn's rounds so the footer shows the whole
        // turn's cost, not just the last round. Reset at each turn's start.
        usage.turnCostUSD += turn
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
