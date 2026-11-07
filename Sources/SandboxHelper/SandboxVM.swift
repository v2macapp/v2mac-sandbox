import AgentProtocol
import Foundation
import Virtualization

/// The one hidden Linux VM (plan §3): read-only erofs rootfs and kernel from the helper bundle, a
/// sparse data disk in `<data>/sandbox/`, vsock, entropy and a balloon. No network device.
@MainActor final class SandboxVM: NSObject, VZVirtualMachineDelegate {
    enum State: String { case stopped, booting, running, stopping }

    private(set) var state = State.stopped { didSet { if state != oldValue { onState(state) } } }
    var onState: (State) -> Void = { _ in }
    /// Shut down this long after the last user (window or app) is gone (plan: "Resources").
    var idleDelay: Duration = .seconds(5 * 60)

    private let root: URL
    private var vm: VZVirtualMachine?
    private var agent: AgentChannel?
    private var users = 0
    private var idleTask: Task<Void, Never>?
    private var console: FileHandle?
    private let agentQueue = DispatchQueue(label: "v2mac.sandbox.agent")

    var socketDevice: VZVirtioSocketDevice? { vm?.socketDevices.first as? VZVirtioSocketDevice }

    /// Each mini VM's Shared folder by id (plan "Files"), seen in the VM as `/exchange/<id>`. Set again
    /// whenever mini VMs change; the running VM picks it up without a restart.
    var shares: [String: URL] = [:] {
        didSet { (vm?.directorySharingDevices.first as? VZVirtioFileSystemDevice)?.share = share }
    }
    private var share: VZMultipleDirectoryShare {
        VZMultipleDirectoryShare(directories: shares.reduce(into: [:]) { $0[$1.key] = VZSharedDirectory(url: $1.value, readOnly: $1.key.hasPrefix("_")) })
    }

    /// Sends one request to the agent and waits for its answer; nil when the VM is down or the answer
    /// did not come within `timeoutMS`. A failed exchange closes the connection and opens a new one, so a
    /// late answer is never read as the next request's. A request that had not gone out yet waits for the
    /// new connection (within its own deadline); one that went out is never sent twice.
    func call(_ message: AgentMessage, timeoutMS: Int32 = 180_000) async -> AgentMessage? {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeoutMS))
        while ContinuousClock.now < deadline, state == .running {
            guard let channel = agent, !channel.isClosed else { try? await Task.sleep(for: .milliseconds(100)); continue }
            // Only exchanges on agentQueue close a channel, so this check there can't race one.
            let sent: AgentMessage?? = await withCheckedContinuation { continuation in
                agentQueue.async { continuation.resume(returning: channel.isClosed ? .none : .some(channel.exchange(message, timeout: deadline - .now))) }
            }
            guard let answer = sent else { continue } // an earlier request broke the channel first
            if answer == nil, channel.isClosed, agent === channel, state == .running {
                log("the agent did not answer in time or broke the protocol; reconnecting")
                agent = nil
                connectAgent(deadline: .now + .seconds(30))
            }
            return answer
        }
        return nil
    }

    init(root: URL) { self.root = root }

    var dataDisk: URL { root.appendingPathComponent("data.img") }
    static let dataDiskSize: UInt64 = 64 << 30

    /// A window or app starts using the VM: boots it if needed and cancels a pending idle shutdown.
    func retain(ramCapMB: Int) {
        users += 1
        idleTask?.cancel()
        if state == .stopped { boot(ramCapMB: ramCapMB) }
    }

    /// Keeps a running VM up with no window or app, for work of its own; ended with `release`.
    func hold() {
        users += 1
        idleTask?.cancel()
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        idleTask?.cancel()
        idleTask = Task { [idleDelay] in
            try? await Task.sleep(for: idleDelay)
            if !Task.isCancelled { await self.stop() }
        }
    }

    func boot(ramCapMB: Int) {
        guard state == .stopped else { return }
        state = .booting
        do {
            let vm = VZVirtualMachine(configuration: try configuration(ramCapMB: ramCapMB))
            vm.delegate = self
            self.vm = vm
            vm.start { result in
                if case .failure(let error) = result { log("VM did not start: \(error.localizedDescription)"); self.reset() }
                else { self.connectAgent(deadline: .now + .seconds(30)) }
            }
        } catch {
            log("VM configuration failed: \(error.localizedDescription)")
            reset()
        }
    }

    /// Asks the agent to power off (so the data disk is flushed), then forces it after 10 seconds.
    func stop() async {
        guard let vm, state == .booting || state == .running else { return }
        state = .stopping
        _ = agent?.send(AgentMessage.shutdown)
        for _ in 0..<100 where vm.state != .stopped { try? await Task.sleep(for: .milliseconds(100)) }
        if vm.state != .stopped { try? await vm.stop() }
        reset()
    }

    private func configuration(ramCapMB: Int) throws -> VZVirtualMachineConfiguration {
        let resources = Bundle.main.resourceURL!
        let boot = VZLinuxBootLoader(kernelURL: resources.appendingPathComponent("Image"))
        // Eight loopback sound cards, one per open window app with sound (rootfs sandbox.sh gui).
        boot.commandLine = "console=hvc0 root=/dev/vda rootfstype=erofs ro init=/sbin/overlay-init quiet"
            + " snd_aloop.enable=1,1,1,1,1,1,1,1 snd_aloop.pcm_substreams=1,1,1,1,1,1,1,1"
        let config = VZVirtualMachineConfiguration()
        config.bootLoader = boot
        config.cpuCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        config.memorySize = UInt64(ramCapMB) << 20
        try makeDataDisk()
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(
                url: resources.appendingPathComponent("rootfs.erofs"), readOnly: true)),
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: dataDisk, readOnly: false)),
        ]
        let log = root.appendingPathComponent("vm.log")
        // The previous boot's console stays as vm.log.1: a problem is often reported after a restart.
        // shortcut: no cap within one boot (about 35 lines per window app), cap it if a VM ever runs for weeks.
        let previous = root.appendingPathComponent("vm.log.1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: log, to: previous)
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        console = try FileHandle(forWritingTo: log)
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: console)
        config.serialPorts = [serial]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: "shared")
        fs.share = share
        config.directorySharingDevices = [fs]
        // No sound device: each app's sound comes over vsock, asked at use (PtyServer, MacAudio).
        try config.validate()
        return config
    }

    /// Sparse file; the guest formats it on first boot (rootfs `v2mac-data.service`).
    private func makeDataDisk() throws {
        guard !FileManager.default.fileExists(atPath: dataDisk.path) else { return }
        FileManager.default.createFile(atPath: dataDisk.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: dataDisk)
        defer { try? handle.close() }
        try handle.truncate(atOffset: Self.dataDiskSize)
    }

    /// The agent starts late in boot, so connecting is retried until it says hello. Also reconnects a
    /// running VM after a failed call.
    private func connectAgent(deadline: ContinuousClock.Instant) {
        guard state == .booting || state == .running, agent == nil,
              let device = vm?.socketDevices.first as? VZVirtioSocketDevice else { return }
        device.connect(toPort: AgentMessage.port) { result in
            nonisolated(unsafe) var said: VZVirtioSocketConnection?
            if case .success(let connection) = result, Self.readHello(connection.fileDescriptor) { said = connection }
            // Hop to the main queue before the next connect: a connect from inside a handler crashes VZ (M0 0.4).
            DispatchQueue.main.async {
                if let connection = said {
                    // Captures `said`, not `connection`: Xcode 26.6 rejects sending the non-Sendable connection.
                    self.agent = AgentChannel(fd: connection.fileDescriptor) { said?.close() }
                    self.state = .running
                } else if ContinuousClock.now < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.connectAgent(deadline: deadline) }
                } else {
                    log("the agent did not answer within 30 seconds")
                    Task { await self.stop() }
                }
            }
        }
    }

    private nonisolated static func readHello(_ fd: Int32) -> Bool {
        AgentChannel.readMessage(fd, until: .now + .seconds(2)) == .hello(version: AgentMessage.version)
    }

    private func reset() {
        agent = nil
        vm = nil
        try? console?.close()
        console = nil
        state = .stopped
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in if self.state != .stopping { self.reset() } }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            log("VM stopped: \(error.localizedDescription)")
            self.reset()
        }
    }
}

/// One connection to the agent (plan §3). `exchange` runs on the VM's serial agent queue; after any
/// failure (short write, no answer by the deadline, end of stream, bad frame) the connection is closed
/// for good, so an answer that comes late can never be taken for the next request's.
final class AgentChannel: @unchecked Sendable {
    private let fd: Int32
    private let closeConnection: () -> Void
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32, close: @escaping () -> Void) {
        self.fd = fd
        closeConnection = close
    }

    var isClosed: Bool { lock.withLock { closed } }

    /// One request and its answer, both within `timeout` counted from now.
    func exchange(_ message: AgentMessage, timeout: Duration) -> AgentMessage? {
        let deadline = ContinuousClock.now + timeout
        if send(message), let answer = Self.readMessage(fd, until: deadline) { return answer }
        close()
        return nil
    }

    /// Writes one frame unless the channel is closed. Locked so `stop` can send from the main actor.
    func send(_ message: AgentMessage) -> Bool {
        let frame = message.frame
        return lock.withLock { !closed && frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == frame.count }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            closeConnection()
        }
    }

    /// The first whole message, or nil at end of stream, on a bad frame or at the deadline. The
    /// deadline is absolute: a peer sending a byte at a time cannot stretch it.
    static func readMessage(_ fd: Int32, until deadline: ContinuousClock.Instant) -> AgentMessage? {
        var reader = AgentMessage.Reader()
        var buf = [UInt8](repeating: 0, count: 16384)
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while case let left = deadline - .now, left > .zero,
              poll(&poller, 1, Int32(max(1, (left / .milliseconds(1)).rounded(.up)))) > 0 {
            let n = read(fd, &buf, buf.count)
            guard n > 0, let messages = try? reader.feed(buf[0..<n]) else { return nil }
            if let first = messages.first { return first }
        }
        return nil
    }
}

/// stdout, and `sandbox.log` next to the helper; at 1 MB it becomes `sandbox.log.1`, so the two stay under 2 MB.
func log(_ text: String) {
    print("[v2mac-sandbox] \(text)")
    let file = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("sandbox.log").path
    var info = stat()
    if stat(file, &info) == 0, info.st_size > 1 << 20 { rename(file, file + ".1") }
    let fd = open(file, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return }
    let line = Array("\(Date().ISO8601Format()) \(text)\n".utf8)
    _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    close(fd)
}
