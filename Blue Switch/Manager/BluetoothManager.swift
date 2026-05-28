import CoreBluetooth

/// Protocol defining the interface for Bluetooth management
protocol BluetoothManaging {
  /// Initializes and sets up the Bluetooth manager
  func setup()

  /// Current state of the Bluetooth manager
  var state: CBManagerState { get }
}

/// Publishes the live `CBManagerState`. Other components subscribe via
/// `@Published var state` (Combine) to react to powerOff / unauthorized
/// transitions and surface them to the user.
final class BluetoothManager: NSObject, ObservableObject, BluetoothManaging {
  // MARK: - Singleton

  static let shared = BluetoothManager()

  // MARK: - Properties

  @Published private(set) var state: CBManagerState = .unknown

  private var centralManager: CBCentralManager?

  // MARK: - Initialization

  private override init() {
    super.init()
  }

  // MARK: - BluetoothManaging Implementation

  func setup() {
    centralManager = CBCentralManager(
      delegate: self,
      queue: DispatchQueue(label: "com.blueswitch.bluetooth", qos: .userInitiated)
    )
  }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    // CB delegate callbacks fire on the queue we passed to the initializer;
    // hop to main before publishing so subscribers (typically UI) don't see
    // mutations from a background thread.
    DispatchQueue.main.async { [weak self] in
      self?.state = central.state
    }
  }
}
