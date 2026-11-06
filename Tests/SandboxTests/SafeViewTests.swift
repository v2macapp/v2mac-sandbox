import Foundation
import Testing
@testable import SandboxHelper

/// Review F22: an app opened with a file gets a copy of only that file, in a folder of its own.
struct SafeViewTests {
    @Test func copiesOneRegularFileAndRefusesOthers() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let views = tmp.appendingPathComponent("view")
        try fm.createDirectory(at: views, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("report one.pdf")
        try Data("%PDF".utf8).write(to: file)
        let link = tmp.appendingPathComponent("link.pdf")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)

        let dir = try #require(PtyServer.viewCopy(of: file, in: views))
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["report one.pdf"])
        #expect(try Data(contentsOf: dir.appendingPathComponent("report one.pdf")) == Data("%PDF".utf8))
        let viaLink = try #require(PtyServer.viewCopy(of: link, in: views), "a symlink gives its target")
        #expect(viaLink != dir, "each window its own folder")
        #expect(PtyServer.viewCopy(of: tmp, in: views) == nil, "not a folder")
        #expect(PtyServer.viewCopy(of: tmp.appendingPathComponent("missing"), in: views) == nil)
    }
}
