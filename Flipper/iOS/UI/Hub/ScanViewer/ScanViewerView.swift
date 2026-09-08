import Core
import Nikita

import SwiftUI

// SCAN VIEWER -- read the machine the Flipper is plugged into.
//
// A USB device can't interrogate its host, so this shows the firmware's PASSIVE
// fingerprint: it runs `nikita host` over the bridge and classifies how the host
// enumerated us (Windows uniquely fetches the MS OS string 0xEE, macOS pulls the
// serial/product strings, Linux's first device-descriptor length is 64). The
// verdict is what lets Nikita tailor a Bad USB payload before writing a line.
//
// Robust by construction: every state is explicit (idle / scanning / no bridge /
// error / result), the scan is cancellable, and it never blocks the UI.
struct ScanViewerView: View {
    // When presented as a cover (hold-left from the remote) it owns its own
    // Back; pushed from the Tools card it uses the navigation stack's Back.
    var showsClose: Bool = false

    @StateObject private var model = ScanViewerModel()
    @StateObject private var ble = BLEEnvironmentScanner()
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable { case host = "Host (USB)"
                                      case nearby = "Nearby (BLE)" }
    @State private var mode: Mode = .host

    var body: some View {
        ZStack {
            Color.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.a2.opacity(0.4))
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                ScrollView {
                    if mode == .host {
                        hostContent
                    } else {
                        nearbyContent
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(showsClose)
        .toolbar {
            LeadingToolbarItems {
                HStack(spacing: 8) {
                    if showsClose {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.primary)
                        }
                    }
                    Title("Scan Viewer").padding(.leading, showsClose ? 0 : 8)
                }
            }
        }
        .onAppear {
            model.scanIfIdle()
            if mode == .nearby { ble.start() }
        }
        .onDisappear { ble.stop() }
        .onChange(of: mode) { newMode in
            if newMode == .nearby { ble.start() } else { ble.stop() }
        }
    }

    // MARK: Host (USB) tab

    private var hostContent: some View {
        VStack(spacing: 16) {
            verdictPanel
            if case let .result(scan, raw) = model.state {
                signalsPanel(scan)
                rawPanel(raw)
            } else if case let .error(message) = model.state {
                noticePanel(
                    icon: "exclamationmark.triangle.fill",
                    title: "Scan failed", message: message)
            } else if case .notConnected = model.state {
                noticePanel(
                    icon: "wave.3.right.circle",
                    title: "No Flipper",
                    message: "Connect a Flipper over Bluetooth. The Viewer reads "
                        + "the host it is plugged into straight off the device.")
            } else if case .oldFirmware = model.state {
                noticePanel(
                    icon: "arrow.down.circle",
                    title: "Update the firmware",
                    message: "This Flipper's firmware doesn't publish the USB host "
                        + "fingerprint yet. Update to the latest Nikita firmware "
                        + "and reconnect.")
            }
            rescanButton
        }
        .padding(16)
    }

    // MARK: Nearby (BLE) tab

    private var nearbyContent: some View {
        VStack(spacing: 10) {
            switch ble.state {
            case .poweredOff:
                noticePanel(icon: "wifi.slash", title: "Bluetooth is off",
                            message: "Turn Bluetooth on to scan for nearby "
                                + "TVs, consoles and devices.")
            case .unauthorized:
                noticePanel(icon: "lock.fill", title: "No Bluetooth access",
                            message: "Allow Bluetooth for the app in Settings.")
            case .unsupported:
                noticePanel(icon: "xmark.octagon", title: "Unsupported",
                            message: "This device can't scan BLE.")
            case .idle, .scanning:
                if ble.devices.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Listening for BLE advertisers…")
                            .font(.system(size: 13, weight: .medium,
                                          design: .monospaced))
                            .foregroundColor(.black30)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(ble.devices) { dev in
                        bleRow(dev)
                    }
                }
            }
        }
        .padding(16)
    }

    private func bleRow(_ dev: BLEEnvironmentScanner.Device) -> some View {
        HStack(spacing: 12) {
            Image(systemName: dev.category.icon)
                .font(.system(size: 20))
                .foregroundColor(dev.category == .unknown ? .black40 : .a1)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(dev.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(dev.category.rawValue
                     + (dev.serviceUUIDs.isEmpty ? ""
                        : " · " + dev.serviceUUIDs.prefix(3).joined(separator: " ")))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.black30)
                    .lineLimit(1)
            }
            Spacer()
            signalBars(dev.rssi)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.groupedBackground)
        .cornerRadius(10)
    }

    private func signalBars(_ rssi: Int) -> some View {
        // -50 or better = full, -100 or worse = empty.
        let level = max(0, min(4, (rssi + 100) / 12))
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < level ? Color.a1 : Color.black40.opacity(0.3))
                    .frame(width: 3, height: 5 + CGFloat(i) * 3)
            }
        }
    }

    // MARK: Header -- the dynamic context line, like the browser's folder name.

    private var header: some View {
        HStack(spacing: 10) {
            // Title chip -- echoes the file browser's "Browser" box, but reads
            // VIEWER and tracks the context (the scanned OS) dynamically.
            Text(model.contextTitle)
                .font(.system(size: 15, weight: .heavy, design: .monospaced))
                .foregroundColor(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.groupedBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.a1, lineWidth: 2))
                .cornerRadius(8)
            Spacer()
            statusDot
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusDot: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.statusColor)
                .frame(width: 8, height: 8)
            Text(model.statusLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.black30)
        }
    }

    // MARK: Verdict -- the big OS call.

    private var verdictPanel: some View {
        VStack(spacing: 12) {
            Image(systemName: model.osIcon)
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(model.osColor)
            Text(model.osHeadline)
                .font(.system(size: 26, weight: .black, design: .monospaced))
                .foregroundColor(model.osColor)
            Text(model.osSubtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.black30)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Color.groupedBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(model.osColor.opacity(0.5), lineWidth: 1))
        .cornerRadius(12)
    }

    // MARK: Signals -- the raw enumeration tells, as a readout.

    private func signalsPanel(_ scan: HostScan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            panelTitle("ENUMERATION SIGNALS")
            signalRow("MS OS string (0xEE)", scan.msOsStringRequested ? "yes" : "no",
                      strong: scan.msOsStringRequested)
            signalRow("serial string", scan.serialRequested ? "yes" : "no")
            signalRow("product string", scan.productRequested ? "yes" : "no")
            signalRow("manufacturer string", scan.manufRequested ? "yes" : "no")
            signalRow("device desc requests", "\(scan.deviceDescRequests)")
            signalRow("config desc requests", "\(scan.configDescRequests)")
            signalRow("string requests", "\(scan.stringRequests)")
            signalRow("first device wLength", "\(scan.firstDeviceDescWLength)",
                      strong: scan.firstDeviceDescWLength == 64)
        }
        .padding(.vertical, 6)
        .background(Color.groupedBackground)
        .cornerRadius(12)
    }

    private func signalRow(_ name: String, _ value: String, strong: Bool = false)
        -> some View {
        HStack {
            Text(name)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.black40)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: strong ? .bold : .regular,
                              design: .monospaced))
                .foregroundColor(strong ? .a1 : .primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: Raw output -- the terminal block.

    private func rawPanel(_ raw: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            panelTitle("nikita host")
            Text(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.a2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.black.opacity(0.85))
                .cornerRadius(8)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(Color.groupedBackground)
        .cornerRadius(12)
    }

    private func noticePanel(icon: String, title: String, message: String)
        -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(.sYellow)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.black30)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.groupedBackground)
        .cornerRadius(12)
    }

    private func panelTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .foregroundColor(.black40)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rescanButton: some View {
        Button {
            model.scan()
        } label: {
            HStack(spacing: 8) {
                if model.isScanning {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(model.isScanning ? "Scanning..." : "Rescan")
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.a1)
            .cornerRadius(10)
        }
        .disabled(model.isScanning)
    }
}

@MainActor
final class ScanViewerModel: ObservableObject {
    enum State: Equatable {
        case idle
        case scanning
        case notConnected
        case oldFirmware
        case error(String)
        case result(HostScan, raw: String)
    }

    @Published private(set) var state: State = .idle

    private var deps: Core.Dependencies { .shared }
    private var task: Task<Void, Never>?

    var isScanning: Bool { if case .scanning = state { return true }; return false }

    func scanIfIdle() {
        if case .idle = state { scan() }
    }

    // Read the host fingerprint straight from the Flipper over BLE -- the
    // firmware publishes it as usb.host.* device_info properties, so whatever the
    // Flipper sees plugged in, the phone sees too. No bridge, no cable.
    func scan() {
        task?.cancel()
        state = .scanning
        task = Task { [weak self] in
            guard let self else { return }
            let connected: Bool = {
                switch self.deps.device.status {
                case .connected, .synchronizing, .synchronized: return true
                default: return false
                }
            }()
            guard connected else {
                if !Task.isCancelled { self.state = .notConnected }
                return
            }
            do {
                var props: [String: String] = [:]
                let stream = await self.deps.nikitaSystem.deviceInfo()
                for try await (key, value) in stream { props[key] = value }
                if Task.isCancelled { return }
                guard let scan = HostScan.fromProperties(props) else {
                    self.state = .oldFirmware
                    return
                }
                self.state = .result(scan, raw: Self.rawText(scan))
            } catch {
                if Task.isCancelled { return }
                self.state = .error("\(error)")
            }
        }
    }

    // Reconstruct the key=value block for the raw panel from the parsed scan.
    private static func rawText(_ s: HostScan) -> String {
        """
        os=\(s.os.rawValue)
        ms_os_string=\(s.msOsStringRequested ? 1 : 0)
        serial_req=\(s.serialRequested ? 1 : 0)
        product_req=\(s.productRequested ? 1 : 0)
        manuf_req=\(s.manufRequested ? 1 : 0)
        device_desc_req=\(s.deviceDescRequests)
        config_desc_req=\(s.configDescRequests)
        string_req=\(s.stringRequests)
        first_dev_wlen=\(s.firstDeviceDescWLength)
        """
    }

    // The dynamic header line, echoing the browser's folder-name behaviour.
    var contextTitle: String {
        switch state {
        case .idle, .scanning: return "VIEWER"
        case .notConnected: return "VIEWER / offline"
        case .oldFirmware: return "VIEWER / update"
        case .error: return "VIEWER / error"
        case let .result(scan, _): return "VIEWER / \(scan.os.rawValue)"
        }
    }

    var statusLabel: String {
        switch state {
        case .idle: return "READY"
        case .scanning: return "SCANNING"
        case .notConnected: return "NO FLIPPER"
        case .oldFirmware: return "OLD FW"
        case .error: return "ERROR"
        case .result: return "LOCKED"
        }
    }

    var statusColor: Color {
        switch state {
        case .result: return .sGreenUpdate
        case .error, .notConnected, .oldFirmware: return .sYellow
        default: return .black40
        }
    }

    var osHeadline: String {
        switch state {
        case .scanning: return "SCANNING"
        case .idle: return "IDLE"
        case .notConnected, .oldFirmware, .error: return "—"
        case let .result(scan, _):
            switch scan.os {
            case .windows: return "WINDOWS"
            case .macos: return "macOS"
            case .linux: return "LINUX"
            case .unknown: return scan.hasScanned ? "UNKNOWN" : "NO HOST"
            }
        }
    }

    var osSubtitle: String {
        switch state {
        case .scanning: return "reading the fingerprint over Bluetooth…"
        case .idle: return "pull the fingerprint"
        case .notConnected: return "connect a Flipper to scan its host"
        case .oldFirmware: return "update the firmware to read the host"
        case .error: return "could not reach the Flipper"
        case let .result(scan, _): return scan.summary
        }
    }

    var osIcon: String {
        guard case let .result(scan, _) = state else { return "questionmark.circle" }
        switch scan.os {
        case .windows: return "window.horizontal.closed"
        case .macos: return "apple.logo"
        case .linux: return "terminal"
        case .unknown: return "questionmark.circle"
        }
    }

    var osColor: Color {
        guard case let .result(scan, _) = state else { return .black40 }
        switch scan.os {
        case .unknown: return .black40
        default: return .a1
        }
    }
}
