import os

/// Runtime logs: `/usr/bin/log show --predicate 'subsystem == "com.gicek.maskpad"'`.
/// Only mask on/off, real screen-lock detection, and hotkey registration failures are logged; never keystroke content.
enum Log {
    static let hotKey = Logger(subsystem: "com.gicek.maskpad", category: "hotkey")
    static let mask = Logger(subsystem: "com.gicek.maskpad", category: "mask")
}
