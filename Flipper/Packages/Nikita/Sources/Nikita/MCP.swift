import CryptoKit
import Foundation

// MCP (Model Context Protocol) client -- the same tool-plugin protocol Claude
// Code speaks, so Nikita on the phone can use a server the user already runs
// instead of every new capability having to be hand-written into Tools.swift.
//
// HTTP only, and that is not a shortcut. The dominant MCP transport is stdio: a
// child process on stdin/stdout. An iOS app cannot spawn one -- the sandbox has
// no fork/exec for us -- so a stdio server is not reachable from here at all,
// by anyone, and pretending otherwise would only produce a tool that fails on
// every call. What IS reachable is Streamable HTTP, which is a POST per
// request. So a stdio-only server is put behind a small HTTP proxy on the
// computer (mcp-proxy, or the Mac-side qFlipper build, which does speak stdio)
// and the phone talks to that.
//
// Names are namespaced the way Claude Code namespaces them --
// mcp__<server>__<tool> -- so the same tool reads the same in both programs.
@MainActor
public final class NikitaMcp: ObservableObject {

    // nonisolated: both are pure string work, and the routing checks that
    // use them run wherever a tool call is being classified, not only on the
    // main actor.
    public nonisolated static let prefix = "mcp__"

    public nonisolated static func isMcpTool(_ name: String) -> Bool {
        name.hasPrefix(prefix)
    }

    // One configured server, as the settings screen edits it. The token is not
    // in here: it lives in the Keychain, keyed by the server's name, for the
    // same reason the API key does.
    public struct Server: Codable, Identifiable, Equatable, Sendable {
        public var name: String
        public var url: String
        public var headerName: String
        public var enabled: Bool

        public var id: String { name }

        public init(
            name: String, url: String,
            headerName: String = "Authorization", enabled: Bool = true
        ) {
            self.name = name
            self.url = url
            self.headerName = headerName
            self.enabled = enabled
        }
    }

    // What the panel shows. Deliberately not the Server itself: the user needs
    // to see whether it actually answered, which is the part they cannot
    // configure.
    public struct State: Identifiable, Equatable {
        public var name: String
        public var url: String
        // "idle" | "connecting" | "ready" | "failed"
        public var status: String
        public var toolCount: Int
        public var error: String
        public var label: String         // what the server calls itself
        public var id: String { name }
    }

    @Published public private(set) var states: [State] = []
    @Published public private(set) var busy = false

    private let settings: NikitaSettings
    private let session: URLSession

    // Per server, in flight or cached.
    // The device pseudonym, and the normalised raw id it was made from. The
    // raw value never leaves this class.
    private var rawDeviceId = ""
    private var deviceId = ""

    private var sessionIds: [String: String] = [:]
    private var schemas: [String: [[String: Any]]] = [:]
    private var nextRequestId = 1

    private static let protocolVersion = "2025-06-18"
    private static let handshakeTimeout: TimeInterval = 20
    private static let callTimeout: TimeInterval = 300
    private static let resultCap = 60_000

    public init(
        settings: NikitaSettings = .shared,
        session: URLSession = .shared
    ) {
        self.settings = settings
        self.session = session
        self.states = settings.mcpServers.map {
            .init(name: $0.name, url: $0.url, status: "idle",
                  toolCount: 0, error: "", label: "")
        }
    }

    public var isEnabled: Bool { settings.mcpEnabled }

    public var toolCount: Int { schemas.values.reduce(0) { $0 + $1.count } }

    public var statusLine: String {
        guard settings.mcpEnabled else { return "MCP off" }
        let configured = settings.mcpServers.filter(\.enabled)
        if configured.isEmpty { return "no MCP servers configured" }
        let ready = states.filter { $0.status == "ready" }.count
        let failed = states.filter { $0.status == "failed" }.count
        var out = "\(ready)/\(configured.count) server(s), \(toolCount) tool(s)"
        if failed > 0 { out += " — \(failed) failed" }
        return out
    }

    // MARK: Which Flipper is asking, and proving it
    //
    // Two values travel with every call, and they are different kinds of
    // thing -- conflating them is the mistake this comment exists to prevent.
    //
    //   deviceId -- a stable PSEUDONYM: SHA-256 of the device's own id, first
    //      32 hex. An IDENTIFIER, never a secret: a Flipper's hardware id is
    //      not secret, so anything derived from it alone is forgeable by
    //      anyone who has seen the device. For scoping only. The raw id is
    //      deliberately never sent -- a hardware id handed to every
    //      third-party server is a fingerprint the user never agreed to.
    //
    //   deviceAuth -- a SIGNED claim, and the part that proves something:
    //
    //        v1:<deviceId>:<unix-seconds>:<nonce>:<hmac>
    //        hmac = HMAC-SHA256(token, "v1|deviceId|ts|nonce|method|tool")
    //
    //      keyed with the token configured for THAT server. It needs the
    //      secret, so only a client configured for this server can produce it;
    //      the timestamp and nonce make a captured value single-use, so a
    //      replayed recording buys nothing; the method and tool are inside the
    //      signature, so one lifted from a harmless call cannot be re-attached
    //      to a dangerous one; and it is per-server, so one server cannot
    //      replay what it received at another.
    //
    //      What it does not do: it does not make the channel confidential
    //      (TLS's job), and it does not cover the call's ARGUMENTS. It is
    //      device authentication, not a full request signature.

    /// Normalised and hashed here; pass the raw id from the bridge.
    public func setDeviceIdentity(_ raw: String?) {
        // Normalised first, so the SAME Flipper produces the same pseudonym in
        // every client of this ecosystem. The phone reads hardware.uid over
        // RPC and the desktop reads the USB serial number; for a Flipper Zero
        // those are the same STM32 value arriving spelled differently.
        // Hashing the spelling would give one device two identities.
        let normalised = (raw ?? "")
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
        guard normalised != rawDeviceId else { return }
        rawDeviceId = normalised
        if normalised.isEmpty {
            deviceId = ""
            return
        }
        let digest = SHA256.hash(data: Data(normalised.utf8))
        deviceId = String(
            digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    private func deviceAuth(
        for server: Server, method: String, tool: String
    ) -> String? {
        guard !deviceId.isEmpty else { return nil }
        let secret = settings.mcpToken(for: server.name)
        guard !secret.isEmpty else { return nil }

        let ts = Int(Date().timeIntervalSince1970)
        // 128 bits from the system CSPRNG. A nonce the server has already seen
        // is a replay, so it has to be unguessable and never repeat.
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let nonce = bytes.map { String(format: "%02x", $0) }.joined()

        let payload = "v1|\(deviceId)|\(ts)|\(nonce)|\(method)|\(tool)"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(payload.utf8),
            using: SymmetricKey(data: Data(secret.utf8)))
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        return "v1:\(deviceId):\(ts):\(nonce):\(hex)"
    }

    private func callMeta(for server: Server, tool: String) -> [String: Any]? {
        guard !deviceId.isEmpty else { return nil }
        // Namespaced keys, because `_meta` is shared ground: an unprefixed
        // "device" would be this client claiming a name it does not own.
        var meta: [String: Any] = [
            "nikita/client": "nikita-ios",
            "nikita/device": deviceId
        ]
        if let auth = deviceAuth(
            for: server, method: "tools/call", tool: tool) {
            meta["nikita/deviceAuth"] = auth
        }
        return meta
    }

    // MARK: Connecting

    // Re-read the configuration and handshake with every enabled server. Called
    // when the assistant screen opens and whenever the user edits the list, so
    // the tools are already known before the first message rather than
    // discovered halfway through one.
    public func reload() async {
        guard settings.mcpEnabled else {
            schemas.removeAll()
            sessionIds.removeAll()
            states = settings.mcpServers.map {
                .init(name: $0.name, url: $0.url, status: "idle",
                      toolCount: 0, error: "", label: "")
            }
            return
        }

        busy = true
        defer { busy = false }

        let servers = settings.mcpServers.filter(\.enabled)
        // Drop anything that left the config, so a removed server's tools stop
        // being offered immediately.
        let names = Set(servers.map(\.name))
        schemas = schemas.filter { names.contains($0.key) }
        sessionIds = sessionIds.filter { names.contains($0.key) }

        states = servers.map {
            .init(name: $0.name, url: $0.url, status: "connecting",
                  toolCount: 0, error: "", label: "")
        }

        // Sequentially: a handshake is two or three small round trips, and the
        // list is short. Doing them in parallel would save a second and make
        // the failure reporting harder to follow.
        for server in servers {
            await connect(server)
        }
    }

    private func connect(_ server: Server) async {
        do {
            let initResult = try await request(
                server,
                method: "initialize",
                params: [
                    "protocolVersion": Self.protocolVersion,
                    "capabilities": [:] as [String: Any],
                    "clientInfo": ["name": "nikita-ios", "version": "1"]
                ],
                timeout: Self.handshakeTimeout)

            var label = ""
            if let info = initResult["serverInfo"] as? [String: Any] {
                label = (info["name"] as? String) ?? ""
                if let v = info["version"] as? String, !v.isEmpty {
                    label += " \(v)"
                }
            }

            // Required by the spec before any other request.
            try? await notify(server, method: "notifications/initialized")

            var collected: [[String: Any]] = []
            var cursor: String?
            // Bounded: a server that keeps handing back a cursor must not spin
            // here forever.
            for _ in 0..<20 {
                var params: [String: Any] = [:]
                if let cursor { params["cursor"] = cursor }
                let page = try await request(
                    server, method: "tools/list", params: params,
                    timeout: Self.handshakeTimeout)
                collected += Self.functionSchemas(
                    from: (page["tools"] as? [[String: Any]]) ?? [],
                    server: server.name)
                cursor = page["nextCursor"] as? String
                if cursor == nil || cursor?.isEmpty == true { break }
            }

            schemas[server.name] = collected
            setState(server.name, status: "ready", tools: collected.count,
                     error: "", label: label)
        } catch {
            schemas[server.name] = nil
            setState(server.name, status: "failed", tools: 0,
                     error: error.localizedDescription, label: "")
        }
    }

    private func setState(
        _ name: String, status: String, tools: Int, error: String, label: String
    ) {
        guard let i = states.firstIndex(where: { $0.name == name })
        else { return }
        states[i].status = status
        states[i].toolCount = tools
        states[i].error = error
        states[i].label = label
    }

    // MARK: Schemas

    private static func functionSchemas(
        from tools: [[String: Any]], server: String
    ) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for t in tools {
            guard let bare = t["name"] as? String, !bare.isEmpty
            else { continue }
            var desc = (t["description"] as? String)
                ?? "Tool provided by the MCP server."
            if desc.count > 900 { desc = String(desc.prefix(900)) }
            var schema = (t["inputSchema"] as? [String: Any]) ?? [:]
            // A function schema with no type is rejected by the API, and a
            // no-argument tool often ships an empty one.
            if schema["type"] == nil { schema["type"] = "object" }
            if schema["properties"] == nil {
                schema["properties"] = [String: Any]()
            }
            out.append([
                "type": "function",
                "function": [
                    "name": "\(prefix)\(server)__\(bare)",
                    "description": "[MCP: \(server)] " + desc,
                    "parameters": schema
                ] as [String: Any]
            ])
        }
        return out
    }

    // Every ready server's tools, for appending to what the model is offered.
    // Round-robin across servers so one large server cannot use up the whole
    // budget and hide a small one completely.
    public func toolSchemas(cap: Int = 32) -> [[String: Any]] {
        guard settings.mcpEnabled else { return [] }
        var out: [[String: Any]] = []
        let names = states.filter { $0.status == "ready" }.map(\.name)
        var index = 0
        var more = true
        while more && out.count < cap {
            more = false
            for name in names {
                guard let list = schemas[name], index < list.count
                else { continue }
                more = true
                out.append(list[index])
                if out.count >= cap { break }
            }
            index += 1
        }
        return out
    }

    // MARK: Calling

    // Returns the same (payload, ok) pair the agent's own tools return, so the
    // execute switch can hand this straight back.
    public func call(
        _ fullName: String, args: [String: Any]
    ) async -> (String, Bool) {
        guard settings.mcpEnabled else {
            return (Self.errorJSON(
                "MCP is switched off in Nikita settings."), false)
        }
        let rest = String(fullName.dropFirst(Self.prefix.count))
        guard let sep = rest.range(of: "__") else {
            return (Self.errorJSON(
                "Malformed MCP tool name \(fullName)."), false)
        }
        let serverName = String(rest[rest.startIndex..<sep.lowerBound])
        let toolName = String(rest[sep.upperBound...])

        guard let server = settings.mcpServers.first(where: {
            $0.name == serverName && $0.enabled
        }) else {
            return (Self.errorJSON(
                "No MCP server named \"\(serverName)\" is configured."), false)
        }

        // Not connected yet (or dropped): one attempt to bring it up, so a call
        // does not fail merely because the handshake happened before the server
        // was running.
        if schemas[serverName] == nil {
            await connect(server)
            if schemas[serverName] == nil {
                let why = states.first { $0.name == serverName }?.error
                    ?? "not reachable"
                return (Self.errorJSON(
                    "MCP server \"\(serverName)\" is not available: "
                    + why), false)
            }
        }

        do {
            var params: [String: Any] = [
                "name": toolName, "arguments": args
            ]
            // The transport-neutral carrier, and the one that follows the
            // device being disconnected and replaced under a live server.
            if let meta = callMeta(for: server, tool: toolName) {
                params["_meta"] = meta
            }
            let result = try await request(
                server, method: "tools/call",
                params: params,
                timeout: Self.callTimeout)

            var text = ""
            for block in (result["content"] as? [[String: Any]]) ?? [] {
                let type = (block["type"] as? String) ?? ""
                if type == "text" {
                    if !text.isEmpty { text += "\n" }
                    text += (block["text"] as? String) ?? ""
                } else if type == "resource",
                          let r = block["resource"] as? [String: Any] {
                    if !text.isEmpty { text += "\n" }
                    text += (r["text"] as? String)
                        ?? "(resource: \((r["uri"] as? String) ?? "?"))"
                } else {
                    if !text.isEmpty { text += "\n" }
                    text += "(\(type) content, not shown)"
                }
            }
            if text.isEmpty, let structured = result["structuredContent"] {
                text = Self.encode(["value": structured])
            }

            var truncated = false
            if text.count > Self.resultCap {
                text = String(text.prefix(Self.resultCap))
                truncated = true
            }

            // isError is the server saying the tool itself failed. Reported as
            // an error so the turn's own error tracking sees it.
            if (result["isError"] as? Bool) == true {
                return (Self.errorJSON(
                    "\(serverName)/\(toolName) failed: "
                    + (text.isEmpty ? "no detail given" : text)), false)
            }

            var payload: [String: Any] = [
                "ok": true,
                "server": serverName,
                "tool": toolName,
                "result": text.isEmpty ? "(no output)" : text
            ]
            if truncated {
                payload["truncated"] = true
                payload["note"] = "Output was longer than the cap and cut "
                    + "here. "
                    + "Narrow the arguments if you need the rest."
            }
            return (Self.encode(payload), true)
        } catch {
            return (Self.errorJSON(
                "\(serverName)/\(toolName): "
                + error.localizedDescription), false)
        }
    }

    // MARK: Transport

    enum McpError: LocalizedError {
        case http(Int, String)
        case rpc(Int, String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "HTTP \(code): \(body)"
            case .rpc(let code, let message): return "\(message) (code \(code))"
            case .malformed(let why): return "unexpected reply: \(why)"
            }
        }
    }

    private func buildRequest(
        _ server: Server, body: [String: Any], timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: server.url) else {
            throw McpError.malformed("\(server.url) is not a URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Both, because Streamable HTTP lets the server answer either way.
        req.setValue("application/json, text/event-stream",
                     forHTTPHeaderField: "Accept")
        req.setValue(Self.protocolVersion,
                     forHTTPHeaderField: "MCP-Protocol-Version")
        if let sid = sessionIds[server.name] {
            req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }
        let token = settings.mcpToken(for: server.name)
        if !token.isEmpty, !server.headerName.isEmpty {
            req.setValue(token, forHTTPHeaderField: server.headerName)
        }
        if !deviceId.isEmpty {
            req.setValue("nikita-ios", forHTTPHeaderField: "X-Nikita-Client")
            req.setValue(deviceId, forHTTPHeaderField: "X-Nikita-Device")
            let method = (body["method"] as? String) ?? ""
            let tool = ((body["params"] as? [String: Any])?["name"]
                as? String) ?? ""
            if let auth = deviceAuth(
                for: server, method: method, tool: tool) {
                req.setValue(auth, forHTTPHeaderField: "X-Nikita-Device-Auth")
            }
        }
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    @discardableResult
    private func request(
        _ server: Server, method: String,
        params: [String: Any] = [:], timeout: TimeInterval
    ) async throws -> [String: Any] {
        let id = nextRequestId
        nextRequestId += 1

        var body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { body["params"] = params }

        let (data, response) = try await session.data(
            for: try buildRequest(server, body: body, timeout: timeout))

        guard let http = response as? HTTPURLResponse else {
            throw McpError.malformed("no HTTP response")
        }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"),
           !sid.isEmpty {
            sessionIds[server.name] = sid
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw McpError.http(http.statusCode, String(body.prefix(300)))
        }

        let ctype = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let message: [String: Any]
        if ctype.contains("text/event-stream") {
            guard let found = Self.firstSSEMessage(in: data) else {
                throw McpError.malformed(
                    "no JSON-RPC message in the event stream")
            }
            message = found
        } else {
            guard let obj = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                throw McpError.malformed("not a JSON object")
            }
            message = obj
        }

        if let err = message["error"] as? [String: Any] {
            throw McpError.rpc((err["code"] as? Int) ?? 0,
                               (err["message"] as? String) ?? "JSON-RPC error")
        }
        return (message["result"] as? [String: Any]) ?? [:]
    }

    private func notify(_ server: Server, method: String) async throws {
        let body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        _ = try await session.data(
            for: try buildRequest(server, body: body, timeout: 10))
    }

    // The first data: frame that parses as a JSON-RPC response. One response
    // per request here, so there is nothing to match up.
    private static func firstSSEMessage(in data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(
            separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let json = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !json.isEmpty, json != "[DONE]",
                  let d = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d)
                    as? [String: Any]
            else { continue }
            if obj["result"] != nil || obj["error"] != nil { return obj }
        }
        return nil
    }

    // MARK: JSON

    private static func encode(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8)
        else { return "{\"ok\":false,\"error\":\"encode failed\"}" }
        return s
    }

    private static func errorJSON(_ message: String) -> String {
        encode(["ok": false, "error": message])
    }
}
