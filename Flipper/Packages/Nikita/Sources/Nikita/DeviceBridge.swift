import Foundation

// The device-facing surface Nikita needs. Implemented in the app target on top
// of the Flipper RPC session (see LiveDeviceBridge). Kept as a protocol here so
// the agent, its tools and its tests never depend on the BLE stack.
//
// Every method is the mobile, BLE-only shape of the desktop Nikita's toolbox:
// storage over RPC, the framebuffer as text, the D-pad, and App RPC open/close.
// There is deliberately no run_cli and no computer_* -- an iPhone has no serial
// CLND to the Flipper and no shell of its own.
public protocol NikitaDeviceBridge: Sendable {
    /// True when a Flipper is connected and its RPC session is live.
    var isConnected: Bool { get async }

    func listFiles(at path: String) async throws -> [NikitaFileEntry]
    func readFile(at path: String) async throws -> String
    func writeFile(at path: String, content: String) async throws
    func makeDir(at path: String) async throws
    func deleteFile(at path: String, recursive: Bool) async throws
    func renameFile(from: String, to: String) async throws
    func fileInfo(at path: String) async throws -> NikitaFileInfo

    /// The Flipper's current screen rendered as text/ASCII.
    func readScreen() async throws -> String
    /// Tap a button `times` times. Buttons: up/down/left/right/ok/back.
    func pressButton(_ button: String, times: Int) async throws
    /// Open (`action == "open"`) an app by name, or close it back to desktop.
    func runApp(action: String, name: String?) async throws
}

public struct NikitaFileEntry: Codable, Sendable, Equatable {
    public let name: String
    public let type: String   // "dir" or "file"
    public let size: Int
    public init(name: String, type: String, size: Int) {
        self.name = name
        self.type = type
        self.size = size
    }
}

public struct NikitaFileInfo: Codable, Sendable, Equatable {
    public let exists: Bool
    public let type: String   // "dir", "file" or "missing"
    public let size: Int
    public init(exists: Bool, type: String, size: Int) {
        self.exists = exists
        self.type = type
        self.size = size
    }
}

public enum NikitaDeviceError: LocalizedError {
    case notConnected
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "No Flipper connected. Connect over Bluetooth first."
        case .failed(let why):
            return why
        }
    }
}
