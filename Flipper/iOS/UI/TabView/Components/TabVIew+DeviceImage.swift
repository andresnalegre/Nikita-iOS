import Core
import SwiftUI

extension TabView {
    // The Flipper tab's icon, drawn like every other tab's: a single glyph in
    // whatever colour the bar is tinting it.
    //
    // It used to be that glyph sitting inside a Flipper-shaped outline painted
    // with the connection status -- so this one tab carried a coloured border
    // no other tab had. The status is already spelled out in the label right
    // beneath it ("Connected", "Not Connected", "Pairing Failed"), so nothing
    // is lost by letting the icon match its neighbours.
    //
    // The glyphs are authored at 12pt to fit inside that old outline, so they
    // are scaled to sit at the same weight as the ~22pt icons beside them.
    struct DeviceImage: View {
        let status: Device.Status

        private var deviceActionName: String {
            "device_" + status.iconName
        }

        var body: some View {
            Group {
                switch status {
                case .connecting, .synchronizing:
                    RotatingImage(name: deviceActionName)

                default:
                    Image(deviceActionName)
                        .renderingMode(.template)
                        .resizable()
                }
            }
            .frame(width: 22, height: 22)
        }

        struct RotatingImage: View {
            @State private var isAnimating: Bool = false
            let name: String

            var body: some View {
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .animation(
                        .linear(duration: 2)
                        .repeatForever(autoreverses: false),
                        value: isAnimating
                    )
                    .onAppear { isAnimating = true }
                    .onDisappear { isAnimating = false }
            }
        }
    }
}

private extension Device.Status {
    var iconName: String {
        switch self {
        case .noDevice: "no_device"
        case .unsupported: "unsupported"
        case .outdatedMobile: "unsupported"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .synchronizing: "syncing"
        case .synchronized: "synced"
        case .updating: "connecting"
        case .invalidPairing: "pairing_failed"
        case .pairingFailed: "pairing_failed"
        }
    }
}
