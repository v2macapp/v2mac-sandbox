import AgentProtocol
import Foundation
import Testing
@testable import SandboxHelper

/// Review F11: a late agent answer must never be read as the next request's.
@Suite struct AgentChannelTests {
    /// A socket pair: the channel on one end, a fake agent on the other.
    func pair() -> (AgentChannel, agent: Int32) {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let mine = fds[0]
        var on: Int32 = 1 // a write to a closed peer must fail, not kill the test run
        for fd in fds { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) }
        return (AgentChannel(fd: mine) { Darwin.close(mine) }, fds[1])
    }

    /// The fake agent reads one request, waits `delay` seconds, writes `bytes` in pieces `gap` apart and
    /// closes its end.
    func answer(on fd: Int32, after delay: TimeInterval, _ bytes: [UInt8], piece: Int = .max, gap: TimeInterval = 0) {
        let thread = Thread {
            var buf = [UInt8](repeating: 0, count: 4096)
            _ = read(fd, &buf, buf.count)
            Thread.sleep(forTimeInterval: delay)
            for start in stride(from: 0, to: bytes.count, by: min(piece, bytes.count)) {
                let chunk = Array(bytes[start..<min(start + piece, bytes.count)])
                _ = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                Thread.sleep(forTimeInterval: gap)
            }
            close(fd)
        }
        thread.start()
    }

    @Test func answersInTimeAreRead() {
        let (channel, agent) = pair()
        answer(on: agent, after: 0.01, AgentMessage.ok.frame)
        #expect(channel.exchange(.put(name: "a", body: "b"), timeout: .seconds(2)) == .ok)
        #expect(!channel.isClosed)
    }

    @Test func aLateAnswerClosesTheChannelAndIsNeverRead() {
        let (channel, agent) = pair()
        answer(on: agent, after: 0.3, AgentMessage.result(status: 0, output: "late").frame)
        #expect(channel.exchange(.run(["slow"]), timeout: .milliseconds(100)) == nil)
        #expect(channel.isClosed)
        Thread.sleep(forTimeInterval: 0.4) // the late answer has been sent by now
        #expect(channel.exchange(.put(name: "a", body: "b"), timeout: .seconds(1)) == nil)
        #expect(!channel.send(.shutdown))
    }

    @Test func theDeadlineIsAbsoluteNotPerRead() {
        let (channel, agent) = pair()
        // Two bytes every 40 ms: each piece is quicker than the timeout, the whole frame is not.
        answer(on: agent, after: 0, AgentMessage.result(status: 0, output: "dribble").frame, piece: 2, gap: 0.04)
        #expect(channel.exchange(.run(["x"]), timeout: .milliseconds(150)) == nil)
        #expect(channel.isClosed)
    }

    @Test func aBadFrameOrTheAgentGoingAwayCloses() {
        let (channel, agent) = pair()
        answer(on: agent, after: 0, [0, 0, 0, 3] + Array("bad".utf8))
        #expect(channel.exchange(.run(["x"]), timeout: .seconds(2)) == nil)
        #expect(channel.isClosed)
        let (other, gone) = pair()
        close(gone)
        #expect(other.exchange(.run(["x"]), timeout: .seconds(2)) == nil)
        #expect(other.isClosed)
    }
}
