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

    let bridge = MachineBridge()
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
        guard bridge.isConnected else {
            return [.init(text: "MACHINE channel not connected. Run the bridge "
                + "on your computer, then: connect ws://<mac-ip>:8765",
                kind: .error)]
        }
        do {
            let output = try await bridge.run(cmd)
            return [.init(text: output.isEmpty ? "(no output)" : output,
                          kind: .output)]
        } catch {
            return [.init(text: error.localizedDescription, kind: .error)]
        }
    }

    // MARK: BLE channel (RPC-mapped commands)

    private func runBLE(_ line: String) async -> [Line] {
        let parts = line.split(whereSeparator: { $0 == " " }).map(String.init)
        guard let cmd = parts.first else { return [] }
        let args = Array(parts.dropFirst())

        if cmd != "help", !(await device.isConnected) {
            return [.init(text: "No Flipper connected over Bluetooth.",
                          kind: .error)]
        }

        do {
            switch cmd {
            case "help": return [.init(text: bleHelp, kind: .output)]

            case "info", "device_info":
                await deps.device.getDeviceInfo()
                let keys = deps.device.info.keys
                return keys.isEmpty
                    ? [.init(text: "(no device info yet)", kind: .output)]
                    : [.init(text: keys.sorted { $0.key < $1.key }
                        .map { "\($0.key): \($0.value)" }
                        .joined(separator: "\n"), kind: .output)]

            case "power", "power_info":
                let pairs = try await drainInfo(deps.nikitaSystem.powerInfo())
                return [.init(text: pairs.isEmpty ? "(no data)"
                    : pairs.sorted { $0.0 < $1.0 }
                        .map { "\($0.0): \($0.1)" }.joined(separator: "\n"),
                    kind: .output)]

            case "props", "property":
                let key = args.first ?? ""
                let pairs = try await drainProps(deps.nikitaSystem.property(key))
                return [.init(text: pairs.isEmpty ? "(no properties)"
                    : pairs.sorted { $0.0 < $1.0 }
                        .map { "\($0.0): \($0.1)" }.joined(separator: "\n"),
                    kind: .output)]

            case "ls", "dir": return try await listCmd(args.first ?? "/ext")
            case "tree": return try await treeCmd(args.first ?? "/ext")

            case "cat", "read":
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

            case "rm", "del":
                guard let p = args.first else { return usage("rm <path> [-r]") }
                let r = args.contains("-r") || args.contains("-rf")
                try await device.deleteFile(at: p, recursive: r)
                return ok("deleted \(p)")

            case "mv", "rename":
                guard args.count >= 2 else { return usage("mv <from> <to>") }
                try await device.renameFile(from: args[0], to: args[1])
                return ok("\(args[0]) -> \(args[1])")

            case "stat":
                guard let p = args.first else { return usage("stat <path>") }
                let i = try await device.fileInfo(at: p)
                return [.init(text: "exists: \(i.exists)  type: \(i.type)  "
                    + "size: \(i.size)", kind: .output)]

            case "md5", "hash":
                guard let p = args.first else { return usage("md5 <path>") }
                let hash = try await deps.nikitaStorage.hash(of: .init(string: p))
                return [.init(text: "\(hash.value)  \(p)", kind: .output)]

            case "df", "storage":
                let path = args.first ?? "/ext"
                let space = try await deps.nikitaStorage
                    .space(of: .init(string: path))
                let used = space.total - space.free
                return [.init(text: "\(path)  used \(human(used)) / "
                    + "\(human(space.total))  (free \(human(space.free)))",
                    kind: .output)]

            case "screen":
                return [.init(text: try await device.readScreen(), kind: .output)]

            case "btn", "press":
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

            case "alert", "beep":
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

            default:
                return [.init(text: "unknown BLE command: \(cmd) "
                    + "(type 'help', or 'channel machine' for the raw CLI)",
                    kind: .error)]
            }
        } catch {
            return [.init(text: error.localizedDescription, kind: .error)]
        }
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
        BLE channel -- RPC-mapped commands:
        info                 full device_info
        power                battery / charge info
        props [key]          system properties
        ls [path] | tree     list a folder (default /ext)
        cat <path>           read a file
        write <path> <text>  write text (\\n = newline)
        mkdir <path>         make a folder
        rm <path> [-r]       delete
        mv <from> <to>       rename / move
        stat <path>          exists / type / size
        md5 <path>           file hash
        df [path]            storage usage
        screen               screen as ASCII
        btn <dir> [n]        up/down/left/right/ok/back
        open <App> / close   launch / exit an app
        alert                make the Flipper beep
        unlock               unlock the desktop
        date | ping          time / round-trip
        reboot [os|dfu|update]

        channel machine      switch to the raw USB CLI (subghz, nfc, gpio, ...)
        connect ws://ip:8765 point at the machine bridge
        clear
        """
    }

    private var machineHelp: String {
        """
        MACHINE channel -- the Flipper's REAL text CLI over USB (via the bridge).
        Anything you type goes straight to the firmware shell. Examples:
          device_info        help              storage list /ext
          subghz             nfc               gpio mode PA7 1
          ir rx              led r 255         vibro 1
          js /ext/apps/x.js  ps                free
        Not connected? Run nikita-flipper-bridge on the computer holding the
        Flipper on USB, then:  connect ws://<mac-ip>:8765
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
