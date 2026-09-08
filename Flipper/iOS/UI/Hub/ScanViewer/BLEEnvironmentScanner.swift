import CoreBluetooth
import SwiftUI

// Scans the phone's BLE surroundings and classifies what it hears. This is the
// half of the Scan Viewer that CAN name a TV or a console: a USB fingerprint
// only sees an OS's enumeration behaviour, but a smart TV / console / speaker
// that advertises BLE gives away its name, its GATT services and (for Apple
// gear) its manufacturer data. Runs its own CBCentralManager so it never
// disturbs the Flipper connection the app already holds.
//
// Robust by construction: every CBManagerState is surfaced, discoveries are
// de-duplicated and RSSI-updated in place, and the scan stops itself on
// disappear so it never drains the radio in the background.
@MainActor
final class BLEEnvironmentScanner: NSObject, ObservableObject {
    struct Device: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
        var category: Category
        var serviceUUIDs: [String]
        var lastSeen: Date
    }

    enum Category: String {
        case tv = "TV"
        case console = "Console"
        case phone = "Phone"
        case computer = "Computer"
        case audio = "Audio"
        case wearable = "Wearable"
        case accessory = "Accessory"
        case beacon = "Beacon"
        case unknown = "Unknown"

        var icon: String {
            switch self {
            case .tv: return "tv"
            case .console: return "gamecontroller"
            case .phone: return "iphone"
            case .computer: return "laptopcomputer"
            case .audio: return "hifispeaker"
            case .wearable: return "applewatch"
            case .accessory: return "keyboard"
            case .beacon: return "dot.radiowaves.right"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    enum State: Equatable {
        case idle, scanning, poweredOff, unauthorized, unsupported
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var state: State = .idle

    private var central: CBCentralManager?
    private var seen: [UUID: Device] = [:]
    private var pruneTimer: Timer?

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            beginScanIfReady()
        }
        // Drop devices we have not heard from in a while so the list reflects
        // what is actually around right now.
        pruneTimer?.invalidate()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
    }

    func stop() {
        central?.stopScan()
        pruneTimer?.invalidate()
        pruneTimer = nil
        if state == .scanning { state = .idle }
    }

    func clear() {
        seen.removeAll()
        devices = []
    }

    private func beginScanIfReady() {
        guard let central, central.state == .poweredOn else { return }
        state = .scanning
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-10)
        for (id, dev) in seen where dev.lastSeen < cutoff {
            seen[id] = nil
        }
        publish()
    }

    private func publish() {
        devices = seen.values.sorted { $0.rssi > $1.rssi }
    }
}

extension BLEEnvironmentScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: beginScanIfReady()
            case .poweredOff: state = .poweredOff
            case .unauthorized: state = .unauthorized
            case .unsupported: state = .unsupported
            default: state = .idle
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Snapshot the ad on the delegate's thread, then hand plain values to the
        // main actor -- CBPeripheral is not Sendable.
        let id = peripheral.identifier
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey]
            as? String) ?? peripheral.name ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey]
            as? [CBUUID])?.map { $0.uuidString } ?? []
        let hasAppleMfg: Bool = {
            guard let d = advertisementData[CBAdvertisementDataManufacturerDataKey]
                as? Data, d.count >= 2 else { return false }
            return d[0] == 0x4C && d[1] == 0x00 // 0x004C little-endian = Apple
        }()
        let rssi = RSSI.intValue
        Task { @MainActor in
            self.ingest(id: id, name: advName, services: services,
                        hasAppleMfg: hasAppleMfg, rssi: rssi)
        }
    }

    @MainActor
    private func ingest(
        id: UUID, name: String, services: [String],
        hasAppleMfg: Bool, rssi: Int
    ) {
        // -127 is CoreBluetooth's "no reading"; skip so it never tops the list.
        guard rssi != 127, rssi != -127 else { return }
        let display = name.isEmpty ? "(unnamed)" : name
        let category = Self.classify(
            name: name, services: services, hasAppleMfg: hasAppleMfg)
        // Keep the best name we have ever seen for this id (ads alternate
        // between named and unnamed packets).
        var existingName = seen[id]?.name
        if existingName == nil || existingName == "(unnamed)" {
            existingName = display
        } else if !name.isEmpty {
            existingName = display
        }
        seen[id] = Device(
            id: id, name: existingName ?? display, rssi: rssi,
            category: category == .unknown ? (seen[id]?.category ?? .unknown)
                : category,
            serviceUUIDs: services.isEmpty ? (seen[id]?.serviceUUIDs ?? [])
                : services,
            lastSeen: Date())
        publish()
    }

    // Best-effort category from the advertised name, GATT services and Apple
    // manufacturer data. Name patterns win because they are the most specific.
    static func classify(name: String, services: [String], hasAppleMfg: Bool)
        -> Category {
        let n = name.lowercased()
        let has: (String) -> Bool = { n.contains($0) }

        if has("tv") || has("bravia") || has("webos") || has("tizen")
            || has("roku") || has("chromecast") || has("firetv")
            || has("fire tv") || has("shield") || has("vizio")
            || has("samsung") && has("q") { return .tv }
        if has("ps5") || has("ps4") || has("dualsense") || has("dualshock")
            || has("xbox") || has("switch") || has("pro controller")
            || has("joy-con") || has("joycon") { return .console }
        if has("iphone") || has("android") || has("pixel")
            || has("galaxy") && !has("buds") || has("redmi") { return .phone }
        if has("macbook") || has("imac") || has("laptop") || has("pc")
            || has("desktop") { return .computer }
        if has("airpods") || has("buds") || has("headphone") || has("speaker")
            || has("soundbar") || has("bose") || has("jbl") || has("sony wh")
            || has("beats") { return .audio }
        if has("watch") || has("band") || has("fit") || has("garmin")
            || has("whoop") { return .wearable }
        if has("keyboard") || has("mouse") || has("magic ") { return .accessory }

        // Service-UUID fallbacks (16-bit assigned numbers).
        let svc = Set(services.map { $0.uppercased() })
        func any(_ ids: String...) -> Bool { ids.contains { svc.contains($0) } }
        if any("110B", "111E", "1108", "110A", "1203") { return .audio }
        if any("1812") { return .accessory } // HID: keyboard/remote/controller
        if any("FEAA", "FEAB", "FDCF") { return .beacon } // Eddystone / beacons
        if hasAppleMfg { return .accessory } // Apple gear, type unclear

        return .unknown
    }
}
