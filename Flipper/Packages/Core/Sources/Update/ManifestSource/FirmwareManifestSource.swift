import Foundation

protocol FirmwareManifestSource {
    func get(
        progress: @escaping (Double) -> Void
    ) async throws -> FirmwareManifest
}

extension FirmwareManifestSource {
    func get() async throws -> FirmwareManifest {
        try await get { _ in }
    }
}

// MARK: Remote

struct RemoteFirmwareManifestSource: FirmwareManifestSource {
    func get(
        progress: @escaping (Double) -> Void
    ) async throws -> FirmwareManifest {
        // FirmwareFeed.current, not a constant: whichever firmware is on the
        // device is the one whose releases this card should be reporting.
        let data = URLSessionData(from: FirmwareFeed.current) {
            progress($0.fractionCompleted)
        }
        return try await JSONDecoder().decode(
            FirmwareManifest.self,
            from: data.result
        )
    }
}
