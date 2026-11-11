import Combine
import Network

/// Whether the Mac has lost its network connection, for the mask's status bar.
///
/// What runs under the mask (downloads, remote sessions, agents) mostly needs the network, and losing it
/// is the commonest way a task stops unnoticed. The status bar shows it only when it happens; a working
/// connection shows nothing, and the network's name is never shown.
///
/// "Offline" means no usable network path (`NWPathMonitor`) over Wi‑Fi, Ethernet or cellular, not that
/// a particular server is unreachable. A path that only has virtual interfaces doesn't count: VPN and
/// proxy apps keep a tunnel interface (utun) up as the default route after Wi‑Fi is turned off, and the
/// system still calls that path satisfied. It is reported only after `offlineDelay` without a connection, so a Wi‑Fi roam or the
/// moment after waking doesn't flash the warning; reconnecting clears it at once.
@MainActor
final class NetworkStatus: ObservableObject {
    static let offlineDelay: Duration = .seconds(5)

    @Published private(set) var isOffline = false

    private let monitor = NWPathMonitor()
    private var pendingOffline: Task<Void, Never>?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isConnected = Self.isConnected(
                isSatisfied: path.status == .satisfied, interfaces: path.availableInterfaces.map(\.type)
            )
            // Delivered on the main queue (see `start`).
            MainActor.assumeIsolated { self?.update(isConnected: isConnected) }
        }
        monitor.start(queue: .main)
    }

    /// Pure rule, for tests: a satisfied path with at least one real interface.
    nonisolated static func isConnected(isSatisfied: Bool, interfaces: [NWInterface.InterfaceType]) -> Bool {
        isSatisfied && interfaces.contains { $0 == .wifi || $0 == .wiredEthernet || $0 == .cellular }
    }

    deinit {
        monitor.cancel()
    }

    private func update(isConnected: Bool) {
        if isConnected {
            pendingOffline?.cancel()
            pendingOffline = nil
            if isOffline { Log.mask.notice("network: back online") }
            isOffline = false
        } else if isOffline == false, pendingOffline == nil {
            pendingOffline = Task { [weak self] in
                try? await Task.sleep(for: Self.offlineDelay)
                guard Task.isCancelled == false else { return }
                self?.pendingOffline = nil
                self?.isOffline = true
                Log.mask.notice("network: offline")
            }
        }
    }
}
