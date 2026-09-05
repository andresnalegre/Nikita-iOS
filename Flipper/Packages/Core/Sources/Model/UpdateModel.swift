import Peripheral

import Combine
import Foundation

@MainActor
public class UpdateModel: ObservableObject {
    @Published public var state: State = .loading {
        didSet { onStateChanged(oldValue) }
    }

    @Published var flipper: Flipper? {
        didSet { onFlipperChanged(oldValue) }
    }

    @Published public var manifest: Update.Manifest?
    @Published public var customFirmware: Update.Firmware?
    // True when the chosen custom firmware is a newer build of the SAME
    // firmware the Flipper is already running, rather than a switch to a
    // different one. Both travel the custom channel, but they are not the same
    // act, and the card should not call an update an install.
    @Published public var customIsSameFirmware = false
    @Published public var updateChannel: Update.Channel = .load() {
        didSet {
            if updateChannel != .custom {
                updateChannel.save()
            }
            updateState()
        }
    }

    @Published public var intent: Update.Intent?
    @Published public var showUpdate = false

    public var firmware: Update.Firmware? {
        switch updateChannel {
        case .release: return manifest?.release
        case .candidate: return manifest?.candidate
        case .development: return manifest?.development
        case .custom: return customFirmware
        }
    }

    public var installed: Update.Version? {
        flipper?.information?.firmwareVersion
    }
    public var available: Update.Version? {
        guard updateChannel != .custom else {
            return .init(
                name: customFirmware?.version.name ?? "unknown",
                channel: .custom)
        }
        return firmware?.version
    }

    public enum State: Equatable {
        case loading
        case ready(Ready)
        case update(Update)
        case error(Error)

        public enum Ready: Equatable {
            case noUpdates
            case versionUpdate
            case channelUpdate
        }

        public enum Update: Equatable, Codable, Hashable {
            case progress(Progress)
            case result(Result)

            public enum Progress: Equatable, Codable, Hashable {
                case preparing
                case downloading(Double)
                case uploading(Double)
            }

            public enum Result: Equatable, Codable, Hashable {
                case started
                case canceled
                case succeeded
                case failed
            }
        }

        public enum Error: Equatable {
            case noCard
            case noDevice
            case noInternet
            case cantConnect
            // The feed was fetched and parsed, and has no build on the chosen
            // channel. Kept apart from `cantConnect` because "Nikita has not
            // published to this channel yet" and "the server is unreachable"
            // are different problems with different fixes, and telling the user
            // the wrong one sends them to check their Wi-Fi over nothing.
            case noReleases
        }
    }

    private var device: Device

    private let manifestSource: TargetManifestSource
    private let provider: FirmwareProvider
    private let uploader: FirmwareUploader

    private var cancellables: [AnyCancellable] = .init()

    public init(
        device: Device,
        manifestSource: TargetManifestSource,
        firmwareProvider: FirmwareProvider,
        firmwareUploder: FirmwareUploader
    ) {
        self.device = device
        self.manifestSource = manifestSource
        // next step
        self.provider = firmwareProvider
        self.uploader = firmwareUploder

        subscribeToPublishers()
    }

    var hasManifest: LazyResult<Bool, Swift.Error> = .idle
    var currentRegion: LazyResult<ISOCode, Swift.Error> = .idle
    var provisionedRegion: LazyResult<ISOCode, Swift.Error> = .idle

    var hasSDCard: LazyResult<Bool, Swift.Error> {
        guard let storage = device.storageInfo else { return .working }
        return .success(storage.external != nil)
    }

    func subscribeToPublishers() {
        device.$flipper
            .receive(on: DispatchQueue.main)
            .assign(to: \.flipper, on: self)
            .store(in: &cancellables)

        device.$storageInfo
            .receive(on: DispatchQueue.main)
            .sink { _ in self.updateState() }
            .store(in: &cancellables)

        // device_info arrives after the connection settles, and the version
        // comes with $flipper. Either can be what finally names the firmware,
        // so both are watched: a flash to a different one has to send the card
        // to a different feed, or it keeps offering the previous firmware's
        // releases.
        device.$info
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.followInstalledFirmware() {
                    self.updateAvailableFirmware()
                }
            }
            .store(in: &cancellables)

        device.$flipper
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.followInstalledFirmware() {
                    self.updateAvailableFirmware()
                }
            }
            .store(in: &cancellables)
    }

    func onStateChanged(_ oldValue: State) {
        recordUpdateStateChanged(from: oldValue, to: state)
    }

    func onFlipperChanged(_ oldValue: Flipper?) {
        if flipper?.state == .disconnected {
            resetFlipperState()
        }

        if oldValue?.state != .connected, flipper?.state == .connected {
            updateInstalledManifest()
            updateProvisionedRegion()
            updateCurrentRegion()
            clearStaleUpdatingFrame()
        }

        switch state {
        case .update(.progress): break
        default: updateState()
        }
    }

    // A Flipper left showing the update frame by an older build of this app --
    // or by any version of it before the frame was ever released -- stays that
    // way across reconnects, because the virtual display belongs to the device,
    // not to the session that started it. Nothing else clears it, so a device
    // could sit stuck on "Update in progress" indefinitely.
    //
    // Only when no update is actually running: mid-update that frame is doing
    // its job.
    func clearStaleUpdatingFrame() {
        switch state {
        case .update: return
        default: break
        }
        Task { await releaseUpdatingFrame() }
    }

    func resetFlipperState() {
        hasManifest = .idle
        currentRegion = .idle
        provisionedRegion = .idle
    }

    public func startUpdate() {
        guard
            let installed = installed,
            let available = available
        else {
            return
        }
        intent = .init(from: installed, to: available)
        showUpdate = true
    }

    func updateInstalledManifest() {
        guard case .idle = hasManifest else { return }
        hasManifest = .working
        Task {
            do {
                let result = try await device.hasAssetsManifest()
                hasManifest = .success(result)
            } catch {
                logger.error("verify manifest: \(error)")
                hasManifest = .success(false)
            }
            updateState()
        }
    }

    func updateProvisionedRegion() {
        guard case .idle = provisionedRegion else { return }
        provisionedRegion = .working
        Task {
            do {
                let region = try await device.getRegion()
                provisionedRegion = .success(region.code)
            } catch {
                logger.error("verify region: \(error)")
                provisionedRegion = .failure(error)
            }
            updateState()
        }
    }

    func updateCurrentRegion() {
        guard case .idle = currentRegion else { return }
        currentRegion = .working
        Task {
            do {
                let region = try await Provisioning().provideRegion().code
                currentRegion = .success(region)
            } catch {
                logger.error("check region change: \(error)")
                currentRegion = .failure(error)
            }
            updateState()
        }
    }

    // Point the feed at whatever firmware the device is running, before asking
    // it anything. Returns true when the stream changed, so a stale manifest
    // from the previous firmware can be dropped rather than shown for the
    // moment it takes the new one to arrive.
    // What the device says it is running, by fork if it reports one and by the
    // shape of its version otherwise.
    public var installedFirmware: FirmwareIdentity? {
        FirmwareIdentity.identify(
            fork: device.info.keys["firmware_origin_fork"],
            version: device.flipper?.information?.firmwareVersion?.name)
    }

    @discardableResult
    func followInstalledFirmware() -> Bool {
        guard let url = installedFirmware?.manifestURL else {
            // A fork with no directory.json of its own. Leave the feed where it
            // is rather than pointing it at somebody else's releases; the card
            // reports what it has and offers no update it cannot justify.
            return false
        }
        guard url != FirmwareFeed.current else { return false }
        FirmwareFeed.current = url
        manifest = nil
        customIsSameFirmware = false
        return true
    }

    public func updateAvailableFirmware() {
        followInstalledFirmware()
        switch state {
        case .update(.progress): return
        case .update(.result(.started)): return
        case .error(.noInternet): return
        default: break
        }
        state = .loading
        Task {
            do {
                manifest = try await manifestSource.manifest(for: .f7)
                updateState()
            } catch {
                state = .error(.cantConnect)
                logger.error("download manifest: \(error)")
            }
        }
    }

    func updateState() {
        guard validateFlipperState() else { return }
        guard validateSDCard() else { return }

        guard validateInstalledFirmware() else { return }
        guard validateUpdateResult() else { return }
        guard validateAvailableFirmware() else { return }

        guard checkChannelUpdate() else { return }
        guard checkVersionUpdate() else { return }

        guard checkManifestUpdate() else { return }
        guard checkRegionUpdate() else { return }

        state = .ready(.noUpdates)
    }

    func validateFlipperState() -> Bool {
        guard let flipper = flipper else { return false }

        switch flipper.state {
        case .connected:
            return true
        case .connecting:
            switch state {
            case .error(.noCard), .update(.result(.started)):
                return false
            default:
                state = .loading
                return false
            }
        default:
            switch state {
            case .update(.result(.started)):
                return false
            default:
                state = .error(.noDevice)
                return false
            }
        }
    }

    func validateSDCard() -> Bool {
        guard case .success(let hasSDCard) = hasSDCard else {
            return false
        }
        guard hasSDCard else {
            state = .error(.noCard)
            return false
        }
        return true
    }

    func validateInstalledFirmware() -> Bool {
        installed != nil
    }

    func validateUpdateResult() -> Bool {
        guard
            let intent = intent,
            let installed = installed,
            case .update(.result(.started)) = state
        else {
            return true
        }
        switch intent.desiredVersion == installed {
        case true: state = .update(.result(.succeeded))
        case false: state = .update(.result(.failed))
        }
        return false
    }

    func validateAvailableFirmware() -> Bool {
        guard available == nil else { return true }

        // No build on this channel, but the feed itself was readable -- say so
        // rather than leaving the card spinning on `loading` forever.
        if manifest != nil, updateChannel != .custom {
            state = .error(.noReleases)
        }
        return false
    }

    func checkManifestUpdate() -> Bool {
        guard case .success(let hasManifest) = hasManifest else {
            return false
        }
        guard hasManifest else {
            state = .ready(.versionUpdate)
            return false
        }
        return true
    }

    func checkRegionUpdate() -> Bool {
        guard
            case .success(let provisionedRegionCode) = provisionedRegion,
            case .success(let currentRegionCode) = currentRegion,
            currentRegionCode == provisionedRegionCode
        else {
            state = .ready(.versionUpdate)
            return false
        }
        return true
    }

    func checkChannelUpdate() -> Bool {
        guard let installed = installed else {
            return false
        }
        guard installed.channel == updateChannel else {
            // Changing firmware is an install; taking a newer build of the one
            // already on the device is an update, whichever channel carries it.
            state = .ready(
                updateChannel == .custom && customIsSameFirmware
                    ? .versionUpdate
                    : .channelUpdate)
            return false
        }
        return true
    }

    func checkVersionUpdate() -> Bool {
        guard
            let installed = installed,
            let available = available
        else {
            return false
        }
        guard installed == available else {
            state = .ready(.versionUpdate)
            return false
        }
        return true
    }

    // MARK: Update

    private var updateTaskHandle: Task<Void, Swift.Error>?

    public func install(_ firmware: Update.Firmware) {
        guard updateTaskHandle == nil else {
            logger.error("update in progress")
            return
        }
        updateTaskHandle = Task {
            // Once the device has been told to reboot into the updater it is
            // gone, and the frame goes with it. Any other way out of here
            // leaves the Flipper still running, still showing the frame put up
            // by prepareForUpdate().
            var rebooted = false
            do {
                let bytes = try await downloadFirmware(firmware.url)
                let bundle = try await UpdateBundle(unpacking: bytes)

                try await prepareForUpdate()
                try await provideRegion()
                let path = try await uploadFirmware(bundle)
                try await startUpdateProcess(path)
                rebooted = true
            } catch {
                handleInstallError(error)
                logger.error("update: \(error)")
            }
            if !rebooted {
                await releaseUpdatingFrame()
            }
            updateTaskHandle = nil
        }
    }

    // Take the Flipper's screen back.
    //
    // showUpdatingFrame() starts a *virtual display*: the phone drives what the
    // Flipper shows, and the Flipper keeps showing it until told to stop.
    // hideUpdatingFrame() existed to do that and was never once called, so any
    // update that did not reach the reboot -- a failed download, no SD card, a
    // cancel -- left the device frozen on "Update in progress" with no way back
    // but a reboot. Remote Control mirrors that same screen, which is where it
    // was seen.
    private func releaseUpdatingFrame() async {
        do {
            try await device.hideUpdatingFrame()
        } catch {
            // The device may already be gone, which is fine: the frame goes
            // with it. Worth a line, never worth failing over.
            logger.debug("release updating frame: \(error)")
        }
    }

    private func handleInstallError(_ error: Swift.Error) {
        switch error {
        case _ as URLError:
            state = .error(.cantConnect)
        case let error as Peripheral.Error
            where error == .storage(.internal):
            state = .error(.noCard)
        default:
            state = .error(.noDevice)
        }
    }

    public func cancel() {
        Task {
            state = .update(.result(.canceled))
            // Before restarting the session, not after: the restart drops the
            // RPC this has to travel over.
            await releaseUpdatingFrame()
            device.restartSession()
        }
    }

    private func prepareForUpdate() async throws {
        state = .update(.progress(.preparing))
        try await device.showUpdatingFrame()
    }

    private func provideRegion() async throws {
        state = .update(.progress(.preparing))
        try await device.provideSubGHzRegion()
    }

    private func downloadFirmware(_ url: URL) async throws -> [UInt8] {
        state = .update(.progress(.downloading(0)))
        return try await provider.data(from: url) { progress in
            if case .update(.progress) = self.state {
                Task { @MainActor in
                    self.state = .update(.progress(.downloading(progress)))
                }
            }
        }
    }

    private func uploadFirmware(
        _ bundle: UpdateBundle
    ) async throws -> Peripheral.Path {
        state = .update(.progress(.preparing))
        return try await uploader.upload(bundle) { progress in
            if case .update(.progress) = self.state {
                Task { @MainActor in
                    self.state = .update(.progress(.uploading(progress)))
                }
            }
        }
    }

    private func startUpdateProcess(
        _ directory: Peripheral.Path
    ) async throws {
        state = .update(.progress(.preparing))
        try await device.startUpdateProcess(from: directory)
        state = .update(.result(.started))
    }
}

private extension Update.Intent {
    init(from: Update.Version, to: Update.Version) {
        id = Int(Date().timeIntervalSince1970)
        currentVersion = from
        desiredVersion = to
    }
}

private extension Update.Channel {
    static func load() -> Self {
        UserDefaultsStorage.shared.updateChannel
    }

    func save() {
        UserDefaultsStorage.shared.updateChannel = self
    }
}

// MARK: Analytics

import enum Analytics.UpdateResult

extension UpdateModel {
    func recordUpdateStateChanged(from oldValue: State, to newValue: State) {
        guard let intent = intent else {
            return
        }

        switch (oldValue, newValue) {

        case (.ready, .update(.progress(.downloading))):
            recordUpdateStarted(intent: intent)

        case (.update(.result(.started)), .update(.result(.succeeded))):
            recordUpdateSuccessed(intent: intent)

        case (.update(.result(.started)), .update(.result(.failed))):
            recordUpdateFailed(intent: intent)

        case (.update(.progress), .update(.result(.canceled))):
            recordUpdateCanceled(intent: intent)

        case (.update(.progress), .error(let error)):
            recordUpdateError(intent: intent, error: error)

        default:
            break
        }
    }

    func recordUpdateStarted(intent: Update.Intent) {
        analytics.flipperUpdateStart(
            id: intent.id,
            from: intent.currentVersion.description,
            to: intent.desiredVersion.description)
    }

    func recordUpdateSuccessed(intent: Update.Intent) {
        analytics.flipperUpdateResult(
            id: intent.id,
            from: intent.currentVersion.description,
            to: intent.desiredVersion.description,
            status: .completed)
    }

    func recordUpdateCanceled(intent: Update.Intent) {
        analytics.flipperUpdateResult(
            id: intent.id,
            from: intent.currentVersion.description,
            to: intent.desiredVersion.description,
            status: .canceled)
    }

    func recordUpdateError(
        intent: Update.Intent,
        error: State.Error
    ) {
        let result: Analytics.UpdateResult
        switch error {
        // noReleases cannot arise mid-update (an update in flight already has
        // a firmware), but it is a download-side problem if it ever does.
        case .cantConnect, .noInternet, .noReleases: result = .failedDownload
        case .noCard, .noDevice: result = .failedUpload
        }
        analytics.flipperUpdateResult(
            id: intent.id,
            from: intent.currentVersion.description,
            to: intent.desiredVersion.description,
            status: result)
    }

    func recordUpdateFailed(intent: Update.Intent) {
        analytics.flipperUpdateResult(
            id: intent.id,
            from: intent.currentVersion.description,
            to: intent.desiredVersion.description,
            status: .failed)
    }
}
