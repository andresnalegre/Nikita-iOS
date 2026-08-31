import Core
import Nikita
import Peripheral

import Foundation

// The concrete NikitaDeviceBridge, wiring the assistant's tools to the live
// Flipper RPC session via Core.Dependencies. Everything here is BLE-shaped:
// storage over RPC, the framebuffer as ASCII, the GUI buttons, and App RPC
// open/close. There is deliberately no CLI and no host access -- an iPhone has
// neither to offer.
struct LiveDeviceBridge: NikitaDeviceBridge {
    private var deps: Core.Dependencies { .shared }

    private var storage: StorageAPI { deps.nikitaStorage }
    private var application: ApplicationAPI { deps.nikitaApplication }
    private var gui: GUIAPI { deps.nikitaGUI }

    var isConnected: Bool {
        get async {
            await MainActor.run {
                switch deps.device.status {
                case .connected, .synchronizing, .synchronized:
                    return true
                default:
                    return false
                }
            }
        }
    }

    // MARK: Files

    func listFiles(at path: String) async throws -> [NikitaFileEntry] {
        let elements = try await storage.list(
            at: .init(string: path), calculatingMD5: false, sizeLimit: 0)
        return elements.map { element in
            switch element {
            case .file(let file):
                return .init(name: file.name, type: "file", size: file.size)
            case .directory(let dir):
                return .init(name: dir.name, type: "dir", size: 0)
            }
        }
    }

    func readFile(at path: String) async throws -> String {
        var bytes: [UInt8] = []
        for try await chunk in await storage.read(at: .init(string: path)) {
            bytes.append(contentsOf: chunk)
            // The desktop caps a read at ~8 KB of text; do the same so a huge
            // binary can't blow the context window.
            if bytes.count > 8 * 1024 { break }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func writeFile(at path: String, content: String) async throws {
        let stream = await storage.write(
            at: .init(string: path), bytes: .init(content.utf8))
        for try await _ in stream {} // drain to completion
    }

    func makeDir(at path: String) async throws {
        // Create parents one level at a time; an existing folder is not an error.
        let parts = path.split(separator: "/").map(String.init)
        var current = ""
        for part in parts {
            current += "/" + part
            do {
                try await storage.create(
                    at: .init(string: current), isDirectory: true)
            } catch let error as Peripheral.Error
                        where error == .storage(.exists) {
                continue
            }
        }
    }

    func deleteFile(at path: String, recursive: Bool) async throws {
        try await storage.delete(at: .init(string: path), force: recursive)
    }

    func renameFile(from: String, to: String) async throws {
        try await storage.move(at: .init(string: from), to: .init(string: to))
    }

    func fileInfo(at path: String) async throws -> NikitaFileInfo {
        do {
            let size = try await storage.size(of: .init(string: path))
            return .init(exists: true, type: "file", size: size)
        } catch let error as Peripheral.Error
                    where error == .storage(.doesNotExist) {
            return .init(exists: false, type: "missing", size: 0)
        } catch {
            // A path that stats-fails as "not a file" is very likely a directory:
            // list it to confirm rather than reporting it missing.
            if let _ = try? await storage.list(
                at: .init(string: path), calculatingMD5: false, sizeLimit: 0) {
                return .init(exists: true, type: "dir", size: 0)
            }
            throw error
        }
    }

    // MARK: Screen

    func readScreen() async throws -> String {
        try await gui.startStreaming()
        // Take the first frame the device pushes after streaming is on, but
        // never block the whole turn on it: race the stream against a timeout so
        // a quiet stream fails fast with a clear message instead of hanging.
        let stream = await gui.screenFrame
        let frame = try await withThrowingTaskGroup(of: ScreenFrame?.self) {
            group -> ScreenFrame? in
            group.addTask {
                for await frame in stream { return frame }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 4 * 1_000_000_000)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let frame else {
            throw NikitaDeviceError.failed(
                "No screen frame received (is the device awake?).")
        }
        return Self.asciiArt(of: frame)
    }

    // The 128x64 monochrome framebuffer as ASCII, downsampled 2x to 64x32 so it
    // fits a tool result without dominating the context window. Not OCR -- the
    // model reads the shapes, same as the desktop's read_screen.
    static func asciiArt(of frame: ScreenFrame) -> String {
        let pixels = frame.pixels
        let width = 128, height = 64
        var lines: [String] = []
        var row = 0
        while row < height {
            var line = ""
            var col = 0
            while col < width {
                let a = pixels[row * width + col]
                let b = col + 1 < width ? pixels[row * width + col + 1] : false
                let c = row + 1 < height ? pixels[(row + 1) * width + col] : false
                let d = (col + 1 < width && row + 1 < height)
                    ? pixels[(row + 1) * width + col + 1] : false
                let on = (a ? 1 : 0) + (b ? 1 : 0) + (c ? 1 : 0) + (d ? 1 : 0)
                line += on >= 3 ? "#" : (on >= 1 ? "." : " ")
                col += 2
            }
            lines.append(line)
            row += 2
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Buttons

    func pressButton(_ button: String, times: Int) async throws {
        let key: InputKey
        switch button.lowercased() {
        case "up": key = .up
        case "down": key = .down
        case "left": key = .left
        case "right": key = .right
        case "ok", "enter": key = .enter
        case "back": key = .back
        default:
            throw NikitaDeviceError.failed("Unknown button \(button).")
        }
        for _ in 0..<max(1, times) {
            try await gui.pressButton(key, isLong: false)
        }
    }

    // MARK: Apps

    func runApp(action: String, name: String?) async throws {
        switch action.lowercased() {
        case "open":
            guard let name, !name.isEmpty else {
                throw NikitaDeviceError.failed("run_app open needs an app name.")
            }
            try await application.start(name, args: "")
        case "close":
            try await application.exit()
        default:
            throw NikitaDeviceError.failed("run_app action must be open or close.")
        }
    }
}
