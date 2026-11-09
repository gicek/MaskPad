import Foundation
import IOKit.ps
import SwiftUI

/// Date, time and battery shown in the top-right corner of the mask.
/// Formatting follows the language MaskPad is running in, with the system region's conventions
/// (e.g. 12/24-hour clock).
struct MaskStatusBar: View {
    var body: some View {
        HStack(spacing: 22) {
            TimelineView(.everyMinute) { context in
                HStack(spacing: 10) {
                    Text(context.date, format: Self.dateFormat)
                    Text(context.date, format: Self.timeFormat)
                }
            }
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if let battery = BatteryStatus.current() {
                    HStack(spacing: 6) {
                        Image(systemName: battery.symbolName)
                            .font(.system(size: 17, weight: .regular))
                        Text(Double(battery.level) / 100, format: .percent.locale(Self.locale))
                    }
                    .foregroundStyle(battery.isLow ? Color(red: 1, green: 0.27, blue: 0.23) : .white.opacity(0.75))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .font(.system(size: 15, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.75))
    }

    /// The app's localization language combined with the system region.
    static let locale: Locale = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        guard let region = Locale.current.region?.identifier else { return Locale(identifier: language) }
        return Locale(identifier: "\(language)_\(region)")
    }()

    private static let dateFormat = Date.FormatStyle(locale: locale)
        .weekday(.abbreviated).month(.abbreviated).day()
    private static let timeFormat = Date.FormatStyle(locale: locale).hour().minute()
}

/// Internal battery state from IOKit power sources; nil on Macs without a battery.
struct BatteryStatus: Equatable {
    var level: Int
    var isCharging: Bool
    var isOnPower: Bool

    static func current() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = description[kIOPSMaxCapacityKey] as? Int, maxCapacity > 0
            else { continue }
            return BatteryStatus(
                level: min(100, max(0, capacity * 100 / maxCapacity)),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isOnPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            )
        }
        return nil
    }

    /// Below 20 % and not on power: shown in red as a warning.
    var isLow: Bool { level < 20 && isCharging == false && isOnPower == false }

    /// SF Symbol for the level. Only the full battery has a bolt variant, so charging or on power
    /// always shows it; the percentage carries the level.
    var symbolName: String {
        if isCharging || isOnPower { return "battery.100percent.bolt" }
        let fill = switch level {
        case 88...: "100"
        case 63..<88: "75"
        case 38..<63: "50"
        case 13..<38: "25"
        default: "0"
        }
        return "battery.\(fill)percent"
    }
}
