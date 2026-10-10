import Foundation
import Network

public struct NetworkStatus: Sendable, Equatable {
    public var isConnected: Bool
    public var isExpensive: Bool
    public var isConstrained: Bool
    public init(isConnected: Bool, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.isConnected = isConnected; self.isExpensive = isExpensive; self.isConstrained = isConstrained
    }
    public static let online = NetworkStatus(isConnected: true)
    public static let offline = NetworkStatus(isConnected: false)
}

public protocol NetworkMonitoring: Sendable {
    func status() -> NetworkStatus
}

public protocol DiskSpaceProviding: Sendable {
    /// Bytes available for important (user-initiated) work on the volume holding `url`; nil if unknown.
    func availableBytes(at url: URL) -> Int64?
}

public protocol DeviceConditions: Sendable {
    var thermalState: ProcessInfo.ThermalState { get }
    var isLowPowerModeEnabled: Bool { get }
}

/// `NWPathMonitor`-backed reachability. Until the first path arrives the network is assumed available, so a slow
/// monitor start never blocks work (a real outage then surfaces as a classified error and a wait).
public final class SystemNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var current = NetworkStatus.online

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let s = NetworkStatus(isConnected: path.status == .satisfied, isExpensive: path.isExpensive,
                                  isConstrained: path.isConstrained)
            self.lock.lock(); self.current = s; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "pare.network"))
    }

    deinit { monitor.cancel() }

    public func status() -> NetworkStatus { lock.lock(); defer { lock.unlock() }; return current }
}

public struct SystemDiskSpace: DiskSpaceProviding {
    public init() {}
    public func availableBytes(at url: URL) -> Int64? {
        var probe = url
        // The directory may not exist yet; ask about the nearest existing ancestor on the same volume.
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }
}

public struct SystemDeviceConditions: DeviceConditions {
    public init() {}
    public var thermalState: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
    public var isLowPowerModeEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}
