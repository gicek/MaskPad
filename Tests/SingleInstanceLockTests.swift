import Darwin
import Foundation
import Testing
@testable import MaskPad

struct SingleInstanceLockTests {
    private func withLockFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("instance.lock"))
    }

    @Test func onlyOneOwnerAndReleaseAllowsRelaunch() throws {
        try withLockFile { url in
            var owner = try SingleInstanceLock.acquire(at: url)
            #expect(owner != nil)
            #expect(try SingleInstanceLock.acquire(at: url) == nil)
            owner = nil
            let replacement = try SingleInstanceLock.acquire(at: url)
            #expect(replacement != nil)
            #expect(try SingleInstanceLock.acquire(at: url) == nil)
            withExtendedLifetime(replacement) {}
        }
    }

    @Test func independentIdentitiesCanRunTogether() throws {
        try withLockFile { url in
            let stable = try SingleInstanceLock.acquire(at: url)
            let debug = try SingleInstanceLock.acquire(at: url.appendingPathExtension("debug"))
            #expect(stable != nil && debug != nil)
            withExtendedLifetime((stable, debug)) {}
        }
    }

    @Test func aDifferentProcessCannotTakeTheLock() throws {
        try withLockFile { url in
            let owner = try #require(try SingleInstanceLock.acquire(at: url))
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            child.arguments = ["-c", """
                import fcntl, sys
                with open(sys.argv[1], 'r+') as file:
                    try:
                        fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        sys.exit(23)
                """, url.path]
            try child.run()
            child.waitUntilExit()
            #expect(child.terminationStatus == 23)
            withExtendedLifetime(owner) {}
        }
    }

    @Test func crashReleasesTheLockWithoutRemovingTheFile() throws {
        try withLockFile { url in
            let child = Process()
            let ready = Pipe()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            child.standardOutput = ready
            child.arguments = ["-c", """
                import fcntl, sys, time
                with open(sys.argv[1], 'w') as file:
                    fcntl.flock(file, fcntl.LOCK_EX)
                    print('ready', flush=True)
                    time.sleep(10)
                """, url.path]
            try child.run()
            defer {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
            #expect(ready.fileHandleForReading.readData(ofLength: 6) == Data("ready\n".utf8))
            #expect(try SingleInstanceLock.acquire(at: url) == nil)
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            let replacement = try SingleInstanceLock.acquire(at: url)
            #expect(replacement != nil)
            #expect(FileManager.default.fileExists(atPath: url.path))
            withExtendedLifetime(replacement) {}
        }
    }

    @Test func lockFailureDoesNotAllowStartupAndSymlinksAreRejected() throws {
        try withLockFile { url in
            let missing = url.appendingPathComponent("missing")
            #expect(throws: (any Error).self) { try SingleInstanceLock.acquire(at: missing) }
            let target = url.appendingPathExtension("target")
            FileManager.default.createFile(atPath: target.path, contents: Data())
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            #expect(throws: (any Error).self) { try SingleInstanceLock.acquire(at: url) }
        }
    }

    @Test func debugBuildHasAnIsolatedIdentity() {
        #if DEBUG
        #expect(AppIdentity.bundleIdentifier == "com.gicek.maskpad.debug")
        #expect(AppIdentity.urlScheme == "maskpad-debug")
        #expect(AppIdentity.passcodeService == "com.gicek.maskpad.debug.passcode")
        #else
        #expect(AppIdentity.bundleIdentifier == "com.gicek.maskpad")
        #expect(AppIdentity.urlScheme == "maskpad")
        #expect(AppIdentity.passcodeService == "com.gicek.maskpad.passcode")
        #endif
        let other = AppIdentity.isDebug ? "maskpad" : "maskpad-debug"
        #expect(MaskCommand.parse(URL(string: "\(other)://on")!) == nil)
        #expect(MaskCommand.parse(MaskCommand.status.url())?.command == .status)
    }
}

@MainActor
struct InstanceLaunchInboxTests {
    @Test func queuesStartupEventsAndDiscardsSecondaryEvents() {
        var events: [String] = []
        let inbox = InstanceLaunchInbox(namespace: "com.gicek.maskpad.tests." + UUID().uuidString,
            onReopen: { events.append("reopen") }, onURL: { events.append($0.host() ?? "") })
        defer { inbox.stop() }
        inbox.enqueue(MaskCommand.status.url())
        inbox.enqueueReopen()
        inbox.enqueue(URL(string: "\(MaskCommand.scheme)://off")!)
        #expect(events.isEmpty)
        inbox.start()
        #expect(events == ["status", "reopen"])
        inbox.start()
        #expect(events.count == 2)
        inbox.enqueue(MaskCommand.on.url())
        #expect(events == ["status", "reopen", "on"])
        inbox.stop()
        inbox.enqueueReopen()
        inbox.enqueue(MaskCommand.status.url())
        inbox.start()
        #expect(events.count == 3)
    }
}
