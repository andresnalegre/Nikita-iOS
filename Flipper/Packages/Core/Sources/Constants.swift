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

    // Where Report Bug submits. Formspree relays it to the address the form is
    // configured with, so the destination lives in the form rather than here.
    //
    // Set FORM_ID to the id from the form's endpoint
    // (https://formspree.io/f/FORM_ID). Until it is a real id, Report Bug says
    // it is not configured rather than silently dropping reports.
    public static var bugReportEndpoint: URL? {
        let formID = "mrpglvov"
        guard formID != "FORM_ID", !formID.isEmpty else { return nil }
        return URL(string: "https://formspree.io/f/\(formID)")
    }

    public static var momentumFirmwareManifestURL = #URL(
        "https://up.momentum-fw.dev/firmware/directory.json"
    )
}

// Which firmware a Flipper is running, and where its releases come from.
//
// Two sources of truth, because neither is enough on its own:
//
//   * firmware_origin_fork is exact when it is there, but it is a field the
//     Unleashed lineage added. A stock Flipper does not necessarily report it,
//     which is how an Official 1.4.3 device kept being offered Nikita releases:
//     the fork came back empty and the feed was left where it was.
//   * the version string always arrives, and each firmware tags in its own
//     shape -- nkt-002, mntm-012, unlshd-092, RM0819-..., and plain semver for
//     Official.
//
// Fork first, version as the fallback.
public enum FirmwareIdentity {
    case nikita, official, momentum, unleashed, rogueMaster, arf, xero

    public static func identify(fork: String?, version: String?) -> Self? {
        if let fork = fork?.lowercased(), !fork.isEmpty {
            if fork.contains("nikita") { return .nikita }
            if fork.contains("momentum") { return .momentum }
            if fork.contains("unleashed") { return .unleashed }
            if fork.contains("roguemaster") { return .rogueMaster }
            if fork.contains("xero") { return .xero }
            if fork.contains("arf") { return .arf }
            if fork.contains("official") { return .official }
        }

        guard let version = version?.lowercased(), !version.isEmpty else {
            return nil
        }
        if version.hasPrefix("nkt-") { return .nikita }
        if version.hasPrefix("mntm-") { return .momentum }
        if version.hasPrefix("unlshd-") { return .unleashed }
        if version.hasPrefix("rm") { return .rogueMaster }
        if version.contains("xero") { return .xero }

        // Official tags plain semver, and its development builds report "dev".
        // Deliberately last: every fork above also carries digits and dots
        // somewhere, so this only gets to answer once they have all declined.
        if version == "dev" { return .official }
        let core = version.hasSuffix("-rc")
            ? String(version.dropLast(3))
            : version
        let parts = core.split(separator: ".")
        if parts.count == 3, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return .official
        }
        return nil
    }

    // The name the import store lists this firmware under.
    public var displayName: String {
        switch self {
        case .nikita: return "Nikita"
        case .official: return "Official"
        case .momentum: return "Momentum"
        case .unleashed: return "Unleashed"
        case .rogueMaster: return "RogueMaster"
        case .arf: return "ARF"
        case .xero: return "Xero"
        }
    }

    // Only these three publish a directory.json. The rest release through
    // GitHub, which this feed format cannot read.
    public var manifestURL: URL? {
        switch self {
        case .nikita: return .firmwareManifestURL
        case .official: return .officialFirmwareManifestURL
        case .momentum: return .momentumFirmwareManifestURL
        default: return nil
        }
    }
}

// Which directory.json the update card compares the device against.
//
// It used to be a constant -- always Nikita's -- so a Flipper flashed with
// Official kept being offered Nikita releases, and the card compared 1.4.3
// against nkt-002 and called it an update. The feed has to follow the firmware
// that is actually on the device.
public enum FirmwareFeed {
    // Read on every manifest fetch rather than captured at startup, because the
    // answer changes the moment a different firmware is flashed.
    public nonisolated(unsafe) static var current: URL = .firmwareManifestURL
}
