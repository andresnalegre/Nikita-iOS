import Nikita
import SwiftUI

// The app-level Flipper->Nikita relay.
//
// On qFlipper the Buddy watcher lives in the always-on backend, so a question
// typed on the Flipper is answered whatever the desktop is showing. The iPhone
// had no equivalent: the watcher was tied to the Nikita chat screen, so over
// BLE the relay only worked while that screen was open. This owns a headless
// agent whose only job is the relay, alive for the app's lifetime, so the
// Flipper is answered no matter which tab the phone is on -- as long as the app
// is in the foreground (iOS suspends background work) and a Flipper is paired.
@MainActor
final class NikitaBuddyService: ObservableObject {
    private let agent = NikitaAgent(
        bridge: LiveDeviceBridge(),
        machine: MailboxMachineBridge(),
        relayEnabled: true)

    private var started = false

    // Idempotent: safe to call on every app-active transition. connectMcp only
    // starts the poll once (buddyPoll == nil guards it), and refreshes the MCP
    // servers and device identity each time, which is harmless.
    func activate() {
        Task {
            await agent.connectMcp()
            started = true
        }
    }
}
