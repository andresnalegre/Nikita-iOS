import Core
import SwiftUI

struct TabView: View {
    @EnvironmentObject var device: Device
    @EnvironmentObject var synchronization: Synchronization
    @EnvironmentObject var applications: Applications

    @Environment(\.colorScheme) var colorScheme

    @Binding var selected: Tab
    var extraAction: () -> Void

    @AppStorage(.hasReaderLog) var hasReaderLog = false

    var hasAppUpdates: Bool {
        applications.outdatedCount > 0
    }

    enum Tab: String, CaseIterable {
        case device
        case archive
        case remote
        case apps
        case hub
    }

    func color(for tab: Tab) -> Color {
        selected == tab ? .accentColor : .secondary
    }

    func handleTap(on tab: Tab) {
        switch selected {
        case tab: extraAction()
        default: selected = tab
        }
    }

    struct Badge: View {
        let offset: Double

        var body: some View {
            Circle()
                .frame(width: 12, height: 12)
                .foregroundColor(.white)
                .overlay(alignment: .center) {
                    Circle()
                        .frame(width: 10, height: 10)
                        .foregroundColor(.sGreenUpdate)
                }
                .offset(x: offset, y: -2)
        }
    }

    var body: some View {
        VStack {
            Divider()
                .background(.surfaceBottomBarSeparator)

            HStack(alignment: .top) {
                TabViewItem(
                    image: deviceImage,
                    name: deviceTabName,
                    isSelected: selected == .device
                ) {
                    handleTap(on: .device)
                }
                .foregroundColor(deviceColor)

                Spacer(minLength: 0)

                TabViewItem(
                    image: remoteImage,
                    name: "Remote",
                    isSelected: selected == .remote
                ) {
                    handleTap(on: .remote)
                }
                .foregroundColor(remoteColor)

                Spacer(minLength: 0)

                TabViewItem(
                    image: appsImage,
                    name: "Apps",
                    isSelected: selected == .apps
                ) {
                    handleTap(on: .apps)
                }
                .foregroundColor(appsColor)
                .analyzingTapGesture {
                    recordAppsOpened()
                }

                Spacer(minLength: 0)

                TabViewItem(
                    image: hubImage,
                    name: "Tools",
                    isSelected: selected == .hub
                ) {
                    handleTap(on: .hub)
                }
                .foregroundColor(hubColor)
            }
            .padding(3)
        }
        .background(.surfaceBottomBarBody)
    }

    // MARK: Analytics

    func recordAppsOpened() {
        analytics.appOpen(target: .fapHub)
    }
}

private extension TabView {
    var deviceTabName: String {
        switch device.status {
        case .noDevice: return "No Device"
        case .unsupported: return "Unsupported"
        case .outdatedMobile: return "Outdated App"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        // TODO: Think about .notConnected state
        case .disconnected: return "Not Connected"
        case .synchronizing: return "Syncing \(synchronization.progress.value)%"
        case .synchronized: return "Synced!"
        case .updating: return "Connecting..."
        case .invalidPairing: return "Pairing Failed"
        case .pairingFailed: return "Pairing Failed"
        }
    }
}

extension Device.Status {
    // The healthy states are the brand magenta, not the neon green they used
    // to be: green sat oddly against this app's palette and read as a stock
    // "OK" light rather than as part of it. Faults stay red -- that is the one
    // colour worth keeping literal -- and idle states stay grey.
    var color: Color {
        switch self {
        case .noDevice: .black40
        case .unsupported: .sRed
        case .outdatedMobile: .sRed
        case .connecting: .black40
        case .connected: .a1
        case .disconnected: .black40
        case .synchronizing: .a1
        case .synchronized: .a1
        case .updating: .black40
        case .invalidPairing: .sRed
        case .pairingFailed: .sRed
        }
    }
}

private extension TabView {
    var deviceColor: Color {
        guard selected == .device else { return .black30 }
        return device.status.color
    }

    // Selected tabs take the brand accent. They used to resolve to .black30 on
    // a dark bar -- the same value as the unselected ones -- so which tab you
    // were on was nearly invisible.
    var archiveColor: Color {
        selected == .archive ? .a1 : .black30
    }

    var remoteColor: Color {
        selected == .remote ? .a1 : .black30
    }

    var appsColor: Color {
        selected == .apps ? .a1 : .black30
    }

    var hubColor: Color {
        selected == .hub ? .a1 : .black30
    }
}

private extension TabView {
    var deviceImage: AnyView {
        .init(DeviceImage(status: device.status))
    }

    var archiveImage: AnyView {
        .init(
            Image(archiveImageName)
                .renderingMode(.template)
        )
    }

    var remoteImage: AnyView {
        .init(
            Image(systemName: selected == .remote
                ? "gamecontroller.fill"
                : "gamecontroller")
                .font(.system(size: 22))
        )
    }

    var appsImage: AnyView {
        .init(
            Image(appsImageName)
                .renderingMode(.template)
                .overlay(alignment: .topLeading) {
                    if hasAppUpdates {
                        Badge(offset: 24)
                    }
                }
        )
    }

    var hubImage: AnyView {
        .init(
            Image(hubImageName)
                .renderingMode(.template)
                .overlay(alignment: .topLeading) {
                    if hasReaderLog {
                        Badge(offset: 30)
                    }
                }
        )
    }

    var archiveImageName: String {
        selected == .archive ? "archive_filled_icon" : "archive_line_icon"
    }

    var appsImageName: String {
        selected == .apps ? "apps_filled_icon" : "apps_line_icon"
    }

    var hubImageName: String {
        selected == .hub ? "tools_filled_icon" : "tools_line_icon"
    }
}
