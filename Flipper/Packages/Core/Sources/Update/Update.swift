import Foundation

public enum Update {
    // A channel with nothing published to it is a normal state, not a broken
    // feed: Nikita starts every channel empty and fills them as releases are
    // tagged, so `release` can carry a build while `development` is still bare.
    // These were non-optional, which meant one empty channel threw and took the
    // other two down with it -- the whole update card failed over a channel the
    // user was not even on.
    public struct Manifest {
        public let release: Firmware?
        public let candidate: Firmware?
        public let development: Firmware?

        // True when the feed parsed but carries no build on any channel.
        // Distinguishable from "could not reach the feed", which is what the
        // card used to report for both.
        public var isEmpty: Bool {
            release == nil && candidate == nil && development == nil
        }
    }

    public struct Firmware: Equatable {
        public var version: Version
        public var changelog: String
        public var url: URL

        public init(version: Version, changelog: String, url: URL) {
            self.version = version
            self.changelog = changelog
            self.url = url
        }
    }

    public struct Version: Equatable, Codable {
        public let name: String
        public let channel: Channel

        public init(name: String, channel: Channel) {
            self.name = name
            self.channel = channel
        }
    }

    public enum Channel: String, Equatable, Codable {
        case development
        case candidate
        case release
        case custom
    }

    public enum Target: String {
        case f7
    }

    public enum Error: Swift.Error {
        case invalidFirmware
        case invalidFirmwareURL
        case invalidFirmwareURLString
        case invalidFirmwareCloudDocument
    }

    public struct Intent: Equatable, Identifiable {
        public let id: Int
        public let currentVersion: Version
        public let desiredVersion: Version
    }
}

extension Update.Manifest {
    init(for target: Update.Target, from manifest: FirmwareManifest) {
        // Per channel, so an empty or missing one costs only itself.
        release = try? manifest.firmware(for: target, channel: .release)
        candidate = try? manifest.firmware(for: target, channel: .candidate)
        development = try? manifest.firmware(for: target, channel: .development)
    }
}

extension FirmwareManifest {
    func firmware(
        for target: Update.Target,
        channel: Update.Channel
    ) throws -> Update.Firmware {
        let version = try self.channel(withID: channel.id)
            .version(forTarget: target.rawValue)

        let url = try version
            .updateBundle(forTarget: target.rawValue)
            .url

        return .init(
            version: .init(
                name: version.version,
                channel: channel),
            changelog: version.changelog,
            url: url)
    }
}

private extension Update.Channel {
    var id: String {
        switch self {
        case .development: return "development"
        case .candidate: return "release-candidate"
        case .release: return "release"
        case .custom: return "custom"
        }
    }
}

extension Update.Version: CustomStringConvertible {
    public var description: String {
        switch channel {
        case .development: return "Dev \(name)"
        case .candidate: return "RC \(name.dropLast(3))"
        case .release: return "Release \(name)"
        case .custom: return "Custom \(name)"
        }
    }
}
