import Darwin
import AppKit
import Foundation

// Integration smoke test against a built Debug app. Every process uses a fresh, disposable identity;
// no real passcode, permissions, preferences, or installed application is changed.
var fixtureIdentity: String?
func stopFixture() {
    guard let identity = fixtureIdentity else { return }
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: identity) {
        kill(app.processIdentifier, SIGCONT)
        app.terminate()
    }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, !NSRunningApplication.runningApplications(withBundleIdentifier: identity).isEmpty {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { stopFixture(); fputs("FAIL: \(message)\n", stderr); exit(1) }
}
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: xcrun swift Scripts/verify_single_instance.swift <Debug.app> <artifact-directory>\n", stderr)
    exit(2)
}
let fm = FileManager.default
let original = URL(fileURLWithPath: CommandLine.arguments[1])
require(Bundle(url: original)?.bundleIdentifier == "com.gicek.maskpad.debug", "input must be the Debug build")
let root = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(UUID().uuidString)
let identity = "com.gicek.maskpad.instancetest." + UUID().uuidString.lowercased()
fixtureIdentity = identity
try fm.createDirectory(at: root, withIntermediateDirectories: true)
let first = root.appendingPathComponent("Primary.app")
let second = root.appendingPathComponent("OtherCopy.app")
try fm.copyItem(at: original, to: first)
let plist = first.appendingPathComponent("Contents/Info.plist")
var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
info["CFBundleIdentifier"] = identity
info["CFBundleName"] = "MaskPad Instance Test"
info["MaskPadURLScheme"] = "maskpad-instance-test"
info["CFBundleURLTypes"] = [["CFBundleURLName": identity, "CFBundleURLSchemes": ["maskpad-instance-test"]]]
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
sign.arguments = ["--force", "--deep", "--sign", "-", first.path]
try sign.run(); sign.waitUntilExit(); require(sign.terminationStatus == 0, "fixture signing")
try fm.copyItem(at: first, to: second)
let executable = "Contents/MacOS/MaskPad"
let owner = Process(); owner.executableURL = first.appendingPathComponent(executable)
try owner.run()
func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 15) -> Bool {
    let until = Date().addingTimeInterval(timeout)
    while Date() < until {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
}
require(waitFor { NSRunningApplication(processIdentifier: owner.processIdentifier)?.isFinishedLaunching == true }, "primary ready")
let clients = try (0..<8).map { _ -> Process in
    let p = Process(); p.executableURL = second.appendingPathComponent(executable); try p.run(); return p
}
require(waitFor { clients.allSatisfy { !$0.isRunning } }, "concurrent duplicates exit")
require(clients.allSatisfy { $0.terminationStatus == 0 }, "duplicates exit successfully")
require(owner.isRunning, "owner survives duplicates")
// Stop the owner to prove a client can finish before the owner consumes its queued URL.
require(kill(owner.processIdentifier, SIGSTOP) == 0, "pause fixture owner")
let replyID = UUID().uuidString
var result: String?
let observation = DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name(identity + ".commandReply"), object: replyID, queue: .main
) { note in result = note.userInfo?["result"] as? String }
let config = NSWorkspace.OpenConfiguration()
config.createsNewApplicationInstance = true
config.activates = false
var openError: Error?
var launchCompleted = false
NSWorkspace.shared.open([URL(string: "maskpad-instance-test://status?reply=\(replyID)")!],
                        withApplicationAt: second, configuration: config) { _, error in openError = error; launchCompleted = true }
require(waitFor { launchCompleted }, "URL client launch finishes")
require(waitFor { NSRunningApplication.runningApplications(withBundleIdentifier: identity).count == 1 || openError != nil }, "URL client exits while owner is paused")
require(kill(owner.processIdentifier, SIGCONT) == 0, "resume fixture owner")
require(waitFor { result != nil || openError != nil }, "URL forwarded from another copy")
require(openError == nil && result == "off", "URL reply is off")
DistributedNotificationCenter.default().removeObserver(observation)
let link = root.appendingPathComponent("maskpad")
try fm.createSymbolicLink(at: link, withDestinationURL: second.appendingPathComponent(executable))
let cli = Process(); let output = Pipe()
cli.executableURL = link; cli.arguments = ["status"]; cli.standardOutput = output
try cli.run()
require(waitFor { !cli.isRunning }, "symlink CLI answered")
require(cli.terminationStatus == 0, "symlink CLI success")
require(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == "off\n", "symlink CLI off")
require(waitFor { NSRunningApplication.runningApplications(withBundleIdentifier: identity).count == 1 }, "only owner remains")
NSRunningApplication(processIdentifier: owner.processIdentifier)?.terminate()
require(waitFor { !owner.isRunning }, "fixture quits gracefully")
let relaunch = Process(); relaunch.executableURL = second.appendingPathComponent(executable)
try relaunch.run()
require(waitFor { NSRunningApplication(processIdentifier: relaunch.processIdentifier)?.isFinishedLaunching == true }, "relaunch takes released lock")
NSRunningApplication(processIdentifier: relaunch.processIdentifier)?.terminate()
require(waitFor { !relaunch.isRunning }, "relaunch quits gracefully")
print("PASS: 8 concurrent duplicates, paused-owner cross-copy URL handoff, symlink CLI, and relaunch")

print("Test artifacts: \(root.path)")
