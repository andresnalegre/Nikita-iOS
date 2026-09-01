import Combine
import CoreBluetooth

class FlipperCentral: NSObject, BluetoothCentral {
    private lazy var manager: CBCentralManager = {
        let manager = CBCentralManager()
        manager.delegate = self
        return manager
    }()

    private var serviceKey: String {
        "kCBAdvDataServiceUUIDs"
    }
    private var flipperServiceIDs: [CBUUID] {
        [
            .flipperZerof6,
            .flipperZeroBlack,
            .flipperZeroWhite,
            .flipperZeroClear
        ]
    }

    // cache to preserve flipper color
    private var services: [UUID: CBUUID] = [:]

    // Scanning is requested before Bluetooth reports itself ready more often
    // than not -- the user is already on the pairing screen when the radio
    // finishes waking up -- so the request is remembered and honoured then.
    private var wantsScan = false

    override init() {
        super.init()
        // Bring CoreBluetooth up now, rather than on first use.
        //
        // `manager` is lazy, and the only startup path that touched it was
        // inside startScanForPeripherals()'s `poweredOn` check -- a state that
        // cannot change until centralManagerDidUpdateState fires, which cannot
        // fire until the manager exists. On a fresh install, with no saved
        // device to connect to, nothing ever broke that circle: the scan
        // no-opped forever, no device was ever discovered, and iOS never even
        // asked for Bluetooth permission, because nothing had asked for
        // Bluetooth. Installs that carried a saved device hid it, since
        // connect() reaches the manager directly.
        _ = manager
    }

    // MARK: BluetoothCentral & BluetoothConnector

    var status: AnyPublisher<BluetoothStatus, Never> {
        _status.eraseToAnyPublisher()
    }
    let _status: CurrentValueSubject<BluetoothStatus, Never> = {
        .init(.unknown)
    }()

    // MARK: BluetoothCentral

    var discovered: AnyPublisher<[BluetoothPeripheral], Never> {
        _discovered.eraseToAnyPublisher()
    }
    let _discovered: CurrentValueSubject<[BluetoothPeripheral], Never> = {
        .init([])
    }()

    func startScanForPeripherals() {
        wantsScan = true
        if _status.value == .poweredOn {
            manager.scanForPeripherals(withServices: flipperServiceIDs)
        }
    }

    func stopScanForPeripherals() {
        wantsScan = false
        if manager.isScanning {
            manager.stopScan()
            _discovered.value.removeAll()
        }
    }

    // MARK: BluetoothConnector

    var connected: AnyPublisher<[BluetoothPeripheral], Never> {
        _connected.eraseToAnyPublisher()
    }
    let _connected: CurrentValueSubject<[BluetoothPeripheral], Never> = {
        .init([])
    }()

    func connect(to id: UUID) {
        guard let peripheral = manager.retrievePeripheral(id) else {
            return
        }
        let device = FlipperPeripheral(
            peripheral: peripheral,
            service: services[id])
        device.onConnecting()
        _connected[id] = device
        manager.connect(peripheral)
    }

    func disconnect(from identifier: UUID) {
        if let peripheral = manager.retrievePeripheral(identifier) {
            manager.cancelPeripheralConnection(peripheral)
        }
    }

    func didConnect(_ peripheral: CBPeripheral) {
        if let peripheral = _connected[peripheral.identifier] {
            peripheral.onConnect()
            _connected[peripheral.id] = peripheral
        }
    }

    func didDisconnect(_ peripheral: CBPeripheral, error: Swift.Error?) {
        if let peripheral = _connected[peripheral.identifier] {
            peripheral.onDisconnect()
            _connected[peripheral.id] = nil
        }
    }

    func didFailToConnect(_ peripheral: CBPeripheral, error: Swift.Error?) {
        if let device = _connected[peripheral.identifier], let error = error {
            device.onError(error)
            _connected[device.id] = nil
        }
    }
}

// MARK: BluetoothCentral

extension FlipperCentral: CBCentralManagerDelegate {

    // MARK: Status changed

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        _status.value = .init(manager.state)
        if manager.state == .poweredOn, wantsScan, !manager.isScanning {
            // Asked for before the radio was ready; start it now.
            manager.scanForPeripherals(withServices: flipperServiceIDs)
        }
        if manager.state != .poweredOn {
            _discovered.value.removeAll()

            _connected.value.forEach { $0.onDisconnect() }
            _connected.value.removeAll()
        }
    }

    // MARK: Did discover

    func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        let service = (advertisementData[serviceKey] as? [CBUUID])?.first
        if _discovered[peripheral.identifier] == nil {
            services[peripheral.identifier] = service
            _discovered[peripheral.identifier] = FlipperPeripheral(
                peripheral: peripheral,
                service: service)
        }
    }
}

// MARK: BluetoothConnector

extension FlipperCentral {

    // MARK: Connection status changed

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        didConnect(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Swift.Error?
    ) {
        didDisconnect(peripheral, error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Swift.Error?
    ) {
        didFailToConnect(peripheral, error: error)
    }
}

fileprivate extension BluetoothStatus {
    init(_ source: CBManagerState) {
        self = BluetoothStatus(rawValue: source.rawValue) ?? .unknown
    }
}

extension Array where Element == BluetoothPeripheral {
    subscript(_ id: UUID) -> Element? {
        get {
            first { $0.id == id }
        }
        set {
            if let index = firstIndex(where: { $0.id == id }) {
                if let newValue = newValue {
                    self[index] = newValue
                } else {
                    remove(at: index)
                }
            } else {
                if let newValue = newValue {
                    append(newValue)
                }
            }
        }
    }
}

extension CurrentValueSubject where Output == [BluetoothPeripheral] {
    subscript(_ id: UUID) -> Output.Element? {
        get { self.value[id] }
        set { self.value[id] = newValue }
    }
}
