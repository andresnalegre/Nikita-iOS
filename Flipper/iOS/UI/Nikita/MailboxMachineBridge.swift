import Foundation
import Nikita

// Nikita reaches the Flipper's firmware CLI and the bridged computer the SAME
// way the CLI screen does: through the SD-card mailbox over Bluetooth, not the
// WebSocket. That is the transport the user actually runs (bridge.py --mailbox),
// so wiring the assistant to it is what gives the AI the same reach the CLI has
// -- run_cli on the Flipper, and the whole computer through `host` -- with no
// WiFi and no address to type.
@MainActor
final class MailboxMachineBridge: NikitaMachineBridge {
    private let device = LiveDeviceBridge()
    private let req = "/ext/nikita/bridge/req"
    private let res = "/ext/nikita/bridge/res"

    // A short-lived probe result: checking the bridge is a full mailbox round
    // trip, so cache it briefly rather than paying it on every single turn.
    private var probe: (at: Date, ok: Bool)?

    var isBridgeConnected: Bool {
        get async {
            if let p = probe, Date().timeIntervalSince(p.at) < 20 { return p.ok }
            let ok = (try? await roundTrip("bridge", timeout: 3)) != nil
            probe = (Date(), ok)
            return ok
        }
    }

    func send(_ command: String) async throws -> String {
        guard let out = try await roundTrip(command, timeout: 30) else {
            throw NikitaDeviceError.failed(
                "No answer from the bridge. Start it on the computer holding the "
                + "Flipper:  python3 bridge.py --mailbox --allow-host")
        }
        return out.isEmpty ? "(no output)" : out
    }

    // Leave "<id>.<base64(command)>" on the card, wait for the answer carrying
    // the same id. Clears any stale answer first so a leftover can never be read
    // as this command's result. Returns nil on timeout (bridge not running).
    private func roundTrip(
        _ command: String, timeout: TimeInterval
    ) async throws -> String? {
        guard await device.isConnected else {
            throw NikitaDeviceError.failed("No Flipper connected over Bluetooth.")
        }
        let id = String(UInt32.random(in: 1...UInt32.max))
        try? await device.deleteFile(at: res, recursive: false)
        let encoded = Data(command.utf8).base64EncodedString()
        try await device.writeFile(at: req, content: id + "." + encoded)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let body = try? await device.readFile(at: res) else { continue }
            let parts = body.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ".", maxSplits: 1,
                       omittingEmptySubsequences: false)
            guard let head = parts.first, String(head) == id else { continue }
            try? await device.deleteFile(at: res, recursive: false)
            guard parts.count > 1 else { return "" }
            var b64 = String(parts[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while b64.count % 4 != 0 { b64 += "=" }
            guard let data = Data(base64Encoded: b64,
                                  options: .ignoreUnknownCharacters) else {
                return ""
            }
            return String(decoding: data, as: UTF8.self)
        }
        return nil
    }
}
