import Foundation
import Testing
@testable import SandboxHelper

/// Review F13: Don't Allow ends an open app's live bridge, and its next use asks again.
@MainActor struct RevokeTests {
    @Test func revokeClosesTheLiveBridgeAndAsksAgain() async throws {
        var guest: [Int32] = [0, 0], mac: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &guest) == 0 && socketpair(AF_UNIX, SOCK_STREAM, 0, &mac) == 0)
        let asked = Asked(), macEnd = mac[0]
        let forward = SessionForward(ask: { asked.n += 1; return asked.n == 1 }, // Allow, then Don't Allow
                                     serve: { fd, done in RelayListener.pipe(fd, macEnd, done: done) })
        await forward.accept(guest[1])
        _ = write(guest[0], "hi", 2)
        var buf = [UInt8](repeating: 0, count: 2)
        #expect(read(mac[1], &buf, 2) == 2, "allowed: bytes reach the Mac side")

        forward.revoke()
        #expect(read(guest[0], &buf, 2) == 0, "the app sees its bridge close")
        #expect(read(mac[1], &buf, 2) == 0, "and so does the Mac side")

        var again: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &again) == 0)
        await forward.accept(again[1])
        #expect(asked.n == 2, "the next use asks again")
        #expect(read(again[0], &buf, 2) == 0, "and is refused by the new answer")
        close(guest[0]); close(mac[1]); close(again[0])
    }
}

@MainActor private final class Asked { var n = 0 }
