import Foundation
import Testing

/// Scripts/host-leak.sh must never pass when tcpdump measured nothing (review F06, from its
/// reproduce_checks.py). Every command it could reach is a harmless stub; nothing is captured.
@Suite struct HostLeakScriptTests {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Scripts/host-leak.sh").path

    func run(tcpdump: String) throws -> Int32 {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("host-leak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, body) in ["id": "echo 0", "route": "echo 'interface: en-test'", "tcpdump": tcpdump] {
            let file = dir.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [Self.script, "en-test", "1"]
        p.environment = ["PATH": "\(dir.path):/usr/bin:/bin", "TMPDIR": dir.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    @Test func failingTcpdumpIsInconclusive() throws {
        #expect(try run(tcpdump: "echo 'intentional test capture failure' >&2; exit 1") == 2)
    }

    @Test func emptyCaptureIsInconclusive() throws {
        #expect(try run(tcpdump: "exec sleep 5") == 2)
    }
}
