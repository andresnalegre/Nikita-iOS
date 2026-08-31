import Macro
import Foundation

extension String {
    static var appGroup: String {
        "group.com.andresnialegre.flipper"
    }
}

extension URL {
    static var shareBaseURL = #URL(
        "https://flpr.app/s"
    )
    static var shareFileBaseURL = #URL(
        "https://flpr.app/sf"
    )
    static var transferBaseURL = #URL(
        "https://transfer.flpr.app"
    )
}

extension URL {
    // The update feed this app treats as its own.
    //
    // Nikita firmware is what this ecosystem is built around, so it -- not the
    // official firmware -- is what the Firmware Update card offers. Everything
    // else (Official, Momentum, Unleashed, RogueMaster, ARF, Xero) stays one
    // tap away under Import, which flashes any of them through the same path.
    //
    // Served straight out of the firmware repo rather than from a dedicated
    // update server: the release workflow regenerates it and commits it, so
    // there is no host to keep alive and no second place a version can drift.
    // The format is the same one Flipper Devices' server serves, which is why
    // nothing here had to learn a new protocol.
    public static var firmwareManifestURL = #URL(
        "https://raw.githubusercontent.com/andresnalegre/Nikita-V8/main/firmware/directory.json"
    )

    // Reachable from Import, for going back to stock.
    public static var officialFirmwareManifestURL = #URL(
        "https://update.flipperzero.one/firmware/directory.json"
    )
}
