import Foundation
import Testing
@testable import MaskPad

/// Runs against a temporary folder, never /usr/local/bin. File names differ by more than case: APFS
/// volumes are usually case-insensitive, so "MaskPad" and "maskpad" would be the same file.
struct CommandLineToolInstallerTests {
    private let fileManager = FileManager.default

    private func withTemporaryFolder(_ body: (URL) throws -> Void) throws {
        let folder = fileManager.temporaryDirectory.appendingPathComponent("maskpad-cli-\(UUID().uuidString)")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        try body(folder)
    }

    @Test func states() throws {
        try withTemporaryFolder { folder in
            let target = folder.appendingPathComponent("MaskPadExecutable").path
            let other = folder.appendingPathComponent("OtherMaskPad").path
            try Data().write(to: URL(fileURLWithPath: target))
            try Data().write(to: URL(fileURLWithPath: other))
            let link = folder.appendingPathComponent("maskpad").path
            func state() -> CommandLineToolInstaller.State {
                CommandLineToolInstaller.state(linkPath: link, target: target)
            }

            #expect(state() == .notInstalled)

            try fileManager.createSymbolicLink(atPath: link, withDestinationPath: target)
            #expect(state() == .installed)

            // Another copy of the app, or a copy that has been moved or deleted.
            try fileManager.removeItem(atPath: link)
            try fileManager.createSymbolicLink(atPath: link, withDestinationPath: other)
            #expect(state() == .otherCopy)
            try fileManager.removeItem(atPath: other)
            #expect(state() == .otherCopy)

            // Not a link: someone else's file, never replaced.
            try fileManager.removeItem(atPath: link)
            try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: link))
            #expect(state() == .otherFile)
        }
    }

    /// A link through another link to the same executable still counts as installed.
    @Test func linkThroughLinkIsInstalled() throws {
        try withTemporaryFolder { folder in
            let target = folder.appendingPathComponent("MaskPadExecutable").path
            try Data().write(to: URL(fileURLWithPath: target))
            let middle = folder.appendingPathComponent("middle").path
            try fileManager.createSymbolicLink(atPath: middle, withDestinationPath: target)
            let link = folder.appendingPathComponent("maskpad").path
            try fileManager.createSymbolicLink(atPath: link, withDestinationPath: middle)
            #expect(CommandLineToolInstaller.state(linkPath: link, target: target) == .installed)
        }
    }

    @Test func shellQuoting() {
        #expect(AdministratorShell.shellQuoted("/Applications/MaskPad.app") == "'/Applications/MaskPad.app'")
        #expect(AdministratorShell.shellQuoted("/Users/a b/it's $HOME") == #"'/Users/a b/it'\''s $HOME'"#)
    }
}
