import Foundation

// The tool schemas the model is offered, in OpenAI function-calling shape. This
// is the desktop Nikita's BLE toolbox: storage over RPC, the framebuffer, the
// full D-pad (no CLI to navigate deterministically, so up/down/left/right earn
// their place) and App RPC open/close -- plus the three memory tools, which
// always travel. There is no run_cli and no computer_* here: an iPhone has no
// serial CLI to the Flipper and no shell of its own.
enum NikitaTools {

    static func function(
        _ name: String,
        _ description: String,
        properties: [String: Any] = [:],
        required: [String] = []
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required
                ]
            ]
        ]
    }

    static func str(_ desc: String, enumValues: [String]? = nil) -> [String: Any] {
        var o: [String: Any] = ["type": "string", "description": desc]
        if let e = enumValues { o["enum"] = e }
        return o
    }

    static func int(_ desc: String) -> [String: Any] {
        ["type": "integer", "description": desc]
    }

    static func bool(_ desc: String) -> [String: Any] {
        ["type": "boolean", "description": desc]
    }

    // MARK: Memory (always offered)

    static var memoryTools: [[String: Any]] {
        [
            function(
                "remember",
                "Save something you have learned about the user. Call this "
                + "PROACTIVELY -- without being asked, in the same turn, without "
                + "announcing it -- whenever they reveal anything worth knowing next "
                + "week: who they are, their setup, what they are building and why, "
                + "preferences, a decision and its reason. Also when they say "
                + "'remember...'. This is NOT a log of what you did. Save ONE thing "
                + "per call, one short line, third person ('User ...'). Do not save "
                + "greetings, filler, or something you already remember.",
                properties: ["fact": str(
                    "One concise durable fact, third person, starting with 'User'.")],
                required: ["fact"]),
            function(
                "list_memory",
                "Show everything you currently remember about the user. Call it when "
                + "they ask what you remember/know about them."),
            function(
                "forget",
                "Delete remembered facts. Pass a word/phrase to remove matching "
                + "facts, or \"all\" to wipe memory.",
                properties: ["match": str(
                    "Text to match facts to delete, or 'all' to clear everything")],
                required: ["match"])
        ]
    }

    // MARK: Device (offered on action turns)

    static var deviceTools: [[String: Any]] {
        [
            function(
                "list_files",
                "List files and folders ON THE CONNECTED FLIPPER ZERO at a path. Use "
                + "/ext for the SD card root, /ext/apps for installed apps, /int for "
                + "internal. Returns each entry's name, type (dir/file) and size.",
                properties: ["path": str(
                    "Absolute path on the Flipper, e.g. /ext or /ext/apps")],
                required: ["path"]),
            function(
                "read_file",
                "Read the text contents of a file ON THE CONNECTED FLIPPER ZERO.",
                properties: ["path": str(
                    "Absolute path to a file, e.g. /ext/apps_data/x/config.txt")],
                required: ["path"]),
            function(
                "save_file",
                "Save/write text to a file ON THE CONNECTED FLIPPER ZERO's SD card. "
                + "Use the right folder: BadUSB -> /ext/badusb/*.txt, Sub-GHz -> "
                + "/ext/subghz/*.sub, Infrared -> /ext/infrared/*.ir, NFC -> "
                + "/ext/nfc/*.nfc, otherwise /ext/. The folder must already exist.",
                properties: [
                    "path": str("Absolute path including filename"),
                    "content": str("The full text content to write")
                ],
                required: ["path", "content"]),
            function(
                "make_dir",
                "Create a folder (and any missing parents) ON THE CONNECTED FLIPPER "
                + "ZERO's SD card, e.g. /ext/apps/Scripts.",
                properties: ["path": str("Absolute folder path on the Flipper")],
                required: ["path"]),
            function(
                "delete_file",
                "Delete a file or folder ON THE CONNECTED FLIPPER ZERO's SD card. "
                + "Destructive -- only when the user clearly asked to delete.",
                properties: [
                    "path": str("Absolute path to delete"),
                    "recursive": bool("Delete a non-empty folder and its contents")
                ],
                required: ["path"]),
            function(
                "rename_file",
                "Rename or MOVE a file/folder ON THE CONNECTED FLIPPER ZERO's SD card "
                + "(same operation does both).",
                properties: [
                    "from": str("Current absolute path"),
                    "to": str("New absolute path (rename) or new location (move)")
                ],
                required: ["from", "to"]),
            function(
                "file_info",
                "Check whether a path exists ON THE CONNECTED FLIPPER ZERO and whether "
                + "it is a file or directory, plus its size in bytes.",
                properties: ["path": str("Absolute path on the Flipper to stat")],
                required: ["path"]),
            function(
                "read_screen",
                "See what is on the Flipper's screen RIGHT NOW, rendered as text/ASCII "
                + "straight from the framebuffer. Use it to VERIFY where you are "
                + "before and after pressing buttons -- you are NOT blind when you "
                + "call this."),
            function(
                "press_button",
                "Press a button on the Flipper over Bluetooth. This is the way to "
                + "drive the device on a wireless link -- there is no CLI here. "
                + "up/down/left/right move the selection, ok enters/confirms, back "
                + "leaves. Do not press blind: read_screen first, move once, then "
                + "look again. A count is never evidence of position.",
                properties: [
                    "button": str(
                        "Which button to tap",
                        enumValues: ["up", "down", "left", "right", "ok", "back"]),
                    "times": int("How many times to tap it (default 1)")
                ],
                required: ["button"]),
            function(
                "run_app",
                "Open or close a Flipper app over Bluetooth, deterministically. "
                + "action \"open\" launches an app by its EXACT name; action \"close\" "
                + "returns to the desktop. Built-in names: Sub-GHz, 125 kHz RFID, NFC, "
                + "Infrared, GPIO, iButton, Bad USB, U2F. For an INSTALLED app (a .fap "
                + "under /ext/apps/<Category>/) pass its FULL .fap PATH as the name. "
                + "Do NOT guess a name from a vague word -- if unsure, ask, or treat "
                + "it as a folder and use list_files. When it succeeds the app IS "
                + "open; do not then read_screen just to check.",
                properties: [
                    "action": str(
                        "open to launch an app, close to return to desktop",
                        enumValues: ["open", "close"]),
                    "name": str("For open: the app's exact name, e.g. NFC or Infrared")
                ],
                required: ["action"])
        ]
    }

    // MARK: Bridge tools -- the Flipper's own shell, and the computer holding it
    //
    // These reach past Bluetooth. The phone has no serial line to the Flipper
    // and no shell of its own, so both go through nikita-flipper-bridge on the
    // computer that holds the Flipper on USB. That is the same split the
    // desktop assistant has, arrived at from the other side.

    static var bridgeTools: [[String: Any]] {
        [
            function(
                "run_cli",
                "Run a command in the Flipper's own text shell, through the "
                + "bridge on the computer. This is how you reach anything "
                + "Bluetooth cannot carry: subghz, nfc, gpio, ir, led, vibro, "
                + "js, i2c. Use the Flipper's real syntax, e.g. "
                + "'storage list /ext', 'subghz rx', 'gpio mode PA7 1'.",
                properties: ["command": str("The command, exactly as the "
                    + "Flipper's shell expects it.")],
                required: ["command"]),
            function(
                "computer_list",
                "List a folder on the computer the Flipper is plugged into. "
                + "Use it to see what is on that machine -- the phone has no "
                + "other way to look.",
                properties: ["path": str("Absolute path, or ~ for home.")],
                required: ["path"]),
            function(
                "computer_read",
                "Read a text file on the bridged computer.",
                properties: ["path": str("Absolute path of the file.")],
                required: ["path"]),
            function(
                "computer_find",
                "Search the bridged computer for files matching a pattern.",
                properties: [
                    "path": str("Folder to search in."),
                    "pattern": str("Name pattern, e.g. '*.txt'.")
                ],
                required: ["path", "pattern"]),
            function(
                "computer_write",
                "Write a text file on the bridged computer, replacing it if it "
                + "is already there.",
                properties: [
                    "path": str("Absolute path of the file."),
                    "content": str("The full contents to write.")
                ],
                required: ["path", "content"]),
            function(
                "computer_mkdir",
                "Create a folder on the bridged computer.",
                properties: ["path": str("Absolute path of the folder.")],
                required: ["path"]),
            function(
                "computer_delete",
                "Delete a file or folder on the bridged computer.",
                properties: [
                    "path": str("Absolute path to delete."),
                    "recursive": bool("True to delete a folder and everything "
                        + "in it.")
                ],
                required: ["path"]),
            function(
                "computer_run",
                "Run a terminal command on the bridged computer and return its "
                + "output. The widest access there is -- prefer a narrower "
                + "tool when one fits.",
                properties: ["command": str("The shell command to run.")],
                required: ["command"])
        ]
    }

    // Which tool family gates a given tool name (for the access filters).
    //
    // Reading, changing and deleting are separate families, on the Flipper and
    // on the computer alike: they are separate risks and deserve separate
    // answers. A tool with no family here would be ungated, so the default
    // lands on the narrowest one rather than the widest.
    static func family(of tool: String) -> String {
        switch tool {
        case "remember", "list_memory", "forget": return "memory"
        case "read_screen": return "screen"
        case "press_button": return "buttons"
        case "run_app": return "apps"
        case "save_file", "make_dir", "rename_file", "write_file":
            return "files_write"
        case "delete_file": return "files_delete"
        case "run_cli": return "serial"
        case "computer_list", "computer_read", "computer_find":
            return "computer_read"
        case "computer_write", "computer_mkdir": return "computer_write"
        case "computer_delete": return "computer_delete"
        case "computer_run": return "computer_run"
        default: return "files"
        }
    }

    // The full offered set for a turn, minus families the user switched off.
    static func offered(
        needsDevice: Bool,
        hasBridge: Bool = false,
        isAllowed: (String) -> Bool
    ) -> [[String: Any]] {
        var all = memoryTools
        if needsDevice { all += deviceTools }
        // Only when a bridge is actually connected. Offering these to the
        // model with nothing behind them invites it to promise work it cannot
        // do and then report a connection error as a result.
        if hasBridge { all += bridgeTools }
        return all.filter { t in
            guard
                let fn = t["function"] as? [String: Any],
                let name = fn["name"] as? String
            else { return false }
            return isAllowed(family(of: name))
        }
    }
}
