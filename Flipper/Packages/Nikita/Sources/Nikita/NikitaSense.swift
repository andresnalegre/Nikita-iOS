import Foundation
import Network

// Nikita's senses on the phone. iOS can't shell out, so perception here is what
// the sandbox honestly allows: which kind of network she's on right now. The
// richer reads (who's on the LAN, Bluetooth around) come from the bridged
// computer when one is connected -- the agent adds those to the snapshot.
enum NikitaSense {
    // The current network interface type: wifi / cellular / wired / offline.
    // A brief, self-cancelling probe with a safety timeout so it never hangs.
    static func pathType() async -> String {
        await withCheckedContinuation { cont in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "nikita.sense.path")
            var done = false
            let finish: (String) -> Void = { value in
                if done { return }
                done = true
                monitor.cancel()
                cont.resume(returning: value)
            }
            monitor.pathUpdateHandler = { path in
                let type: String
                if path.status != .satisfied {
                    type = "offline"
                } else if path.usesInterfaceType(.wifi) {
                    type = "wifi"
                } else if path.usesInterfaceType(.cellular) {
                    type = "cellular"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    type = "wired"
                } else {
                    type = "other"
                }
                finish(type)
            }
            monitor.start(queue: queue)
            // Both closures run on the same serial queue, so `done` is safe.
            queue.asyncAfter(deadline: .now() + 1.5) { finish("unknown") }
        }
    }
}
