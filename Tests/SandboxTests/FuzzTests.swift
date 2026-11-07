import AgentProtocol
import Foundation
import Testing
@testable import RFB
@testable import SandboxHelper
import V2MacCore

/// Security plan S8.3: mutated input for everything that parses bytes from the VM, the link or a plugin.
/// No crash, the same result however the bytes are split, and each input within a time limit.
/// `FUZZ_SEED` and `FUZZ_RUNS` change the run; a failure prints its seed and input.
@Suite(.serialized) struct FuzzTests {
    static let seed = UInt64(ProcessInfo.processInfo.environment["FUZZ_SEED"] ?? "") ?? 0x5eed_2026
    static let runs = Int(ProcessInfo.processInfo.environment["FUZZ_RUNS"] ?? "") ?? 3000
    /// Per input; the parsers handle each in microseconds.
    static let limit = 0.25

    struct Rand: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { // SplitMix64
            state &+= 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return z ^ (z >> 31)
        }
    }

    /// Flips, inserts, deletes, splices and boundary values in length-sized places.
    static func mutate(_ input: [UInt8], _ seeds: [[UInt8]], _ r: inout Rand) -> [UInt8] {
        var b = input
        for _ in 0..<Int.random(in: 1...4, using: &r) {
            switch Int.random(in: 0..<6, using: &r) {
            case 0 where !b.isEmpty: b[Int.random(in: 0..<b.count, using: &r)] ^= 1 << UInt8.random(in: 0..<8, using: &r)
            case 1: b.insert(UInt8.random(in: 0...255, using: &r), at: Int.random(in: 0...b.count, using: &r))
            case 2 where !b.isEmpty: b.remove(at: Int.random(in: 0..<b.count, using: &r))
            case 3: b += seeds.randomElement(using: &r)!
            case 4 where b.count >= 4:
                let at = Int.random(in: 0...(b.count - 4), using: &r)
                let value: [UInt8] = [[0, 0, 0, 0], [0xff, 0xff, 0xff, 0xff], [0, 1, 0, 0], [0, 0, 0xff, 0xff], [0x7f, 0xff, 0xff, 0xff]].randomElement(using: &r)!
                b.replaceSubrange(at..<(at + 4), with: value)
            case 5 where !b.isEmpty: b = Array(b.prefix(Int.random(in: 0..<b.count, using: &r)))
            default: b.append(UInt8.random(in: 0...255, using: &r))
            }
        }
        return b
    }

    static func chunks(_ b: [UInt8], _ r: inout Rand) -> [[UInt8]] {
        var out: [[UInt8]] = [], i = 0
        while i < b.count {
            let n = min(b.count - i, Int.random(in: 1...max(1, b.count / 3 + 1), using: &r))
            out.append(Array(b[i..<(i + n)]))
            i += n
        }
        return out
    }

    /// Feeds each mutated input whole and in chunks; `parse` returns a comparable summary or "throws".
    static func fuzz(_ name: String, seeds: [[UInt8]], parse: ([[UInt8]]) -> String) {
        var r = Rand(state: seed)
        for run in 0..<runs {
            let input = mutate(seeds.randomElement(using: &r)!, seeds, &r)
            let start = Date()
            let whole = parse([input])
            let split = parse(chunks(input, &r))
            let took = Date().timeIntervalSince(start)
            #expect(whole == split, "\(name) run \(run) seed \(seed): split input parsed differently: \(input)")
            #expect(took < limit, "\(name) run \(run) seed \(seed): \(took)s for \(input.count) bytes")
        }
    }

    static func summary<T>(_ body: () throws -> [T]) -> String {
        do { return String(describing: try body()) } catch { return "throws" }
    }

    // MARK: Targets

    @Test func agentMessages() {
        let seeds = [AgentMessage.hello(version: 1), .ok, .shutdown, .put(name: "xray.json", body: "{\"a\": 1}"),
                     .run(["app-add", "3", "x.y"]), .pty(["open", "1"]), .gui(["open", "2", "a-b"]), .result(status: 0, output: "fine")]
            .map(\.frame)
        Self.fuzz("AgentMessage", seeds: seeds) { parts in
            var reader = AgentMessage.Reader()
            return Self.summary { try parts.flatMap { try reader.feed($0) } }
        }
    }

    @Test func ptyInput() {
        let seeds = [PtyInput.data(Array("ls -l\n".utf8)), .resize(rows: 40, cols: 120), .data([])].map(\.frame)
        Self.fuzz("PtyInput", seeds: seeds) { parts in
            var reader = PtyInput.Reader()
            return Self.summary { try parts.flatMap { try reader.feed($0) } }
        }
    }

    @Test func rfbClientFilter() {
        let handshake = Array("RFB 003.008\n".utf8) + [1, 1]
        let seeds: [[UInt8]] = [
            handshake + [5, 0, 0, 10, 0, 20] + [4, 1, 0, 0, 0, 0, 0, 0x61],
            handshake + [250, 0, 0, 0, 3] + Array("سلام".utf8.prefix(3)),
            handshake + [6, 0, 0, 0, 0, 0, 0, 2, 0x68, 0x69] + [252, 4, 0, 3, 0, 2],
            handshake + [2, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 0] + [3, 1, 0, 0, 0, 0, 1, 0, 1, 0],
            handshake + [0] + [UInt8](repeating: 0, count: 19),
        ]
        for clipboard in [true, false] {
            Self.fuzz("RFBClientFilter", seeds: seeds) { parts in
                var filter = RFBClientFilter(clipboard: clipboard)
                // Forwarded bytes may be split differently; what reaches wayvnc and the agent may not.
                return Self.summary { () throws -> [RFBClientFilter.Out] in
                    try parts.flatMap { try filter.feed($0) }.reduce(into: []) { out, next in
                        if next == .forward([]) { return } // an empty feed forwards nothing
                        if case .forward(let b) = next, case .forward(let a)? = out.last { out[out.count - 1] = .forward(a + b) } else { out.append(next) }
                    }
                }
            }
        }
    }

    @Test func sandboxLink() throws {
        let toHelper: [SandboxLink.ToHelper] = [.hello(version: 1, ramCapMB: 2048, core: "/x"), .servers([.init(id: "a", name: "Frankfurt")], active: "a"),
                                                .outbound(id: "a", json: #"{"protocol":"freedom"}"#), .downloaded(request: 1, path: nil), .probe]
        let toApp: [SandboxLink.ToApp] = [.hello(version: 1), .vmState("running"), .notice(kind: "exit", text: "stopped"),
                                          .download(request: 1, url: URL(string: "https://example.com/a")!, sha256: String(repeating: "0", count: 64))]
        Self.fuzz("SandboxLink.ToHelper", seeds: try toHelper.map { [UInt8](try SandboxLink.frame($0)) }) { parts in
            var reader = SandboxLink.Reader<SandboxLink.ToHelper>()
            return Self.summary { try parts.flatMap { try reader.feed(Data($0)) } }
        }
        Self.fuzz("SandboxLink.ToApp", seeds: try toApp.map { [UInt8](try SandboxLink.frame($0)) }) { parts in
            var reader = SandboxLink.Reader<SandboxLink.ToApp>()
            return Self.summary { try parts.flatMap { try reader.feed(Data($0)) } }
        }
    }

    @Test func pluginManifest() {
        let good = #"{"api":2,"id":"hello-pty","name":"Hello","version":"1.0","display":"pty","launch":{"cmd":["bash","-l"],"env":{"GREETING":"hi"}},"permissions":["ssh-agent"],"packages":["htop"],"iconSvg":"<svg xmlns='http://www.w3.org/2000/svg' width='8' height='8'><rect width='8' height='8'/></svg>"}"#
        Self.fuzz("PluginManifest", seeds: [Array(good.utf8)]) { parts in
            let data = Data(parts.joined())
            do {
                let m = try JSONDecoder().decode(PluginManifest.self, from: data)
                try m.validate()
                // What validate() promises the runtime.
                #expect(AgentMessage.isWord(m.id) && ["pty", "gui"].contains(m.display) && !m.launch.cmd.isEmpty)
                return m.id
            } catch { return "throws" }
        }
    }

    /// The guest picks every byte here. `run()` ends with "closed" once the input runs out.
    @Test func rfbClient() {
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ enc: Int32) -> [UInt8] {
            be16(x) + be16(y) + be16(w) + be16(h) + withUnsafeBytes(of: enc.bigEndian) { Array($0) }
        }
        let greeting = Array("RFB 003.008\n".utf8) + [1, 1, 0, 0, 0, 0] + be16(4) + be16(4) + [UInt8](repeating: 0, count: 16) + [0, 0, 0, 1, 0x41]
        let seeds: [[UInt8]] = [
            greeting + [0, 0] + be16(1) + rect(1, 1, 2, 2, 0) + [UInt8](repeating: 7, count: 16),
            greeting + [0, 0] + be16(2) + rect(0, 0, 2, 2, 1) + be16(2) + be16(2) + rect(0, 0, 6, 6, -223),
            greeting + [3, 0, 0, 0, 0, 0, 0, 2, 0x68, 0x69, 2],
        ]
        Self.fuzz("RFBClient", seeds: seeds) { parts in
            final class Input: @unchecked Sendable { var bytes: ArraySlice<UInt8>; init(_ b: [UInt8]) { bytes = b[...] } }
            let input = Input(Array(parts.joined()))
            let client = RFBClient(read: { buf in
                let n = min(buf.count, input.bytes.count)
                guard n > 0 else { return 0 }
                for i in 0..<n { buf[i] = input.bytes[input.bytes.startIndex + i] }
                input.bytes = input.bytes.dropFirst(n)
                return n
            }, write: { _ in })
            do { try client.handshake(); try client.run() } catch let e as RFBClient.Invalid { return e.reason } catch { return "other" }
            return "ended"
        }
    }
}

/// S8.3's time limits for the worst cases mutation won't find: many tiny messages in one read, and
/// small input that asks for big work.
@Suite(.serialized) struct FuzzCostTests {
    static func time(_ body: () throws -> Void) rethrows -> Double {
        let start = Date(); try body(); return Date().timeIntervalSince(start)
    }

    /// 4x the bytes in one read must cost about 4x the time; quadratic buffer handling costs 16x.
    static func linear(_ name: String, _ message: [UInt8], _ feed: ([UInt8]) throws -> Void) throws {
        let small = Array([[UInt8]](repeating: message, count: (1 << 18) / message.count).joined())
        let big = Array([[UInt8]](repeating: small, count: 4).joined())
        let ratio = try time { try feed(big) } / max(try time { try feed(small) }, 1e-4)
        #expect(ratio < 8, "\(name): 4x the input took \(ratio)x the time")
    }

    @Test func manySmallMessagesInOneRead() throws {
        try Self.linear("AgentMessage", AgentMessage.ok.frame) { var r = AgentMessage.Reader(); _ = try r.feed($0) }
        try Self.linear("PtyInput", [1, 0, 1, 0, 1]) { var r = PtyInput.Reader(); _ = try r.feed($0) }
        try Self.linear("RFBClientFilter", [5, 0, 0, 1, 0, 1]) {
            var r = RFBClientFilter(clipboard: true)
            _ = try r.feed(Array("RFB 003.008\n".utf8) + [1, 1] + $0)
        }
        try Self.linear("SandboxLink", [UInt8](try SandboxLink.frame(SandboxLink.ToHelper.probe))) {
            var r = SandboxLink.Reader<SandboxLink.ToHelper>(); _ = try r.feed(Data($0))
        }
    }
}
