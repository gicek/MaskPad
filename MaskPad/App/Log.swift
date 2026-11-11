import os

/// Runtime logs: `/usr/bin/log show --predicate 'subsystem == "com.gicek.maskpad"'`.
/// Only mask on/off, real screen-lock detection, hotkey registration failures, postponed update relaunches
/// and checks, ignored mask button presses, the network going offline or coming back while masked, and `maskpad://`
/// commands are logged; never keystroke content.
enum Log {
    static let command = Logger(subsystem: "com.gicek.maskpad", category: "command")
    static let hotKey = Logger(subsystem: "com.gicek.maskpad", category: "hotkey")
    static let mask = Logger(subsystem: "com.gicek.maskpad", category: "mask")
    static let update = Logger(subsystem: "com.gicek.maskpad", category: "update")
}
