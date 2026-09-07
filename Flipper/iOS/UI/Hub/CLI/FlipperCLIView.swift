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

    @Published private(set) var lines: [Line] = []
    @Published private(set) var running = false
    @Published var history: [String] = []

    // Where "ls" and a bare command land, one per side. The machine's is
    // resolved by its own shell (cd there, run, report pwd); the Flipper has no
    // shell, so the app does the path math for it. Shown in the prompt so you
    // always know where you are before you look.
    @Published var machineCwd: String = "~"
    @Published var flipperCwd: String = "/ext"

    // Live python3 REPL on the computer, driven line-by-line through the bridge.
    @Published var pythonMode = false
    @Published var pythonMore = false

    // The built-in editor panel (edit / nano / vi ...).
    @Published var editorOpen = false
    @Published var editorPath = ""
    @Published var editorText = ""
    @Published var editorIsFlipper = false
    @Published var editorSaving = false
    @Published var editorMessage: String?

    // Every command name, for the suggestion bar above the keyboard.
    static let allCommands: [String] = {
        let computer = ["ls","cat","tree","stat","md5","mkdir","rm","mv","cp",
            "touch","echo","grep","sed","head","tail","wc","find","file","diff",
            "du","df","cd","pwd","ps","kill","whoami","hostname","uname","id",
            "env","which","date","ping","ifconfig","netstat","dig","nslookup",
            "traceroute","ssh","git","python3","docker","nmap","tar","zip",
            "unzip","gzip","openssl","base64","sha256sum","hexdump","xxd","awk",
            "chmod","man","host","wget","curl","edit","nano","history","clear",
            "help"]
        let flipper = ["fls","fcat","ftree","fstat","fmd5","fmkdir","frm","fmv",
            "ftouch","fecho","fgrep","fsed","fhead","ftail","fwc","ffind","ffile",
            "fdiff","fdu","fdf","fcd","fpwd","fwhoami","fopen","fclose","freboot",
            "fshutdown","fvibro","flocate","fwget"]
        let firmware = ["device_info","info","storage","gpio","subghz","nfc",
            "rfid","ir","led","power","loader","js","bt","top","log","free",
            "uptime","vibro","nikita"]
        return (computer + flipper + firmware).sorted()
    }()

    let bridge = MachineBridge.shared
    private let device = LiveDeviceBridge()
    private var deps: Core.Dependencies { .shared }

    // The Flipper's name, for the prompt. Filled in once the device answers.
    @Published var devName: String = "flipper"

    init() {
        Task { await loadName() }
    }

    private func loadName() async {
        await deps.device.getDeviceInfo()
        if let name = deps.device.info.keys["hardware_name"], !name.isEmpty {
            devName = name
        }
    }

    func clear() {
        lines.removeAll()
        emit(.system, "cleared.")
    }

    private func expandHistory(_ token: String) -> String? {
        if token == "!!" { return history.last }
        let body = String(token.dropFirst())
        if let n = Int(body) {
            return (n >= 1 && n <= history.count) ? history[n - 1] : nil
        }
        return history.last(where: { $0.hasPrefix(body) })
    }

    func submit(_ raw: String) {
        var cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !running else { return }
        // In a live python3 session every line goes straight to the interpreter.
        if pythonMode {
            history.append(cmd)
            emit(.input, cmd)
            running = true
            Task {
                let out = await runPython(cmd)
                for line in out { emit(line.kind, line.text) }
                running = false
            }
            return
        }
        // History expansion, resolved before the line runs: !! repeats the
        // last command, !12 re-runs entry 12, !ls the last one starting "ls".
        if cmd.hasPrefix("!") {
            guard let expanded = expandHistory(cmd) else {
                emit(.input, raw)
                emit(.error, "\(raw): no match in history")
                return
            }
            cmd = expanded
        }
        history.append(cmd)
        emit(.input, cmd)

        if cmd == "clear" { clear(); return }

        running = true
        Task {
            let out = await route(cmd)
            for line in out { emit(line.kind, line.text) }
            running = false
        }
    }

    // MARK: MACHINE channel (raw firmware CLI over the bridge)

    // The computer, always relative to where you are on it.
    //
    // cd is resolved by the machine's own shell -- "cd <here> && cd <there> &&
    // pwd" moves and reports the new absolute path in one step, which also
    // proves the target exists. Every other verb runs after a cd into the
    // current directory, so "ls" with no argument lists where you are and a
    // relative path means what it says.
    private func runMachineCwd(verb: String, args: [String]) async -> [Line] {
        let cwd = Self.shq(machineCwd)

        if verb == "cd" {
            let target = args.first.map(Self.shq) ?? "~"
            let out = await runMachineRaw(
                "cd \(cwd) 2>/dev/null; cd \(target) && pwd")
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") {
                machineCwd = path
                return []          // moved; the prompt shows the new place
            }
            return [.init(text: out.isEmpty ? "cd: no such directory" : out,
                          kind: .error)]
        }
        if verb == "pwd" {
            let out = await runMachineRaw("cd \(cwd) 2>/dev/null && pwd")
            return [.init(text: out.isEmpty ? machineCwd : out, kind: .output)]
        }

        // Everything else runs where you are. A bare ls gets -la so it is
        // actually useful; a relative path in any verb resolves against cwd.
        let tail = args.map(Self.shq).joined(separator: " ")
        let body = (verb == "ls" && args.isEmpty)
            ? "ls -la"
            : verb + (tail.isEmpty ? "" : " " + tail)
        let out = await runMachineRaw("cd \(cwd) 2>/dev/null && " + body)
        return [.init(text: out.isEmpty ? "(no output)" : out, kind: .output)]
    }

    private func runMachineRaw(_ shell: String) async -> String {
        do { return try await mailboxSend("host " + shell) }
        catch { return error.localizedDescription }
    }

    // The computer as a real shell: the whole line runs there, in the folder
    // you are standing in, so pipes, quotes, globs and flags all survive. Only
    // cd and pwd are caught, to keep the tracked cwd in step with the machine.
    private func runMachineLine(_ line: String) async -> [Line] {
        let parts = line.split(whereSeparator: { $0 == " " }).map(String.init)
        let verb = parts.first.map(Self.normalise) ?? ""
        let cwd = Self.shq(machineCwd)
        if verb == "cd" {
            let target = parts.count > 1 ? Self.shq(parts[1]) : "~"
            let out = await runMachineRaw(
                "cd \(cwd) 2>/dev/null; cd \(target) && pwd")
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") { machineCwd = path; return [] }
            return [.init(text: out.isEmpty ? "cd: no such directory" : out,
                          kind: .error)]
        }
        if verb == "pwd" {
            let out = await runMachineRaw("cd \(cwd) 2>/dev/null && pwd")
            return [.init(text: out.isEmpty ? machineCwd : out, kind: .output)]
        }
        let out = await runMachineRaw("cd \(cwd) 2>/dev/null && " + line)
        return [.init(text: out.isEmpty ? "(no output)" : out, kind: .output)]
    }

    // A raw firmware command, to the Flipper's own shell through the bridge.
    private func runFlipperRaw(_ command: String) async -> String {
        do { return try await mailboxSend(command) }
        catch { return error.localizedDescription }
    }

    private func sendMailbox(_ command: String) async -> String {
        do { return try await mailboxSend(command) }
        catch { return error.localizedDescription }
    }

    private static func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    // cp [-r] <src> <dst>: the bridge moves the bytes -- binary-safe and
    // MD5-verified -- in whichever direction the paths imply (Mac<->Flipper).
    private func runTransfer(_ args: [String]) async -> [Line] {
        let flags = args.filter { $0.hasPrefix("-") }
        let paths = args.filter { !$0.hasPrefix("-") }
        guard paths.count >= 2 else { return usage("cp [-r] <src> <dst>") }
        let flagStr = flags.isEmpty ? "" : " " + flags.joined(separator: " ")
        let cmd = "xcp \(Self.b64(paths[0])) \(Self.b64(paths[1])) "
            + "\(Self.b64(machineCwd))\(flagStr)"
        let out = await sendMailbox(cmd)
        return [.init(text: out.isEmpty ? "(done)" : out, kind: .output)]
    }

    // wget/fwget <url> [dest]: download on the computer, land it on whichever
    // machine the destination points at (fwget always the Flipper).
    private func runWget(_ args: [String], toFlipper: Bool) async -> [Line] {
        guard let url = args.first else { return usage("wget <url> [dest]") }
        let base = URL(string: url)?.lastPathComponent ?? "download"
        let name = base.isEmpty ? "download" : base
        let dst: String
        if args.count > 1 { dst = args[1] }
        else if toFlipper { dst = flipperCwd + "/" + name }
        else { dst = name }
        let cmd = "xwget \(Self.b64(url)) \(Self.b64(dst)) \(Self.b64(machineCwd))"
        let out = await sendMailbox(cmd)
        return [.init(text: out.isEmpty ? "(done)" : out, kind: .output)]
    }

    // One line into the live python session; the reply's first byte is state:
    // \u{00} done, \u{01} needs more input, \u{02} the session exited.
    private func runPython(_ line: String) async -> [Line] {
        let resp = await sendMailbox("xpy \(Self.b64(line))")
        guard let flag = resp.first else { pythonMore = false; return [] }
        let text = String(resp.dropFirst()).trimmingCharacters(in: .newlines)
        switch flag {
        case "\u{02}":
            pythonMode = false
            pythonMore = false
            var out: [Line] = text.isEmpty ? [] : [.init(text: text, kind: .output)]
            out.append(.init(text: "[ python3 session ended ]", kind: .system))
            return out
        case "\u{01}":
            pythonMore = true
            return text.isEmpty ? [] : [.init(text: text, kind: .output)]
        default:
            pythonMore = false
            return text.isEmpty ? [] : [.init(text: text, kind: .output)]
        }
    }

    // edit/nano/vi <path>: pull the file into the editor sheet; the machine is
    // the one the path points at (a Flipper path over RPC, else the computer).
    private func openEditor(_ args: [String]) async -> [Line] {
        guard let path = args.first else { return usage("edit <path>") }
        let isFlip = path.hasPrefix("/ext") || path.hasPrefix("/int")
        let content: String
        if isFlip {
            content = (try? await device.readFile(at: path)) ?? ""
        } else {
            content = await runMachineRaw("cat \(Self.shq(path)) 2>/dev/null")
        }
        editorPath = path
        editorIsFlipper = isFlip
        editorText = content
        editorMessage = nil
        editorOpen = true
        return [.init(text: "[ editing \(path) -- save or cancel in the editor ]",
                      kind: .system)]
    }

    func saveEditor() async {
        editorSaving = true
        defer { editorSaving = false }
        if editorIsFlipper {
            do {
                try await device.writeFile(at: editorPath, content: editorText)
                editorMessage = "saved \(editorPath)"
                editorOpen = false
            } catch {
                editorMessage = "save failed: \(error.localizedDescription)"
            }
        } else {
            let encoded = Data(editorText.utf8).base64EncodedString()
            let out = await runMachineRaw(
                "printf %s \(Self.shq(encoded)) | openssl base64 -d -A > "
                + "\(Self.shq(editorPath))")
            if out.isEmpty {
                editorMessage = "saved \(editorPath)"
                editorOpen = false
            } else {
                editorMessage = out
            }
        }
    }

    // Single-quote for the shell, so a path with a space or a quote is one
    // argument and never a second command. A leading "~" (or "~/") is kept
    // OUTSIDE the quotes so the shell still expands it to $HOME -- quoting the
    // tilde makes "cd '~'" look for a directory literally named ~, which fails
    // and leaves every "ls" from the home dir empty.
    private static func shq(_ value: String) -> String {
        func q(_ v: String) -> String {
            "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        if value == "~" { return "~" }
        if value.hasPrefix("~/") { return "~/" + q(String(value.dropFirst(2))) }
        return q(value)
    }

    // Resolve a Flipper path by hand -- no shell over there to do it. Absolute
    // stays as is; "." and ".." and plain names fold against the current dir.
    // Never climbs above /ext or /int: those are the two roots.
    static func resolveFlipper(_ cwd: String, _ target: String) -> String {
        let base = target.hasPrefix("/") ? [] : cwd.split(separator: "/").map(String.init)
        var parts = base
        for piece in target.split(separator: "/").map(String.init) {
            if piece == "." || piece.isEmpty { continue }
            if piece == ".." { if parts.count > 1 { parts.removeLast() }; continue }
            parts.append(piece)
        }
        let path = "/" + parts.joined(separator: "/")
        return path.isEmpty ? "/ext" : path
    }

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

    static let bridgeBootstrapHelp = """
        flipper-bridge bootstraps the computer the Flipper is plugged into.

        The phone cannot install it over Bluetooth alone — a bare machine has
        nothing listening on the USB yet. The Flipper does it from its own USB
        serial CLI:

        1. Plug the Flipper into the computer with the cable.
        2. Open the Flipper CLI with:  screen /dev/cu.usbmodemflip*
           (screen lets go of the port on its own the moment the next step
           runs. qFlipper works too, but hit RELEASE PORT right after typing
           the command -- otherwise it keeps the serial line the bridge needs.)
        3. Type:  nikita install flipper-bridge

        The Flipper becomes a keyboard, opens Terminal, types the bridge in and
        starts it in --mailbox mode. It waits for the serial port to come back,
        so a brief busy moment is fine. After that, ls / fls and everything
        else here work.
        """

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
        // Clear any leftover answer before asking, so a stale response from a
        // previous command can never be mistaken for this one's.
        try? await device.deleteFile(at: Self.mailboxRes, recursive: false)
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
        "whoami", "open", "close", "cd", "pwd", "sed", "diff", "file"
    ]

    // Spellings of the same verb, within one machine.
    private static func normalise(_ verb: String) -> String {
        let synonyms = [
            "dir": "ls", "ll": "ls", "la": "ls", "read": "cat", "type": "cat",
            "del": "rm", "erase": "rm", "rename": "mv", "move": "mv", "ren": "mv",
            "hash": "md5", "md5sum": "md5", "md": "mkdir", "chdir": "cd",
            "lcd": "cd", "lpwd": "pwd", "diskfree": "df", "press": "btn",
            "beep": "alert", "power_info": "power", "property": "props",
            "copy": "cp", "pull": "cp", "push": "cp", "curl": "wget",
            "fetch": "wget", "nano": "edit", "vi": "edit", "vim": "edit",
            "emacs": "edit", "pico": "edit", "micro": "edit", "python": "python3"
        ]
        return synonyms[verb] ?? verb
    }

    // The Flipper's own firmware vocabulary: bare, passed straight through to
    // the device exactly as typed (subghz, nfc, storage, device_info, ...).
    private static let firmwareVerbs: Set<String> = [
        "device_info", "info", "gpio", "subghz", "nfc", "rfid", "ir", "led",
        "loader", "storage", "power", "top", "log", "js", "bt", "crypto",
        "date", "free", "free_blocks", "i2c", "onewire", "sysctl", "uptime",
        "input", "neofetch", "vibro", "nikita", "ikey", "factory_reset",
        "update", "reload_ext_cmds", "start_rpc_session", "sleep",
        "props", "screen", "btn", "alert", "unlock", "reboot"
    ]

    // Flipper-only verbs -- they only make sense on the device.
    private static let flipperOnly: Set<String> = [
        "fclose", "fopen", "freboot", "fshutdown", "fvibro", "fname", "flocate"
    ]

    private static func flipperCanon(_ raw: String) -> String {
        [
            "fclose": "close", "fopen": "open", "freboot": "reboot",
            "fshutdown": "shutdown", "fvibro": "vibro", "fname": "name",
            "flocate": "locate"
        ][raw] ?? String(raw.dropFirst())
    }

    private func route(_ line: String) async -> [Line] {
        let parts = line.split(whereSeparator: { $0 == " " }).map(String.init)
        guard let raw = parts.first else { return [] }
        let verb = Self.normalise(raw)
        var args = Array(parts.dropFirst())

        // Panel-only + the escape hatch, before anything touches a wire.
        if raw == "help" || raw == "?" {
            return [.init(text: bleHelp, kind: .output)]
        }
        if raw == "history" {
            if args.first == "-c" { history.removeAll(); return ok("history cleared") }
            let listing = history.enumerated()
                .map { "\($0.offset + 1)  \($0.element)" }
                .joined(separator: "\n")
            return [.init(text: listing.isEmpty ? "(empty)" : listing, kind: .output)]
        }
        if raw == "host" || raw == "local" || raw == "run" {
            let rest = line.drop(while: { $0 != " " })
                .trimmingCharacters(in: .whitespaces)
            return await runMachineLine(rest.isEmpty ? "pwd" : rest)
        }

        // "nikita install ..." must NOT travel the mailbox: the mailbox is the
        // bridge it is installing, so routing it there just times out with a
        // misleading "no answer". Intercept it and tell the truth.
        if raw == "nikita", args.first == "install" {
            let target = args.count > 1 ? args[1] : ""
            if target == "flipper-bridge" || target.isEmpty {
                return [.init(text: Self.bridgeBootstrapHelp, kind: .output)]
            }
            return [.init(text: "nikita install: unknown target \(target). "
                + "Did you mean flipper-bridge?", kind: .error)]
        }

        // ---- smart transfers, the REPL and the editor (bridge-backed) ----
        if verb == "cp" { return await runTransfer(args) }
        if verb == "wget" { return await runWget(args, toFlipper: false) }
        if raw == "fwget" { return await runWget(args, toFlipper: true) }
        if verb == "python3", args.isEmpty {
            pythonMode = true
            pythonMore = false
            return [.init(text: "[ python3 -- runs on the computer, not the "
                + "Flipper. exit() or quit() to leave. ]", kind: .system)]
        }
        if verb == "edit" { return await openEditor(args) }

        // ---- the one rule: bare = this computer, f<verb> = the Flipper ----
        //
        // f + a dual verb (fls, fcat, ...) or an f-only verb (fopen, fclose,
        // freboot, fvibro, fname, flocate, fshutdown) means the Flipper. A bare
        // firmware word (subghz, nfc, storage, device_info, ...) is the
        // Flipper's own vocabulary and passes straight through to it.
        // EVERYTHING else -- every real Unix program -- runs on THIS computer.
        let fStripped = raw.hasPrefix("f") && raw.count > 1
            ? Self.normalise(String(raw.dropFirst())) : ""
        let isFlipper = (!fStripped.isEmpty && Self.dualVerbs.contains(fStripped))
            || Self.flipperOnly.contains(raw)
        let isFirmware = Self.firmwareVerbs.contains(verb)

        if !isFlipper && !isFirmware {
            return await runMachineLine(line)
        }

        let cmd = isFlipper
            ? (Self.flipperOnly.contains(raw) ? Self.flipperCanon(raw) : fStripped)
            : verb

        // fcd / fpwd navigate the Flipper the way cd / pwd navigate the machine.
        // The Flipper has no shell, so the path math is done here.
        if cmd == "cd" {
            let target = args.first ?? "/ext"
            let dest = Self.resolveFlipper(flipperCwd, target)
            if (try? await device.listFiles(at: dest)) != nil {
                flipperCwd = dest
                return []
            }
            return [.init(text: "fcd: no such directory: \(dest)", kind: .error)]
        }
        if cmd == "pwd" {
            return [.init(text: flipperCwd, kind: .output)]
        }
        // A bare fls lists where you are; a relative path resolves against it.
        // Resolve a relative path against the Flipper cwd -- but only for the
        // verbs whose first argument IS a path. For grep/echo/btn/open and the
        // firmware words the first argument is a pattern or a value, not a path.
        let flipperPathVerbs: Set<String> = [
            "ls", "tree", "cat", "stat", "md5", "rm", "mkdir", "touch",
            "du", "df", "mv"
        ]
        if args.isEmpty, cmd == "ls" || cmd == "tree" {
            args = [flipperCwd]
        } else if flipperPathVerbs.contains(cmd), let first = args.first,
                  !first.hasPrefix("/") {
            args[0] = Self.resolveFlipper(flipperCwd, first)
        }

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
                return ok("buzzed")

            case "locate":
                return try await findCmd(
                    "/ext", needle: (args.first ?? "").lowercased())

            case "shutdown":
                let out = await runFlipperRaw("power off")
                return ok(out.isEmpty ? "powering off" : out)

            case "name":
                return [.init(text: "fname: rename in qFlipper > Settings "
                    + "(not wired to mobile yet).", kind: .error)]

            case "file":
                guard let p0 = args.first else { return usage("ffile <path>") }
                let path = p0.hasPrefix("/") ? p0
                    : Self.resolveFlipper(flipperCwd, p0)
                let body = try await device.readFile(at: path)
                let what = body.isEmpty ? "empty"
                    : (body.unicodeScalars.contains { $0.value == 0 }
                        ? "data (binary)"
                        : "ASCII text, \(body.split(separator: "\n").count) lines")
                return ok("\(path): \(what)")

            case "sed":
                guard args.count >= 2, args[0].hasPrefix("s/") else {
                    return usage("fsed s/old/new/[g] <path>")
                }
                let parts = args[0].split(
                    separator: "/", omittingEmptySubsequences: false)
                guard parts.count >= 3 else {
                    return usage("fsed s/old/new/[g] <path>")
                }
                let old = String(parts[1]), new = String(parts[2])
                let global = parts.count > 3 && parts[3].contains("g")
                let p1 = args[args.count - 1]
                let path = p1.hasPrefix("/") ? p1
                    : Self.resolveFlipper(flipperCwd, p1)
                let body = try await device.readFile(at: path)
                let result: String
                if global {
                    result = body.replacingOccurrences(of: old, with: new)
                } else if let r = body.range(of: old) {
                    result = body.replacingCharacters(in: r, with: new)
                } else {
                    result = body
                }
                try await device.writeFile(at: path, content: result)
                return ok("fsed: updated \(path)")

            case "diff":
                guard args.count >= 2 else { return usage("fdiff <a> <b>") }
                func resolve(_ x: String) -> String {
                    x.hasPrefix("/") ? x : Self.resolveFlipper(flipperCwd, x)
                }
                let a = try await device.readFile(at: resolve(args[0]))
                    .split(separator: "\n", omittingEmptySubsequences: false)
                let b = try await device.readFile(at: resolve(args[1]))
                    .split(separator: "\n", omittingEmptySubsequences: false)
                var diff: [String] = []
                for i in 0..<max(a.count, b.count) {
                    let la = i < a.count ? String(a[i]) : ""
                    let lb = i < b.count ? String(b[i]) : ""
                    if la != lb {
                        if !la.isEmpty { diff.append("- \(la)") }
                        if !lb.isEmpty { diff.append("+ \(lb)") }
                    }
                }
                return [.init(
                    text: diff.isEmpty ? "(identical)" : diff.joined(separator: "\n"),
                    kind: .output)]

            default:
                // Not one of the mapped verbs: it is a raw firmware command --
                // subghz, nfc, gpio, ir, led, power, js, loader and the rest.
                // Straight to the Flipper's own shell through the bridge (no
                // "host" -- that would run it on the computer), so the single
                // prompt reaches the whole device with nothing to switch.
                let out = await runFlipperRaw(line)
                return [.init(text: out.isEmpty ? "(no output)" : out,
                              kind: .output)]
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

    // Two aligned columns per section, the way nikita-qflipper lays it out.
    private static func columns(_ items: [String], width: Int = 18) -> String {
        let names = items.sorted()
        var rows: [String] = []
        var i = 0
        while i < names.count {
            let left = names[i]
            if i + 1 < names.count {
                let padded = left.padding(
                    toLength: width, withPad: " ", startingAt: 0)
                rows.append("  " + padded + names[i + 1])
            } else {
                rows.append("  " + left)
            }
            i += 2
        }
        return rows.joined(separator: "\n")
    }

    private var bleHelp: String {
        let flipper = [
            "fls", "fcat", "ftree", "fstat", "fmd5", "fmkdir", "frm", "fmv",
            "ftouch", "fecho", "fgrep", "fsed", "fhead", "ftail", "fwc",
            "ffind", "ffile", "fdiff", "fdu", "fdf", "fcd", "fpwd", "fwhoami",
            "fopen", "fclose", "freboot", "fshutdown", "fvibro", "flocate",
        ]
        let computer = [
            "ls", "cat", "tree", "stat", "md5", "mkdir", "rm", "mv", "cp",
            "touch", "echo", "grep", "sed", "head", "tail", "wc", "find",
            "file", "diff", "du", "df", "cd", "pwd", "ps", "kill", "whoami",
            "hostname", "uname", "id", "env", "which", "date", "ping",
            "ifconfig", "netstat", "dig", "nslookup", "traceroute", "ssh",
            "git", "python3", "docker", "nmap", "tar", "zip", "unzip", "gzip",
            "openssl", "base64", "sha256sum", "hexdump", "xxd", "awk", "chmod",
            "man", "host",
        ]
        let firmware = [
            "device_info", "info", "storage", "gpio", "subghz", "nfc", "rfid",
            "ir", "led", "power", "loader", "js", "bt", "top", "log", "free",
            "uptime", "vibro", "nikita", "onewire", "i2c", "input", "crypto",
            "sysctl", "neofetch",
        ]
        return """
        One prompt, two machines. The NAME picks which: a bare name is THIS
        COMPUTER (the real Unix program); an f-prefixed name is the FLIPPER.

        ------ Flipper (f + verb) ------
        \(Self.columns(flipper))

        ------ Computer (bare) ------
        \(Self.columns(computer))

        ------ Firmware (bare -> the Flipper) ------
        \(Self.columns(firmware))

        The computer side needs nikita-flipper-bridge running there over USB:
          python3 bridge.py --mailbox --allow-host
        host <cmd> forces the computer.  history, !!, !n.  clear.
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
        terminal
        .background(Color.background)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackground(Color.background)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            LeadingToolbarItems { BackButton { dismiss() } }
            PrincipalToolbarItems(alignment: .leading) { Title("CLI") }
        }
        .sheet(isPresented: $cli.editorOpen) { editorSheet }
    }

    // The built-in editor -- edit/nano/vi on either machine open here.
    private var editorSheet: some View {
        NavigationView {
            VStack(spacing: 0) {
                TextEditor(text: $cli.editorText)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if let msg = cli.editorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.a1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(cli.editorPath)
                        .font(.system(.caption, design: .monospaced))
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cli.editorOpen = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if cli.editorSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await cli.saveEditor() } }
                    }
                }
            }
        }
    }



    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(cli.lines) { line in row(line).id(line.id) }
                    VStack(alignment: .leading, spacing: 2) {
                        suggestionBar
                        inputLine
                    }.id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            // Tapping anywhere in the terminal puts the cursor back on the
            // command line, the way a terminal behaves.
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .onChange(of: cli.lines.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { focused = true }
        }
    }

    // The prompt and the cursor as the terminal's last line -- no bar, no
    // border, no button. Enter (the keyboard's return) runs it. While a command
    // is in flight the line shows a small spinner in place of the cursor.
    private var inputLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(prompt).foregroundColor(.a2)
            if cli.running {
                Text(input).foregroundColor(.primary)
                ProgressView().scaleEffect(0.6).padding(.leading, 6)
            } else {
                TextField("", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit(send)
                    .submitLabel(.go)
                    .tint(.a2)
            }
            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Tab-style completion for a phone with no Tab key: the command names that
    // start with what you have typed so far, tap to fill in.
    private var suggestions: [String] {
        guard !cli.pythonMode, !cli.running else { return [] }
        let typed = input
        guard !typed.isEmpty, !typed.contains(" ") else { return [] }
        return Array(FlipperCLI.allCommands
            .filter { $0.hasPrefix(typed) && $0 != typed }
            .prefix(8))
    }

    @ViewBuilder private var suggestionBar: some View {
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(suggestions, id: \.self) { name in
                        Text(name)
                            .font(.system(.caption2, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.a2.opacity(0.15))
                            .cornerRadius(6)
                            .onTapGesture {
                                input = name + " "
                                focused = true
                            }
                    }
                }
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

    // The same prompt nikita-qflipper shows: the device name, where you are on
    // the computer, and -- only when you have moved off the card's root -- where
    // you are on the Flipper. "~" for home and for /ext, the way a shell does.
    private var prompt: String {
        if cli.pythonMode { return cli.pythonMore ? "... " : ">>> " }
        let host = Self.tildeHome(cli.machineCwd)
        let flip = cli.flipperCwd == "/ext"
            ? ""
            : "[f:" + Self.tildeExt(cli.flipperCwd) + "]"
        return "\(cli.devName)@flipper \(host)\(flip) % "
    }

    private static func tildeHome(_ path: String) -> String {
        if path == "~" || path.hasPrefix("~") { return path }
        // The machine reports absolute home paths; fold the obvious ones to ~.
        for marker in ["/Users/", "/home/"] {
            if let r = path.range(of: marker) {
                let after = path[r.upperBound...]
                if let slash = after.firstIndex(of: "/") {
                    return "~" + after[slash...]
                }
                return "~"
            }
        }
        return path
    }

    private static func tildeExt(_ path: String) -> String {
        if path == "/ext" { return "~" }
        if path.hasPrefix("/ext/") { return "~" + path.dropFirst(4) }
        return path
    }


    private func send() {
        let cmd = input
        input = ""
        cli.submit(cmd)
        focused = true
    }
}
