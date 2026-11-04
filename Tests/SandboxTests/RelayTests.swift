import Foundation
import Synchronization
import Testing
@testable import SandboxHelper

/// Review F10: the relay's connection caps and idle deadline.
@Suite(.serialized) struct RelayTests {
    @Test func capsConnectionsPerMiniVMAndInTotal() {
        let vms = (0..<4).map { _ in RelayListener(port: 1) }
        #expect((0..<RelayListener.perVM).allSatisfy { _ in vms[0].admit() })
        #expect(!vms[0].admit(), "one past the mini VM's cap")
        #expect(vms[1].admit(), "another mini VM still gets in")
        vms[0].release()
        #expect(vms[0].admit(), "a closed connection frees its place")
        var others = 1
        while others < RelayListener.total - RelayListener.perVM, vms[1 + others / RelayListener.perVM].admit() { others += 1 }
        #expect((0..<RelayListener.floor).allSatisfy { _ in vms[3].admit() }, "a mini VM's first few always get in")
        #expect(!vms[3].admit(), "past its floor, the total cap holds")
        for _ in 0..<RelayListener.floor { vms[3].release() }
        for _ in 0..<RelayListener.perVM { vms[0].release() }
        for i in 0..<others { vms[1 + i / RelayListener.perVM].release() }
        #expect(vms[3].admit())
        vms[3].release()
    }

    @Test func idleConnectionIsClosedAtTheDeadline() async throws {
        var guest: [Int32] = [0, 0], core: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &guest) == 0 && socketpair(AF_UNIX, SOCK_STREAM, 0, &core) == 0)
        let closed = Mutex(false)
        let start = Date()
        RelayListener.pipe(guest[1], core[0], idle: 2) { closed.withLock { $0 = true } }
        // Bytes still pass, and keep it open.
        _ = write(guest[0], "hi", 2)
        var buf = [UInt8](repeating: 0, count: 2)
        #expect(read(core[1], &buf, 2) == 2)
        for _ in 0..<80 where !closed.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(closed.withLock { $0 })
        #expect(Date().timeIntervalSince(start) >= 2)
        #expect(read(guest[0], &buf, 2) == 0, "the guest sees the close")
        close(guest[0]); close(core[1])
    }
}
