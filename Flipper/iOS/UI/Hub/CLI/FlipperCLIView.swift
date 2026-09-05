import Core
import Peripheral
import SwiftUI

// A two-channel CLI for the Flipper.
//
//  * BLE  -- the phone's own Bluetooth link, commands mapped onto the RPC
//            protocol (storage, gui, apps, system). Rich, but not the raw
//            firmware shell -- BLE does not carry it.
//  * MACHINE -- a WebSocket to nikita-flipper-bridge on a computer that holds
//            the Flipper on USB. This IS the raw text CLI: subghz, nfc, gpio,
//            ir, led, vibro, js, i2c -- everything the firmware exposes.
//
// Both at once (option C): flip the channel and the same prompt reaches either.
@MainActor
final class FlipperCLI: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let kind: Kind
        enum Kind { case input, output, error, system }
    }

    enum Channel: String { case ble, machine }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var running = false
    @Published var channel: Channel = .ble
    @Published var history: [String] = []

    let bridge = MachineBridge.shared
    private let device = LiveDeviceBridge()
    private var deps: Core.Dependencies { .shared }

    init() {
        emit(.system, "Nikita CLI. Channel: BLE (RPC) / MACHINE (raw USB CLI).")
        emit(.system, "Type 'help'. Switch with the toggle or 'channel machine'.")
    }

    func clear() {
        lines.removeAll()
        emit(.system, "cleared.")
    }

    func submit(_ raw: String) {
        let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !running else { return }
        history.append(cmd)
        emit(.input, cmd)

        // Local meta-commands, handled the same on both channels.
        switch cmd.split(separator: " ").first.map(String.init) {
        case "clear": clear(); return
        case "channel":
            let arg = cmd.split(separator: " ").dropFirst().first.map(String.init)
            switch arg {
            case "ble": channel = .ble; emit(.system, "channel: BLE")
            case "machine": channel = .machine; emit(.system, "channel: MACHINE")
            default: emit(.system, "channel is \(channel.rawValue.uppercased())")
            }
            return
        case "connect":
            let arg = cmd.split(separator: " ").dropFirst().first.map(String.init)
            if let arg { bridge.setURL(arg) }
            bridge.connect()
            emit(.system, "connecting to \(bridge.urlString) …")
            return
        case "disconnect":
            bridge.disconnect(); emit(.system, "bridge disconnected"); return
        default: break
        }

        running = true
        Task {
            let out: [Line]
            switch channel {
            case .ble: out = await runBLE(cmd)
            case .machine: out = await runMachine(cmd)
            }
            for line in out { emit(line.kind, line.text) }
            running = false
        }
    }

    // MARK: MACHINE channel (raw firmware CLI over the bridge)

    private func runMachine(_ cmd: String) async -> [Line] {
        if cmd == "help" { return [.init(text: machineHelp, kind: .output)] }
        // The bridge is reached through the Flipper's SD card over Bluetooth --
        // no WebSocket, no WiFi. The phone leaves the command in a mailbox file,
        // the bridge on the computer picks it up over USB, runs it and leaves
        // the answer back. See mailboxSend.
        do {
            let output = try await mailboxSend(cmd)
            return [.init(text: output.isEmpty ? "(no output)" : output,
                          kind: .output)]
        } catch {
            return [.init(text: error.localizedDescription, kind: .error)]
        }
    }

    // MARK: The SD-card mailbox (phone <-> bridge, over Bluetooth)

    private static let mailboxReq = "/ext/nikita/bridge/req"
    private static let mailboxRes = "/ext/nikita/bridge/res"

    // Leave a command on the card and wait for the matching answer.
    //
    // Every request carries an id, and the reply must carry the same one: the
    // response file may still hold a previous answer when this starts polling,
    // and taking that would pair a command with the wrong output. So the id is
    // the handshake -- an answer with a different id is somebody else's, or
    // stale, and is ignored until the right one lands or the wait runs out.
    private func mailboxSend(_ command: String) async throws -> String {
        guard await device.isConnected else {
            throw MailboxError.noFlipper
        }
        let id = String(UInt32.random(in: 1...UInt32.max))
        // "id.base64(command)" -- one line, only base64 characters. The serial
        // CLI on the far side mangles spaces and newlines when a file crosses
        // it, and a shell command is nothing but spaces; base64 has neither, so
        // it survives the trip whole.
        let encoded = Data(command.utf8).base64EncodedString()
        try await device.writeFile(
            at: Self.mailboxReq, content: id + "." + encoded)

        // Poll for the answer. The bridge polls its side about twice a second,
        // runs the command, then writes back -- so a second or two is normal,
        // longer for something slow. Give up after 30s rather than hang.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let body: String
            do {
                body = try await device.readFile(at: Self.mailboxRes)
            } catch {
                continue   // not written yet
            }
            let parts = body.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ".", maxSplits: 1,
                       omittingEmptySubsequences: false)
            guard let head = parts.first, String(head) == id else {
                continue
            }
            try? await device.deleteFile(at: Self.mailboxRes, recursive: false)
            guard parts.count > 1 else { return "" }
            // Restore any padding lost in transit and ignore stray bytes: the
            // "=" tail gets clipped somewhere on the serial hop, and strict
            // base64 refuses a string that is not a multiple of four. The
            // content is intact -- only the padding needs putting back.
            var b64 = String(parts[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while b64.count % 4 != 0 { b64 += "=" }
            guard let data = Data(base64Encoded: b64,
                                  options: .ignoreUnknownCharacters) else {
                return ""
            }
            return String(decoding: data, as: UTF8.self)
        }
        throw MailboxError.timedOut
    }

    enum MailboxError: LocalizedError {
        case noFlipper
        case timedOut
        var errorDescription: String? {
            switch self {
            case .noFlipper:
                return "No Flipper over Bluetooth. Connect first."
            case .timedOut:
                return "No answer from the bridge. Is nikita-flipper-bridge "
                    + "running on the computer, with --mailbox?"
            }
        }
    }

    // MARK: BLE channel (RPC-mapped commands)

    // The prefix says WHICH MACHINE, not which spelling.
    //
    // A bare Unix name is the computer the Flipper is plugged into; the same
    // verb with an "f" is the Flipper itself. "ls" lists a folder on that
    // computer, "fls" lists one on the SD card. This is the desktop panel's
    // rule, and it is the whole reason both spellings exist -- treating them as
    // twins, which this did at first, threw away the distinction that makes
    // them useful.
    //
    // Verbs that only make sense on one side (screen, btn, unlock, info) need
    // no prefix: there is nothing on the other machine they could mean.
    private static let dualVerbs: Set<String> = [
        "ls", "cat", "tree", "stat", "md5", "mkdir", "rm", "mv", "df",
        "touch", "echo", "grep", "head", "tail", "wc", "find", "du",
        "whoami", "open", "close"
    ]

    // Spellings of the same verb, within one machine.
    private static func normalise(_ verb: String) -> String {
        let synonyms = [
            "dir": "ls", "read": "cat", "del": "rm", "rename": "mv",
            "hash": "md5", "storage": "df", "press": "btn", "beep": "alert",
            "power_info": "power", "property": "props", "device_info": "info"
        ]
        return synonyms[verb] ?? verb
    }

    private func runBLE(_ line: String) async -> [Line] {
        let parts = line.split(whereSeparator: { $0 == " " }).map(String.init)
        guard let raw = parts.first else { return [] }
        let verb = Self.normalise(raw)

        // Bare Unix verb: the user means the computer. It travels through the
        // bridge, because the phone cannot reach that machine any other way.
        if Self.dualVerbs.contains(verb) {
            // The computer, reached over the SD mailbox through Bluetooth.
            // No WebSocket to check -- if the bridge is not running, the
            // mailbox wait times out and says so.
            return await runMachine("host " + line)
        }

        // "f" + a dual verb: the Flipper. Everything below works on the card.
        let stripped = raw.hasPrefix("f") && raw.count > 1
            ? Self.normalise(String(raw.dropFirst()))
            : verb
        let cmd = Self.dualVerbs.contains(stripped) ? stripped : verb
        let args = Array(parts.dropFirst())

        if cmd != "help", !(await device.isConnected) {
            return [.init(text: "No Flipper connected over Bluetooth.",
                          kind: .error)]
        }

        do {
            switch cmd {
            case "help": return [.init(text: bleHelp, kind: .output)]

            case "info":
                await deps.device.getDeviceInfo()
                let keys = deps.device.info.keys
                return keys.isEmpty
                    ? [.init(text: "(no device info yet)", kind: .output)]
                    : [.init(text: keys.sorted { $0.key < $1.key }
                        .map { "\($0.key): \($0.value)" }
                        .joined(separator: "\n"), kind: .output)]

            case "power":
                let pairs = try await drainInfo(deps.nikitaSystem.powerInfo())
                return [.init(text: pairs.isEmpty ? "(no data)"
                    : pairs.sorted { $0.0 < $1.0 }
                        .map { "\($0.0): \($0.1)" }.joined(separator: "\n"),
                    kind: .output)]

            case "props":
                let key = args.first ?? ""
                let pairs = try await drainProps(deps.nikitaSystem.property(key))
                return [.init(text: pairs.isEmpty ? "(no properties)"
                    : pairs.sorted { $0.0 < $1.0 }
                        .map { "\($0.0): \($0.1)" }.joined(separator: "\n"),
                    kind: .output)]

            case "ls": return try await listCmd(args.first ?? "/ext")
            case "tree": return try await treeCmd(args.first ?? "/ext")

            case "cat":
                guard let p = args.first else { return usage("cat <path>") }
                let text = try await device.readFile(at: p)
                return [.init(text: text.isEmpty ? "(empty)" : text,
                              kind: .output)]

            case "write":
                guard args.count >= 2 else {
                    return usage("write <path> <content...>")
                }
                let content = args.dropFirst().joined(separator: " ")
                    .replacingOccurrences(of: "\\n", with: "\n")
                try await device.writeFile(at: args[0], content: content)
                return ok("wrote \(content.utf8.count) bytes -> \(args[0])")

            case "mkdir":
                guard let p = args.first else { return usage("mkdir <path>") }
                try await device.makeDir(at: p); return ok("created \(p)")

            case "rm":
                guard let p = args.first else { return usage("rm <path> [-r]") }
                let r = args.contains("-r") || args.contains("-rf")
                try await device.deleteFile(at: p, recursive: r)
                return ok("deleted \(p)")

            case "mv":
                guard args.count >= 2 else { return usage("mv <from> <to>") }
                try await device.renameFile(from: args[0], to: args[1])
                return ok("\(args[0]) -> \(args[1])")

            case "stat":
                guard let p = args.first else { return usage("stat <path>") }
                let i = try await device.fileInfo(at: p)
                return [.init(text: "exists: \(i.exists)  type: \(i.type)  "
                    + "size: \(i.size)", kind: .output)]

            case "md5":
                guard let p = args.first else { return usage("md5 <path>") }
                let hash = try await deps.nikitaStorage.hash(of: .init(string: p))
                return [.init(text: "\(hash.value)  \(p)", kind: .output)]

            case "df":
                let path = args.first ?? "/ext"
                let space = try await deps.nikitaStorage
                    .space(of: .init(string: path))
                let used = space.total - space.free
                return [.init(text: "\(path)  used \(human(used)) / "
                    + "\(human(space.total))  (free \(human(space.free)))",
                    kind: .output)]

            case "screen":
                return [.init(text: try await device.readScreen(), kind: .output)]

            case "btn":
                guard let b = args.first else {
                    return usage("btn <up|down|left|right|ok|back> [n]")
                }
                let n = args.count > 1 ? Int(args[1]) ?? 1 : 1
                try await device.pressButton(b, times: n)
                return ok("pressed \(b) x\(n)")

            case "open":
                guard !args.isEmpty else { return usage("open <App name>") }
                let name = args.joined(separator: " ")
                try await device.runApp(action: "open", name: name)
                return ok("opened \(name)")

            case "close":
                try await device.runApp(action: "close", name: nil)
                return ok("closed app")

            case "alert":
                try await deps.nikitaGUI.playAlert(); return ok("alert sent")

            case "unlock":
                try await deps.nikitaDesktop.unlock(); return ok("unlocked")

            case "date":
                let date = try await deps.nikitaSystem.getDate()
                return [.init(text: "\(date)", kind: .output)]

            case "ping":
                let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
                let echo = try await deps.nikitaSystem.ping(bytes)
                return ok(echo == bytes ? "pong" : "pong (mismatch)")

            case "reboot":
                let mode: OutgoingMessage.RebootMode
                switch args.first {
                case "dfu": mode = .dfu
                case "update": mode = .update
                default: mode = .os
                }
                try await deps.nikitaSystem.reboot(to: mode)
                return ok("reboot (\(args.first ?? "os")) sent")

            // Text utilities. The firmware has none of these and has no room
            // to grow them -- it is an STM32WB55 with 256 KB of RAM -- so the
            // file is read once over RPC and the work happens on the phone.
            // Exactly how the desktop does it, for exactly the same reason.
            case "grep":
                guard args.count >= 2 else {
                    return [.init(text: "usage: grep <pattern> <path>",
                                  kind: .error)]
                }
                let pattern = args[0].lowercased()
                let body = try await device.readFile(at: args[1])
                let hits = body.split(separator: "\n", omittingEmptySubsequences: false)
                    .enumerated()
                    .filter { $0.element.lowercased().contains(pattern) }
                    .map { "\($0.offset + 1): \($0.element)" }
                return [.init(
                    text: hits.isEmpty ? "(no matches)"
                        : hits.joined(separator: "\n"),
                    kind: .output)]

            case "head", "tail":
                guard let path = args.last, !path.isEmpty else {
                    return [.init(text: "usage: \(cmd) [n] <path>", kind: .error)]
                }
                let count = args.count > 1 ? (Int(args[0]) ?? 10) : 10
                let lines = try await device.readFile(at: path)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                let picked = cmd == "head"
                    ? lines.prefix(count) : lines.suffix(count)
                return [.init(text: picked.joined(separator: "\n"),
                              kind: .output)]

            case "wc":
                guard let path = args.first else {
                    return [.init(text: "usage: wc <path>", kind: .error)]
                }
                let body = try await device.readFile(at: path)
                let lines = body.split(
                    separator: "\n", omittingEmptySubsequences: false).count
                let words = body.split(whereSeparator: { $0.isWhitespace }).count
                return ok("\(lines) lines, \(words) words, \(body.count) chars")

            case "find":
                guard args.count >= 2 else {
                    return [.init(text: "usage: find <path> <name>",
                                  kind: .error)]
                }
                return try await findCmd(args[0], needle: args[1].lowercased())

            case "du":
                let root = args.first ?? "/ext"
                let total = try await sizeOf(root)
                return ok("\(root): \(total) bytes")

            case "touch":
                guard let path = args.first else {
                    return [.init(text: "usage: touch <path>", kind: .error)]
                }
                try await device.writeFile(at: path, content: "")
                return ok("created \(path)")

            case "echo":
                guard args.count >= 2 else {
                    return [.init(text: "usage: echo <text> <path>",
                                  kind: .error)]
                }
                let text = args.dropLast().joined(separator: " ")
                try await device.writeFile(at: args[args.count - 1],
                                           content: text)
                return ok("wrote \(text.count) chars")

            case "whoami":
                await deps.device.getDeviceInfo()
                let name = deps.device.info.keys["hardware_name"] ?? "unknown"
                return ok(name)

            case "vibro":
                // No RPC for the motor; the alert does buzz, which is the
                // honest nearest thing rather than a silent no-op.
                try await deps.device.playAlert()
                return ok("buzzed (vibro proper needs the machine channel)")

            case "shutdown":
                return [.init(
                    text: "shutdown needs the machine channel: "
                        + "channel machine, then 'power off'",
                    kind: .error)]

            default:
                return [.init(text: "unknown BLE command: \(cmd) "
                    + "(type 'help', or 'channel machine' for the raw CLI)",
                    kind: .error)]
            }
        } catch {
            return [.init(text: error.localizedDescription, kind: .error)]
        }
    }

    // Walk the card looking for a name. Depth-limited: every level is another
    // round of RPC calls over Bluetooth, and an unbounded walk of /ext takes
    // long enough to look like a hang.
    private func findCmd(
        _ root: String, needle: String, depth: Int = 3
    ) async throws -> [Line] {
        var hits: [String] = []
        func walk(_ path: String, _ level: Int) async {
            guard level <= depth,
                  let items = try? await device.listFiles(at: path) else { return }
            for entry in items {
                let full = path.hasSuffix("/")
                    ? path + entry.name : path + "/" + entry.name
                if entry.name.lowercased().contains(needle) { hits.append(full) }
                if entry.type == "dir" { await walk(full, level + 1) }
            }
        }
        await walk(root, 1)
        return [.init(
            text: hits.isEmpty ? "(no matches)" : hits.joined(separator: "\n"),
            kind: .output)]
    }

    private func sizeOf(_ root: String, depth: Int = 3) async throws -> Int {
        var total = 0
        func walk(_ path: String, _ level: Int) async {
            guard level <= depth,
                  let items = try? await device.listFiles(at: path) else { return }
            for entry in items {
                if entry.type == "dir" {
                    let full = path.hasSuffix("/")
                        ? path + entry.name : path + "/" + entry.name
                    await walk(full, level + 1)
                } else {
                    total += entry.size
                }
            }
        }
        await walk(root, 1)
        return total
    }

    private func listCmd(_ path: String) async throws -> [Line] {
        let items = try await device.listFiles(at: path)
        if items.isEmpty { return [.init(text: "(empty)", kind: .output)] }
        let body = items.map { e -> String in
            let tag = e.type == "dir" ? "[dir] " : "      "
            let size = e.type == "dir" ? "" : "  (\(e.size) b)"
            return "\(tag)\(e.name)\(size)"
        }.joined(separator: "\n")
        return [.init(text: body, kind: .output)]
    }

    private func treeCmd(_ path: String, depth: Int = 2) async throws -> [Line] {
        var out: [String] = []
        func walk(_ p: String, _ prefix: String, _ level: Int) async {
            guard level <= depth,
                  let items = try? await device.listFiles(at: p) else { return }
            for e in items {
                out.append("\(prefix)\(e.type == "dir" ? "📁" : "  ") \(e.name)")
                if e.type == "dir" {
                    await walk("\(p)/\(e.name)", prefix + "  ", level + 1)
                }
            }
        }
        await walk(path, "", 1)
        return [.init(text: out.isEmpty ? "(empty)" : out.joined(separator: "\n"),
                      kind: .output)]
    }

    // MARK: Helpers

    private func drainInfo(
        _ stream: SystemAPI.OldInfoStream
    ) async throws -> [(String, String)] {
        var result: [(String, String)] = []
        for try await pair in stream { result.append(pair) }
        return result
    }

    private func drainProps(
        _ stream: SystemAPI.ProperyStream
    ) async throws -> [(String, String)] {
        var result: [(String, String)] = []
        for try await p in stream { result.append((p.key, p.value)) }
        return result
    }

    private func human(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes), i = 0
        while value >= 1024, i < units.count - 1 { value /= 1024; i += 1 }
        return String(format: i == 0 ? "%.0f%@" : "%.1f%@", value, units[i])
    }

    private func ok(_ msg: String) -> [Line] { [.init(text: msg, kind: .output)] }
    private func usage(_ msg: String) -> [Line] {
        [.init(text: "usage: \(msg)", kind: .error)]
    }
    private func emit(_ kind: Line.Kind, _ text: String) {
        lines.append(.init(text: text, kind: kind))
    }

    private var bleHelp: String {
        """
        Two machines, one prompt. The prefix picks which.

          ls  /Users/me      the COMPUTER the Flipper is plugged into
          fls /ext           the FLIPPER itself

        Bare Unix verbs go to the computer, through nikita-flipper-bridge
        running there. The same verb with an f goes to the Flipper over
        Bluetooth. Both sides:
          ls  cat  tree  stat  md5  mkdir  rm  mv  df  touch  echo
          grep  head  tail  wc  find  du  whoami  open  close

        Flipper only, no prefix needed -- nothing on the computer they
        could mean:
          info  power  props  screen  btn <name> [n]  alert  vibro
          unlock  date  ping  reboot [os|dfu|update]  write <path> <text>

        Text tools run on the phone for the Flipper side: the firmware has no
        grep and no room to grow one, so the file is read once and filtered
        here.

        The computer needs nikita-flipper-bridge running on it, plugged to
        the Flipper by USB. The phone reaches it through the Flipper's SD
        card over Bluetooth -- no WiFi, no address to type. Start it with:
          python3 bridge.py --mailbox --allow-host

        channel machine       type straight into the Flipper's own shell
        clear
        """
    }

    private var machineHelp: String {
        """
        MACHINE channel -- the Flipper's REAL text CLI, reached through the
        bridge on the computer. Anything you type goes to the firmware shell:
          device_info        help              storage list /ext
          subghz             nfc               gpio mode PA7 1
          ir rx              led r 255         vibro 1
          js /ext/apps/x.js  ps                free
        Needs nikita-flipper-bridge running on the computer holding the
        Flipper, started with --mailbox. No WiFi: it travels the SD card.
        Local: channel ble | clear | disconnect
        """
    }
}

struct FlipperCLIView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cli = FlipperCLI()
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            channelBar
            output
            Divider().overlay(Color.a1.opacity(0.4))
            inputBar
        }
        .background(Color.background)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackground(Color.background)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            LeadingToolbarItems { BackButton { dismiss() } }
            PrincipalToolbarItems(alignment: .leading) { Title("CLI") }
        }
    }

    private var channelBar: some View {
        HStack(spacing: 6) {
            Text("BLE")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.a2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.a2.opacity(0.6), lineWidth: 1))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.groupedBackground)
    }

    private var bridgeColor: Color {
        switch cli.bridge.state {
        case .connected: return .a2
        case .connecting: return .sYellow
        case .failed: return .sRed
        case .disconnected: return .black30
        }
    }

    private var bridgeLabel: String {
        switch cli.bridge.state {
        case .connected: return "bridge up"
        case .connecting: return "connecting"
        case .failed(let e): return e
        case .disconnected: return "connect ws://…"
        }
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(cli.lines) { line in row(line).id(line.id) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .onChange(of: cli.lines.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func row(_ line: FlipperCLI.Line) -> some View {
        Group {
            switch line.kind {
            case .input:
                (Text(prompt).foregroundColor(.a2)
                    + Text(line.text).foregroundColor(.primary))
            case .output:
                Text(line.text).foregroundColor(.primary.opacity(0.9))
            case .error:
                Text(line.text).foregroundColor(.sRed)
            case .system:
                Text(line.text).foregroundColor(.a1)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var prompt: String {
        cli.channel == .machine ? "flipper(usb)> " : "flipper> "
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text(prompt)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.a2)
                .lineLimit(1)
                .fixedSize()
            TextField("command", text: $input)
                .font(.system(.caption, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit(send)
                .submitLabel(.send)
            if cli.running {
                ProgressView().scaleEffect(0.7)
            } else {
                Button(action: send) {
                    Image(systemName: "return").foregroundColor(.a1)
                }
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.groupedBackground)
    }

    private func send() {
        let cmd = input
        input = ""
        cli.submit(cmd)
        focused = true
    }
}
