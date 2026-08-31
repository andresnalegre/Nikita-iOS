// FIXME: Move somewhere

extension Flipper.DeviceInformation {
    public var firmwareVersion: Update.Version? {
        guard let channel = firmwareChannel else {
            return nil
        }
        let parts = softwareRevision.split(separator: " ")

        var version: String
        switch channel {
        case .release: version = "\(parts[1])"
        case .candidate: version = "\(parts[1])"
        // The official firmware's development builds all report the version
        // "dev", so the commit is the only thing that identifies one. A Nikita
        // development build is tagged ("nkt-001-dev") and so identifies itself.
        case .development: version = isNikitaVersion ? "\(parts[1])" : "\(parts[0])"
        case .custom: version = "\(parts[1])"
        }

        return .init(name: version, channel: channel)
    }

    private var versionField: Substring? {
        let parts = softwareRevision.split(separator: " ")
        return parts.count >= 2 ? parts[1] : nil
    }

    private var isNikitaVersion: Bool {
        Update.Channel(nikitaVersion: versionField) != nil
    }

    private var firmwareChannel: Update.Channel? {
        guard let version = versionField else { return nil }

        // Nikita first: its tags are the shape this app is built to expect.
        if let channel = Update.Channel(nikitaVersion: version) {
            return channel
        }

        guard !version.hasSuffix("-rc") else {
            return .candidate
        }

        let versionParts = version.split(separator: ".")
        guard
            versionParts.count == 3,
            versionParts.allSatisfy({ $0.allSatisfy { $0.isNumber } })
        else {
            return version == "dev" ? .development : .custom
        }

        return .release
    }
}

extension Update.Channel {
    // Nikita tags its releases "nkt-001", "nkt-001-rc" and "nkt-001-dev", and
    // the build stamps the tag into the version, so the tag is what reaches the
    // app in the device's software revision string.
    //
    // Without this every Nikita build read as `.custom`, which left the update
    // card permanently claiming the firmware "doesn't match update channel" --
    // it matched perfectly, the app just had no name for the channel it was on.
    //
    // A locally built Nikita reports "v8" and is deliberately NOT matched here:
    // it came from nobody's release channel, so `.custom` is the truth about it.
    //
    // Note this says nothing about WHICH firmware is running -- that is
    // device_info's firmware_origin_fork, not anything in this string.
    init?(nikitaVersion version: Substring?) {
        guard var rest = version.map(Substring.init) else { return nil }
        guard rest.hasPrefix("nkt-") else { return nil }
        rest = rest.dropFirst("nkt-".count)

        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }

        switch rest.dropFirst(digits.count) {
        case "": self = .release
        case "-rc": self = .candidate
        case "-dev": self = .development
        default: return nil
        }
    }
}
