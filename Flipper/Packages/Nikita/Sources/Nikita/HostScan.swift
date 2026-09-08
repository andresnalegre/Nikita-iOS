import Foundation

// The result of `nikita host` -- the passive USB fingerprint the firmware
// collected from how the plugged-in machine enumerated the Flipper. A device
// can't read its host, but each OS asks for descriptors differently, so this is
// a best-effort family guess plus the raw signals it was derived from.
//
// Shared between the agent's scan_viewer tool and the Scan Viewer screen: both
// run `nikita host` (over the bridge) and parse its key=value lines with
// HostScan.parse, so they always agree on what the fingerprint means.
public struct HostScan: Sendable, Equatable {
    public enum OS: String, Sendable {
        case windows, macos, linux, unknown
    }

    public var os: OS
    public var msOsStringRequested: Bool
    public var serialRequested: Bool
    public var productRequested: Bool
    public var manufRequested: Bool
    public var deviceDescRequests: Int
    public var configDescRequests: Int
    public var stringRequests: Int
    public var firstDeviceDescWLength: Int

    public init(
        os: OS = .unknown,
        msOsStringRequested: Bool = false,
        serialRequested: Bool = false,
        productRequested: Bool = false,
        manufRequested: Bool = false,
        deviceDescRequests: Int = 0,
        configDescRequests: Int = 0,
        stringRequests: Int = 0,
        firstDeviceDescWLength: Int = 0
    ) {
        self.os = os
        self.msOsStringRequested = msOsStringRequested
        self.serialRequested = serialRequested
        self.productRequested = productRequested
        self.manufRequested = manufRequested
        self.deviceDescRequests = deviceDescRequests
        self.configDescRequests = configDescRequests
        self.stringRequests = stringRequests
        self.firstDeviceDescWLength = firstDeviceDescWLength
    }

    // True once the host has actually enumerated us -- otherwise the Viewer has
    // nothing to show yet (Flipper unplugged, or plugged into a dumb charger).
    public var hasScanned: Bool {
        deviceDescRequests > 0 || stringRequests > 0 || configDescRequests > 0
    }

    // A person-facing one-liner for the Viewer header / chat.
    public var summary: String {
        switch os {
        case .windows: return "Windows host"
        case .macos: return "macOS host"
        case .linux: return "Linux host"
        case .unknown:
            return hasScanned ? "Unknown host" : "No host detected"
        }
    }

    // Parse the `nikita host` output: one `key=value` per line. Unknown keys are
    // ignored so new firmware fields never break an older app.
    public static func parse(_ raw: String) -> HostScan {
        var kv: [String: String] = [:]
        for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "=") else { continue }
            let key = String(t[t.startIndex..<eq])
            let val = String(t[t.index(after: eq)...])
            if !key.isEmpty { kv[key] = val }
        }
        func flag(_ k: String) -> Bool { kv[k] == "1" }
        func num(_ k: String) -> Int { Int(kv[k] ?? "") ?? 0 }
        return HostScan(
            os: OS(rawValue: kv["os"] ?? "unknown") ?? .unknown,
            msOsStringRequested: flag("ms_os_string"),
            serialRequested: flag("serial_req"),
            productRequested: flag("product_req"),
            manufRequested: flag("manuf_req"),
            deviceDescRequests: num("device_desc_req"),
            configDescRequests: num("config_desc_req"),
            stringRequests: num("string_req"),
            firstDeviceDescWLength: num("first_dev_wlen"))
    }

    // Build from the Flipper's RPC device_info properties (read over BLE, no
    // bridge). The firmware emits usb.host.* keys; returns nil when they are
    // absent (older firmware) so the caller can say "update the firmware".
    public static func fromProperties(_ props: [String: String]) -> HostScan? {
        guard props.keys.contains(where: { $0.hasPrefix("usb.host.") }) else {
            return nil
        }
        func flag(_ k: String) -> Bool { props["usb.host." + k] == "1" }
        func num(_ k: String) -> Int { Int(props["usb.host." + k] ?? "") ?? 0 }
        return HostScan(
            os: OS(rawValue: props["usb.host.os"] ?? "unknown") ?? .unknown,
            msOsStringRequested: flag("msos"),
            serialRequested: flag("serial"),
            productRequested: flag("product"),
            manufRequested: flag("manuf"),
            deviceDescRequests: num("devdesc"),
            configDescRequests: num("cfgdesc"),
            stringRequests: num("strreq"),
            firstDeviceDescWLength: num("firstwlen"))
    }

    // The shape the scan_viewer tool hands back to the model.
    public var toolPayload: [String: Any] {
        [
            "os": os.rawValue,
            "summary": summary,
            "scanned": hasScanned,
            "signals": [
                "ms_os_string_requested": msOsStringRequested,
                "serial_requested": serialRequested,
                "product_requested": productRequested,
                "manuf_requested": manufRequested,
                "device_desc_requests": deviceDescRequests,
                "config_desc_requests": configDescRequests,
                "string_requests": stringRequests,
                "first_device_desc_wlength": firstDeviceDescWLength
            ]
        ]
    }
}
