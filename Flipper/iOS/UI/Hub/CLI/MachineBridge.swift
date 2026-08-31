import Foundation

// WebSocket client for the machine bridge (nikita-flipper-bridge running on a
// computer that holds the Flipper on USB). The bridge exposes the Flipper's
// REAL text CLI -- subghz, nfc, gpio, ir, led, vibro, everything -- which BLE
// cannot reach. One command in, the full output back as one text frame.
@MainActor
final class MachineBridge: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .disconnected
    private(set) var urlString: String =
        UserDefaults.standard.string(forKey: "nikita.bridge.url")
        ?? "ws://192.168.0.10:8765"

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)

    func setURL(_ value: String) {
        urlString = value
        UserDefaults.standard.set(value, forKey: "nikita.bridge.url")
    }

    var isConnected: Bool { state == .connected }

    func connect() {
        disconnect()
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("ws") == true
        else {
            state = .failed("bad url (use ws://host:port)")
            return
        }
        state = .connecting
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        // Probe the link with a ping so a wrong host fails fast instead of
        // hanging on the first command.
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.state = .failed(String(
                        error.localizedDescription.prefix(60)))
                } else {
                    self.state = .connected
                }
            }
        }
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if state != .failed("") { state = .disconnected }
    }

    // Send one command, receive the full output as a single text frame.
    func run(_ command: String) async throws -> String {
        guard let task, state == .connected else {
            throw BridgeError.notConnected
        }
        try await task.send(.string(command))
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            return String(decoding: data, as: UTF8.self)
        @unknown default:
            return ""
        }
    }

    enum BridgeError: LocalizedError {
        case notConnected
        var errorDescription: String? {
            "Not connected to the machine bridge. Run the bridge on your "
            + "computer and 'connect ws://<mac-ip>:8765'."
        }
    }
}
