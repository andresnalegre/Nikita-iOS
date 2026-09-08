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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.a2.opacity(0.4))
                ScrollView {
                    VStack(spacing: 16) {
                        verdictPanel
                        if case let .result(scan, raw) = model.state {
                            signalsPanel(scan)
                            rawPanel(raw)
                        } else if case let .error(message) = model.state {
                            noticePanel(
                                icon: "exclamationmark.triangle.fill",
                                title: "Scan failed", message: message)
                        } else if case .noBridge = model.state {
                            noticePanel(
                                icon: "cable.connector.slash",
                                title: "No bridge",
                                message: "Plug the Flipper into the computer and "
                                    + "run  python3 bridge.py --mailbox  so the "
                                    + "Viewer can read the host it is attached to.")
                        }
                        rescanButton
                    }
                    .padding(16)
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
        .onAppear { model.scanIfIdle() }
    }

    // MARK: Header -- the dynamic context line, like the browser's folder name.

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.a1)
            Text(model.contextTitle)
                .font(.system(size: 15, weight: .heavy, design: .monospaced))
                .foregroundColor(.primary)
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
        case noBridge
        case error(String)
        case result(HostScan, raw: String)
    }

    @Published private(set) var state: State = .idle

    private let machine = MailboxMachineBridge()
    private var task: Task<Void, Never>?

    var isScanning: Bool { if case .scanning = state { return true }; return false }

    func scanIfIdle() {
        if case .idle = state { scan() }
    }

    func scan() {
        task?.cancel()
        state = .scanning
        task = Task { [weak self] in
            guard let self else { return }
            guard await self.machine.isBridgeConnected else {
                if !Task.isCancelled { self.state = .noBridge }
                return
            }
            do {
                let raw = try await self.machine.send("nikita host")
                if Task.isCancelled { return }
                self.state = .result(HostScan.parse(raw), raw: raw)
            } catch {
                if Task.isCancelled { return }
                self.state = .error("\(error)")
            }
        }
    }

    // The dynamic header line, echoing the browser's folder-name behaviour.
    var contextTitle: String {
        switch state {
        case .idle, .scanning: return "VIEWER"
        case .noBridge: return "VIEWER / offline"
        case .error: return "VIEWER / error"
        case let .result(scan, _): return "VIEWER / \(scan.os.rawValue)"
        }
    }

    var statusLabel: String {
        switch state {
        case .idle: return "READY"
        case .scanning: return "SCANNING"
        case .noBridge: return "NO BRIDGE"
        case .error: return "ERROR"
        case .result: return "LOCKED"
        }
    }

    var statusColor: Color {
        switch state {
        case .result: return .sGreenUpdate
        case .error, .noBridge: return .sYellow
        default: return .black40
        }
    }

    var osHeadline: String {
        switch state {
        case .scanning: return "SCANNING"
        case .idle: return "IDLE"
        case .noBridge, .error: return "—"
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
        case .scanning: return "reading how the host enumerated us…"
        case .idle: return "pull the fingerprint"
        case .noBridge: return "bridge needed to read the host"
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
