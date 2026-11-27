import Foundation
import XCTest

@testable import PostWomanCLI

/// In-memory links and files whose operations can be made to fail.
private final class LinkDisk: @unchecked Sendable {
    private let lock = NSLock()
    var links: [String: String] = [:]
    var files: Set<String> = []
    var directories: [String] = []
    var failCreateDirectory = false
    var failRemove = false
    var sent = 0

    var cliLinks: CLILinks {
        CLILinks(
            destination: { path in self.lock.withLock { self.links[path] } },
            exists: { path in self.lock.withLock { self.links[path] != nil || self.files.contains(path) } },
            createDirectory: { path in
                try self.lock.withLock {
                    if self.failCreateDirectory { throw CocoaError(.fileWriteNoPermission) }
                    self.directories.append(path)
                }
            },
            createLink: { path, target in self.lock.withLock { self.links[path] = target } },
            remove: { path in
                try self.lock.withLock {
                    if self.failRemove { throw CocoaError(.fileWriteNoPermission) }
                    self.links[path] = nil
                }
            })
    }
}

private let helper = "/Applications/PostWoman.app/Contents/Helpers/postwoman"
private let link = "/Users/test/.local/bin/postwoman"

private func runLink(_ words: [String], _ disk: LinkDisk, path: String = "/usr/bin", executable: String = helper) async -> (status: Int32, stdout: String, stderr: String) {
    let output = CLIOutputBox()
    var environment = makeCLIEnvironment(
        output: output, variables: ["PATH": path],
        send: { _ in
            disk.sent += 1
            throw URLError(.cannotConnectToHost)
        })
    environment.links = disk.cliLinks
    environment.executablePath = executable
    let status = await CLI.run(words, environment: environment)
    return (status, output.stdout, output.stderr)
}

final class CLILinkCommandTests: XCTestCase {
    func testInstallLinksIntoLocalBinAndSaysHowToAddItToPATH() async {
        let disk = LinkDisk()
        let result = await runLink(["cli", "install-link"], disk)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "Linked \(link) → \(helper)")
        XCTAssertEqual(result.stderr, #"Add /Users/test/.local/bin to PATH, for example: echo 'export PATH="/Users/test/.local/bin:$PATH"' >> ~/.zshrc"#)
        XCTAssertEqual(disk.links, [link: helper])
        XCTAssertEqual(disk.directories, ["/Users/test/.local/bin"])
        XCTAssertEqual(disk.sent, 0, "Local commands need no app")
    }

    func testInstallOnPATHPrintsNoHintAndAgainChangesNothing() async {
        let disk = LinkDisk()
        let first = await runLink(["cli", "install-link"], disk, path: "/usr/bin:/Users/test/.local/bin")
        XCTAssertEqual(first.stderr, "")
        disk.directories = []
        let again = await runLink(["cli", "install-link"], disk, path: "/usr/bin:/Users/test/.local/bin")
        XCTAssertEqual(again.status, 0)
        XCTAssertEqual(again.stdout, "\(link) already links here.")
        XCTAssertEqual(disk.directories, [], "Nothing is created the second time")
    }

    func testInstallInJSONReportsTheLinkAndWhetherItIsOnPATH() async throws {
        let disk = LinkDisk()
        let result = await runLink(["cli", "install-link", "--json"], disk)
        XCTAssertEqual(result.stderr, "")
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(
            value,
            .object([
                "ok": .bool(true),
                "result": .object([
                    "link": .string(link), "target": .string(helper), "changed": .bool(true), "onPath": .bool(false),
                    "hint": .string(#"Add /Users/test/.local/bin to PATH, for example: echo 'export PATH="/Users/test/.local/bin:$PATH"' >> ~/.zshrc"#)
                ])
            ]))
        let again = await runLink(["cli", "install-link", "--json"], disk, path: "/Users/test/.local/bin")
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: Data(again.stdout.utf8))["result"],
            .object(["link": .string(link), "target": .string(helper), "changed": .bool(false), "onPath": .bool(true)]))
    }

    func testTheDirectoryExpandsTildeAndDropsATrailingSlash() async {
        let cases: [(String, String)] = [
            ("~/bin", "/Users/test/bin/postwoman"), ("~", "/Users/test/postwoman"), ("/opt/bin/", "/opt/bin/postwoman"), ("/opt/bin", "/opt/bin/postwoman")
        ]
        for (directory, expected) in cases {
            let disk = LinkDisk()
            let result = await runLink(["cli", "install-link", "--directory", directory], disk)
            XCTAssertEqual(result.status, 0, directory)
            XCTAssertEqual(disk.links, [expected: helper], directory)
            let removed = await runLink(["cli", "remove-link", "--directory=\(directory)"], disk)
            XCTAssertEqual(removed.stdout, "Removed \(expected).", directory)
            XCTAssertEqual(disk.links, [:], directory)
        }
    }

    func testAnotherLinkIsReplacedOnlyWithForce() async {
        let disk = LinkDisk()
        disk.links[link] = "/elsewhere/postwoman"
        let refused = await runLink(["cli", "install-link"], disk)
        XCTAssertEqual(refused.status, 1)
        XCTAssertEqual(refused.stderr, "postwoman: \(link) already links to /elsewhere/postwoman. Pass --force to replace it. (LINK_FAILED)")
        XCTAssertEqual(disk.links[link], "/elsewhere/postwoman", "Left alone")

        disk.failRemove = true
        let stuck = await runLink(["cli", "install-link", "--force"], disk)
        XCTAssertEqual(stuck.status, 1)
        XCTAssertEqual(stuck.stderr, "postwoman: Can't replace \(link). (LINK_FAILED)")

        disk.failRemove = false
        let forced = await runLink(["cli", "install-link", "--force"], disk)
        XCTAssertEqual(forced.status, 0)
        XCTAssertEqual(forced.stdout, "Linked \(link) → \(helper)")
        XCTAssertEqual(disk.links[link], helper)
    }

    func testARealFileIsNeverReplacedOrRemoved() async {
        let disk = LinkDisk()
        disk.files = [link]
        for words in [["cli", "install-link"], ["cli", "install-link", "--force"]] {
            let result = await runLink(words, disk)
            XCTAssertEqual(result.status, 1, "\(words)")
            XCTAssertEqual(result.stderr, "postwoman: \(link) exists and is not a link. Remove it, or choose another --directory. (LINK_FAILED)", "\(words)")
        }
        let removed = await runLink(["cli", "remove-link"], disk)
        XCTAssertEqual(removed.status, 1)
        XCTAssertEqual(removed.stderr, "postwoman: \(link) is not a link, so it was left alone. (LINK_FAILED)")
        XCTAssertEqual(disk.files, [link])
        XCTAssertEqual(disk.links, [:])
    }

    func testInstallFailuresSayWhy() async {
        let relative = await runLink(["cli", "install-link"], LinkDisk(), executable: "postwoman")
        XCTAssertEqual(relative.status, 1)
        XCTAssertEqual(relative.stderr, "postwoman: Can't tell where this postwoman command is. (LINK_FAILED)")

        let disk = LinkDisk()
        disk.failCreateDirectory = true
        let unwritable = await runLink(["cli", "install-link", "--json"], disk)
        XCTAssertEqual(unwritable.status, 1)
        XCTAssertEqual(
            unwritable.stdout,
            JSONValue.object([
                "ok": .bool(false),
                "error": .object([
                    "code": .string("LINK_FAILED"), "exitStatus": .number(1),
                    "message": .string("Can't create \(link): \(CocoaError(.fileWriteNoPermission).localizedDescription)")
                ])
            ]).compact)
        XCTAssertEqual(disk.links, [:])
    }

    func testRemoveSaysWhetherThereWasALink() async {
        let disk = LinkDisk()
        let missing = await runLink(["cli", "remove-link"], disk)
        XCTAssertEqual(missing.status, 0)
        XCTAssertEqual(missing.stdout, "There is no link at \(link).")

        disk.links[link] = "/anything"
        disk.failRemove = true
        let stuck = await runLink(["cli", "remove-link"], disk)
        XCTAssertEqual(stuck.status, 1)
        XCTAssertEqual(stuck.stderr, "postwoman: Can't remove \(link). (LINK_FAILED)")

        disk.failRemove = false
        let removed = await runLink(["cli", "remove-link", "--json"], disk)
        XCTAssertEqual(removed.stdout, #"{"ok":true,"result":{"link":"\#(link)","removed":true}}"#)
        XCTAssertEqual(disk.links, [:])
        XCTAssertEqual(disk.sent, 0)
    }
}
