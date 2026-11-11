import Network
import Testing
@testable import MaskPad

struct BatteryStatusTests {
    @Test func symbolFollowsLevel() {
        #expect(BatteryStatus(level: 95, isCharging: false, isOnPower: false).symbolName == "battery.100percent")
        #expect(BatteryStatus(level: 70, isCharging: false, isOnPower: false).symbolName == "battery.75percent")
        #expect(BatteryStatus(level: 50, isCharging: false, isOnPower: false).symbolName == "battery.50percent")
        #expect(BatteryStatus(level: 20, isCharging: false, isOnPower: false).symbolName == "battery.25percent")
        #expect(BatteryStatus(level: 5, isCharging: false, isOnPower: false).symbolName == "battery.0percent")
    }

    /// Only the full battery has a bolt variant, so charging or on power always uses it.
    @Test func chargingOrOnPowerShowsBolt() {
        #expect(BatteryStatus(level: 30, isCharging: true, isOnPower: true).symbolName == "battery.100percent.bolt")
        #expect(BatteryStatus(level: 100, isCharging: false, isOnPower: true).symbolName == "battery.100percent.bolt")
    }

    /// Below 20 % on battery is low; charging or on power never is.
    @Test func lowBatteryWarning() {
        #expect(BatteryStatus(level: 19, isCharging: false, isOnPower: false).isLow)
        #expect(BatteryStatus(level: 20, isCharging: false, isOnPower: false).isLow == false)
        #expect(BatteryStatus(level: 10, isCharging: true, isOnPower: true).isLow == false)
        #expect(BatteryStatus(level: 10, isCharging: false, isOnPower: true).isLow == false)
    }
}

struct NetworkStatusTests {
    @Test func realInterfaceOnSatisfiedPathIsConnected() {
        #expect(NetworkStatus.isConnected(isSatisfied: true, interfaces: [.wifi]))
        #expect(NetworkStatus.isConnected(isSatisfied: true, interfaces: [.other, .wiredEthernet]))
    }

    @Test func unsatisfiedPathIsOffline() {
        #expect(NetworkStatus.isConnected(isSatisfied: false, interfaces: [.wifi]) == false)
        #expect(NetworkStatus.isConnected(isSatisfied: false, interfaces: []) == false)
    }

    /// A VPN or proxy app keeps its tunnel up as the default route after Wi-Fi is turned off, and the
    /// system still reports the path as satisfied.
    @Test func tunnelAloneIsOffline() {
        #expect(NetworkStatus.isConnected(isSatisfied: true, interfaces: [.other, .other]) == false)
        #expect(NetworkStatus.isConnected(isSatisfied: true, interfaces: [.loopback]) == false)
    }
}
