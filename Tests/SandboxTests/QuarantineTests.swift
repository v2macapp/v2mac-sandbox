import Foundation
import Testing
@testable import SandboxHelper

/// Review F23: the flag is read back, and export never puts an unflagged file on the Mac.
struct QuarantineTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString)")

    func flag(_ url: URL) -> String? {
        var buf = [CChar](repeating: 0, count: 128)
        let n = getxattr(url.path, "com.apple.quarantine", &buf, buf.count - 1, 0, XATTR_NOFOLLOW)
        return n > 0 ? String(decoding: buf.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }

    @Test func exportFlagsEveryItemAndRefusesOutsideTheSharedFolder() throws {
        let fm = FileManager.default
        let shared = base.appendingPathComponent("Shared"), out = base.appendingPathComponent("Downloads")
        try fm.createDirectory(at: shared.appendingPathComponent("Report/inner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data("x".utf8).write(to: shared.appendingPathComponent("Report/inner/a.pdf"))
        // A flag the VM set itself must not stand.
        _ = setxattr(shared.appendingPathComponent("Report/inner/a.pdf").path, "com.apple.quarantine", "0000;0;evil;", 12, 0, 0)
        try fm.createSymbolicLink(atPath: shared.appendingPathComponent("Report/home").path, withDestinationPath: NSHomeDirectory())
        try fm.createSymbolicLink(atPath: shared.appendingPathComponent("link").path, withDestinationPath: NSHomeDirectory())

        let target = out.appendingPathComponent("Report")
        try QuarantineWatcher.export(shared.appendingPathComponent("Report"), from: shared, to: target)
        for item in ["", "/inner", "/inner/a.pdf", "/home"] {
            #expect(flag(URL(fileURLWithPath: target.path + item))?.hasSuffix(";V2Mac Sandbox;") == true, "\(item) flagged")
        }
        #expect(try fm.destinationOfSymbolicLink(atPath: target.path + "/home") == NSHomeDirectory(), "a link is copied, not followed")
        #expect(try fm.contentsOfDirectory(atPath: out.path) == ["Report"], "no staging left behind")

        #expect(throws: QuarantineWatcher.ExportError.self) { try QuarantineWatcher.export(shared.appendingPathComponent("link"), from: shared, to: out.appendingPathComponent("l")) }
        #expect(throws: QuarantineWatcher.ExportError.self) { try QuarantineWatcher.export(out.appendingPathComponent("Report"), from: shared, to: out.appendingPathComponent("r")) }
    }
}
