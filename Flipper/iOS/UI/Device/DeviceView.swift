import Core
import SwiftUI
import UIKit
import Notifications

struct DeviceView: View {
    // Every tab lives in the same ZStack and only its opacity changes, so
    // onAppear fires once at launch and onDisappear never fires on a tab
    // switch. Mirroring was hung on those two, which is why leaving for the
    // remote control and coming back left the header frozen: nothing told it it
    // was on screen again. Tab selection is the signal that actually changes.
    var isActive: Bool = true

    @EnvironmentObject var router: Router
    @EnvironmentObject var central: Central
    @EnvironmentObject var device: Device
    @EnvironmentObject var synchronization: Synchronization
    @EnvironmentObject var updateModel: UpdateModel
    @EnvironmentObject var notifications: Notifications

    @Environment(\.scenePhase) var scenePhase

    // The header mirrors the Flipper's screen, which means asking the device to
    // stream it. Only while this screen is actually in front and the device is
    // otherwise idle: the stream shares the one BLE link with syncing and
    // updating, and it is decoration here -- it must never be the reason a
    // transfer slows down or an update stumbles.
    @State private var mirrorKeepAlive: Task<Void, Never>?

    private var canMirrorScreen: Bool {
        device.status == .connected || device.status == .synchronized
    }

    private func startMirroring() {
        guard canMirrorScreen else { return }
        device.startScreenStreaming()
        startMirrorKeepAlive()
    }

    private func stopMirroring() {
        mirrorKeepAlive?.cancel()
        mirrorKeepAlive = nil
        device.stopScreenStreaming()
    }

    // Re-assert the stream every couple of seconds, the same way the remote
    // control does. A BLE hiccup restarts the RPC session and the Flipper
    // forgets it was streaming; asking once meant the mirror showed the last
    // frame that arrived and then sat there, which looked like a screenshot
    // rather than a screen.
    private func startMirrorKeepAlive() {
        mirrorKeepAlive?.cancel()
        mirrorKeepAlive = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                if isActive, canMirrorScreen, scenePhase == .active {
                    device.startScreenStreaming()
                }
            }
        }
    }

    @State private var path = NavigationPath()

    // Shown right after forgetting: a notice, not an offer. iOS keeps its own
    // pairing with the Flipper and no app can remove it -- CoreBluetooth has no
    // unpair call, and the system pairing list is the user's to edit. So this
    // says the removal has to be done by hand and opens the one screen where it
    // can be, rather than implying the app will do it.
    @State private var showForgetOnPhone = false
    @State private var showOutdatedFirmwareAlert = false
    @State private var showOutdatedMobileAlert = false

    @AppStorage(.notificationsSuggested) var notificationsSuggested = false
    @AppStorage(.isNotificationsOn) var isNotificationsOn = false
    @State private var showNotificationsAlert: Bool = false
    @Environment(\.notifications) var inApp

    var flipper: Flipper? {
        device.flipper
    }

    var isDeviceAvailable: Bool {
        device.status == .connected ||
        device.status == .synchronized ||
        device.status == .synchronizing
    }

    var isOutdatedVersion: Bool {
        device.status == .unsupported ||
        device.status == .outdatedMobile
    }

    var canSync: Bool {
        device.status == .connected
    }

    var canPlayAlert: Bool {
        device.flipper?.state == .connected && !isOutdatedVersion
    }

    var canConnect: Bool {
        flipper?.state == .disconnected ||
        flipper?.state == .disconnecting ||
        flipper?.state == .pairingFailed ||
        flipper?.state == .invalidPairing
    }

    var canDisconnect: Bool {
        flipper?.state == .connected ||
        flipper?.state == .connecting
    }

    var canForget: Bool {
        device.status != .noDevice
    }

    enum Destination {
        case info
        case options
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                DeviceHeader(device: flipper, screen: device.frame)

                ScrollView {
                    VStack(spacing: 0) {
                        switch device.status {
                        case .unsupported:
                            OutdatedFirmwareCard()
                                .padding(.top, 24)
                                .padding(.horizontal, 14)
                        case .outdatedMobile:
                            OutdatedMobileCard()
                                .padding(.top, 24)
                                .padding(.horizontal, 14)
                        default:
                            // Device info first: what the Flipper IS reads
                            // before what could be done to it, and the update
                            // card is the one that changes shape the most.
                            NavigationLink(value: Destination.info) {
                                DeviceInfoCard()
                                    .padding(.top, 24)
                                    .padding(.horizontal, 14)
                            }
                            .disabled(!isDeviceAvailable)
                            if device.status != .noDevice {
                                DeviceUpdateCard()
                                    .padding(.top, 24)
                                    .padding(.horizontal, 14)
                            }
                        }

                        VStack(spacing: 24) {
                            VStack(spacing: 0) {
                                NavigationButton(
                                    image: "Options",
                                    title: "Options",
                                    destination: Destination.options
                                )
                            }
                            .cornerRadius(10)

                            if device.status != .noDevice {
                                VStack(spacing: 0) {
                                    ActionButton(
                                        image: "Sync",
                                        title: "Synchronize"
                                    ) {
                                        synchronization.start()
                                    }
                                    .disabled(!canSync)

                                    Divider()

                                    ActionButton(
                                        image: "Alert",
                                        title: "Play Alert"
                                    ) {
                                        device.playAlert()
                                    }
                                    .disabled(!canPlayAlert)
                                }
                                .cornerRadius(10)
                            }

                            VStack(spacing: 0) {
                                if device.status == .noDevice {
                                    ActionButton(
                                        image: "Connect",
                                        title: "Connect Flipper"
                                    ) {
                                        connect()
                                    }
                                } else {
                                    if canConnect {
                                        ActionButton(
                                            image: "Connect",
                                            title: "Connect"
                                        ) {
                                            connect()
                                        }
                                    }

                                    if canDisconnect {
                                        ActionButton(
                                            image: "Disconnect",
                                            title: "Disconnect"
                                        ) {
                                            disconnect()
                                        }
                                    }

                                    Divider()

                                    if canForget {
                                        ActionButton(
                                            image: "Forget",
                                            title: "Forget Flipper"
                                        ) {
                                            device.forgetDevice()
                                            showForgetOnPhone = true
                                        }
                                        .foregroundColor(.sRed)
                                    }
                                }
                            }
                            .cornerRadius(10)
                        }
                        .padding(.vertical, 24)
                        .padding(.horizontal, 14)
                    }
                }
                .background(Color.background)
                .refreshable(isEnabled: isDeviceAvailable) {
                    updateModel.updateAvailableFirmware()
                }
            }
            .navigationBarHidden(true)
            .navigationBarBackground(Color.background)
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .info: DeviceInfoView()
                case .options: OptionsView()
                }
            }
        }
        // Deliberately out here, on the NavigationStack rather than inside the
        // scroll view. Forgetting flips device.status to .noDevice, which
        // rebuilds that subtree -- and took the alert down with it the instant
        // it appeared, so the one thing the user had to read flashed past.
        // No close button: OK is the only way out, and a second control that
        // does the same thing invites dismissing the one instruction unread.
        .alert(isPresented: $showForgetOnPhone, showsCloseButton: false) {
            RemovePairingAlert(isPresented: $showForgetOnPhone)
        }
        .alert(isPresented: $showOutdatedFirmwareAlert) {
            OutdatedFirmwareAlert(isPresented: $showOutdatedFirmwareAlert)
        }
        .alert(isPresented: $showOutdatedMobileAlert) {
            OutdatedMobileAlert(isPresented: $showOutdatedMobileAlert)
        }
        .onChange(of: device.status) { status in
            showOutdatedFirmwareAlert = status == .unsupported
            showOutdatedMobileAlert = status == .outdatedMobile
        }
        .onChange(of: central.state) { state in
            if state == .poweredOn {
                device.connect()
            }
        }
        .onChange(of: scenePhase) { scenePhase in
            switch scenePhase {
            case .active:
                onActive()
                if isActive { startMirroring() }
            default:
                // Backgrounded: stop asking for frames nobody can see.
                stopMirroring()
            }
        }
        .onAppear { if isActive { startMirroring() } }
        .onDisappear { stopMirroring() }
        .onChange(of: isActive) { active in
            active ? startMirroring() : stopMirroring()
        }
        .onChange(of: device.status) { _ in
            // Follows the device rather than being set once: the stream cannot
            // start before there is a connection, and a sync starting is a
            // reason to get out of the way.
            guard isActive else { return }
            canMirrorScreen ? startMirroring() : stopMirroring()
        }
        .task {
            if central.state != .poweredOn {
                central.kick()
            }
            suggestNotifications()
        }
        .alert(isPresented: $showNotificationsAlert) {
            EnableNotificationsAlert(isPresented: $showNotificationsAlert) {
                Task { await enableNotifications() }
            }
        }
        .notification(isPresented: inApp.notifications.showEnabled) {
            NotificationsEnabledBanner(
                isPresented: inApp.notifications.showEnabled)
        }
        .notification(isPresented: inApp.notifications.showDisabled) {
            NotificationsDisabledBanner(
                isPresented: inApp.notifications.showDisabled)
        }
        .environment(\.path, $path)
    }

    func suggestNotifications() {
        guard !notificationsSuggested else { return }
        Task { @MainActor in
            try? await Task.sleep(seconds: 1)
            notificationsSuggested = true
            showNotificationsAlert = true
        }
    }

    func onActive() {
        if device.status == .disconnected, central.state == .poweredOn {
            device.connect()
        }
    }

    func connect() {
        guard device.status != .noDevice else {
            router.showWelcomeScreen()
            return
        }

        guard central.state == .poweredOn else {
            showBluetoothDisabled()
            return
        }

        device.connect()
    }

    func disconnect() {
        device.disconnect()
    }

    func enableNotifications() async {
        do {
            try await notifications.enable()
            isNotificationsOn = true
            inApp.notifications.showEnabled = true
        } catch {
            inApp.notifications.showDisabled = true
        }
    }
}

// FIXME: refactor

import CoreBluetooth

private func showBluetoothDisabled() {
    _ = CBCentralManager()
}
