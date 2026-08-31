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

    // Which tool family gates a given tool name (for the access filters).
    static func family(of tool: String) -> String {
        switch tool {
        case "remember", "list_memory", "forget": return "memory"
        case "read_screen": return "screen"
        case "press_button": return "buttons"
        case "run_app": return "apps"
        default: return "files"
        }
    }

    // The full offered set for a turn, minus families the user switched off.
    static func offered(
        needsDevice: Bool,
        isAllowed: (String) -> Bool
    ) -> [[String: Any]] {
        var all = memoryTools
        if needsDevice { all += deviceTools }
        return all.filter { t in
            guard
                let fn = t["function"] as? [String: Any],
                let name = fn["name"] as? String
            else { return false }
            return isAllowed(family(of: name))
        }
    }
}
