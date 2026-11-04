import Foundation
import Synchronization
import Virtualization

/// Host end of a mini VM's relay (plan §4): each guest connection on vsock port 11000+n is piped to
/// the sandbox core's VLESS inbound for that mini VM.
final class RelayListener: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    /// Review F10: open connections a mini VM may have, and all mini VMs together (two threads each, and
    /// macOS allows a process 9216). One past either is refused: the guest sees its connection fail, and
    /// the VM has no other way out. Below `floor` a mini VM always gets in, so busy ones can't lock out another.
    static let perVM = 256, total = 768, floor = 16
    /// A connection with no bytes either way for this long is closed (seconds). xray-in-vm already ends
    /// idle ones after 300 s (its default `connIdle`), so this only reclaims what it lost track of.
    static let idle = 600
    private static let open = Mutex<(total: Int, byVM: [ObjectIdentifier: Int], refused: Int)>((0, [:], 0))

    /// Guest ends of the connections open now, so an exit switch can end them (review F12, strict).
    private let live = Mutex<Set<Int32>>([])
    /// The sandbox core's inbound port; changes when the core restarts.
    nonisolated(unsafe) var port: Int
    let listener = VZVirtioSocketListener()

    init(port: Int) {
        self.port = port
        super.init()
        listener.delegate = self
    }

    /// Counts a new connection in, or says it is one too many.
    func admit() -> Bool {
        let me = ObjectIdentifier(self)
        return Self.open.withLock { open in
            let mine = open.byVM[me, default: 0]
            guard mine < Self.perVM, open.total < Self.total || mine < Self.floor else {
                // A full VM retries fast: the first refusal and every 1000th, so the log stays small.
                if open.refused % 1000 == 0 { log("relay on port \(port): \(mine) open here, \(open.total) in all; refusing new connections") }
                open.refused += 1
                return false
            }
            open.byVM[me] = mine + 1
            open.total += 1
            return true
        }
    }

    /// Ends every open connection; the apps reconnect through whatever exit the core has now.
    func closeAll() { live.withLock { for fd in $0 { shutdown(fd, SHUT_RDWR) } } }

    func release() {
        let me = ObjectIdentifier(self)
        Self.open.withLock { open in
            open.byVM[me, default: 1] -= 1
            open.total -= 1
        }
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        guard admit() else { return false } // fail closed
        let guest = dup(connection.fileDescriptor)
        connection.close()
        let host = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: in_port_t(UInt16(port).bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(host, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard guest >= 0, host >= 0, connected == 0 else {
            close(guest); close(host); release()
            return true // the guest sees the connection close: fail closed
        }
        live.withLock { _ = $0.insert(guest) }
        Self.pipe(guest, host, idle: Self.idle) { [self] in live.withLock { _ = $0.remove(guest) }; release() }
        return true
    }

    /// shortcut: two blocking threads per connection; move to a kqueue loop if thread count bites.
    /// `idle` (seconds) closes both ends after that long without a byte either way, or a write that long stuck.
    static func pipe(_ a: Int32, _ b: Int32, idle: Int? = nil, done: @escaping @Sendable () -> Void = {}) {
        let group = DispatchGroup()
        let last = LastByte()
        if let idle {
            // Reads wake every minute to look at the other direction; a write gives up after `idle`.
            var wake = timeval(tv_sec: min(idle, 60), tv_usec: 0), stuck = timeval(tv_sec: idle, tv_usec: 0)
            for fd in [a, b] {
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wake, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &stuck, socklen_t(MemoryLayout<timeval>.size))
            }
        }
        for (from, to) in [(a, b), (b, a)] {
            group.enter()
            Thread {
                var buf = [UInt8](repeating: 0, count: 65536)
                copy: while true {
                    let n = read(from, &buf, buf.count)
                    if n < 0, errno == EAGAIN || errno == EINTR {
                        if let idle, Int(ProcessInfo.processInfo.systemUptime) - last.at.load(ordering: .relaxed) >= idle {
                            shutdown(a, SHUT_RDWR); shutdown(b, SHUT_RDWR) // wakes the other direction
                            break copy
                        }
                        continue
                    }
                    guard n > 0 else { break }
                    last.at.store(Int(ProcessInfo.processInfo.systemUptime), ordering: .relaxed)
                    var off = 0
                    while off < n {
                        let w = buf[off..<n].withUnsafeBytes { write(to, $0.baseAddress, $0.count) }
                        if w <= 0 { break copy }
                        off += w
                    }
                }
                shutdown(to, SHUT_WR)
                group.leave()
            }.start()
        }
        // done() first: a caller's list of open fds must drop these before the numbers can be reused.
        group.notify(queue: .global()) { done(); close(a); close(b) }
    }
}

/// When a piped connection last carried a byte (uptime seconds).
private final class LastByte: Sendable {
    let at = Atomic<Int>(Int(ProcessInfo.processInfo.systemUptime))
}
