import Foundation
import Testing
@testable import MaskPad

struct MaskCommandTests {
    private func parse(_ string: String) -> MaskCommand.Request? {
        URL(string: string).flatMap(MaskCommand.parse)
    }

    @Test func parsesCommands() {
        #expect(parse("maskpad://on") == .init(command: .on, replyID: nil))
        #expect(parse("maskpad://status") == .init(command: .status, replyID: nil))
        // Scheme and command are case-insensitive; a trailing slash is fine.
        #expect(parse("MaskPad://ON/") == .init(command: .on, replyID: nil))
    }

    /// There is no command to turn the mask off, and nothing else is accepted.
    @Test func rejectsEverythingElse() {
        for string in ["maskpad://off", "maskpad://disengage", "maskpad://", "maskpad://on/extra",
                       "https://on", "maskpad:on"] {
            #expect(parse(string) == nil, "\(string)")
        }
    }

    @Test func replyIDMustBeAUUID() {
        let id = UUID().uuidString
        #expect(parse("maskpad://on?reply=\(id)")?.replyID == id)
        // Normalized to the canonical form.
        #expect(parse("maskpad://on?reply=\(id.lowercased())")?.replyID == id)
        // Anything else is dropped; the command still runs without a reply.
        #expect(parse("maskpad://on?reply=com.apple.screenIsLocked") == .init(command: .on, replyID: nil))
    }

    @Test func urlRoundTrips() {
        let id = UUID().uuidString
        for command in MaskCommand.allCases {
            #expect(MaskCommand.parse(command.url()) == .init(command: command, replyID: nil))
            #expect(MaskCommand.parse(command.url(replyID: id)) == .init(command: command, replyID: id))
        }
    }

    /// Launch Services and Xcode start the app with no command word, so they must start the app.
    @Test func appLaunchesAreNotToolInvocations() {
        let app = "/Applications/MaskPad.app/Contents/MacOS/MaskPad"
        #expect(CommandLineTool.run(arguments: [app]) == nil)
        #expect(CommandLineTool.run(arguments: [app, "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
        #expect(CommandLineTool.run(arguments: [app, "unknown"]) == nil)
    }

    /// Under the name `maskpad`, anything is a tool invocation; unknown commands are usage errors.
    @Test func toolUsage() {
        #expect(CommandLineTool.run(arguments: ["/Users/me/.local/bin/maskpad"]) == 0)
        #expect(CommandLineTool.run(arguments: ["maskpad", "off"]) == 2)
        #expect(CommandLineTool.run(arguments: ["maskpad", "--help"]) == 0)
        #expect(CommandLineTool.run(arguments: ["maskpad", "version"]) == 0)
    }
}
