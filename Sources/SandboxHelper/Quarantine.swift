import CoreServices
import Foundation
import Observation

/// Files that appear in `~/V2Mac Sandbox` get `com.apple.quarantine` (plan "Files"), so macOS treats
/// what a mini VM wrote like a download. shortcut: FSEvents can't tell who wrote a file, so files the
/// user drops in for the VM are flagged too; harmless, Gatekeeper only asks before running them.
/// The flag comes after the file (review F23): the Shared folder is a direct channel, and `export`
/// is the way out that never shows a file before it is flagged.
final class QuarantineWatcher: @unchecked Sendable {
    /// What went wrong last, shown in the Sandbox window (review F23: a failure is never silent).
    @MainActor @Observable final class Status {
        static let shared = Status()
        var problem: String?
    }

    private var stream: FSEventStreamRef?
    /// The C callback can't capture; there is one watcher per helper.
    nonisolated(unsafe) static var root = ""
    let folder: URL

    init(folder: URL) { self.folder = folder }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var context = FSEventStreamContext()
        Self.root = Self.real(folder)
        let callback: FSEventStreamCallback = { _, _, count, paths, flags, _ in
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            for i in 0..<min(count, list.count) {
                let f = Int(flags[i])
                // Events were dropped (a flood): flag everything below that folder again.
                if f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                    QuarantineWatcher.markTree(list[i], under: QuarantineWatcher.root)
                    continue
                }
                guard f & (kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemIsSymlink) != 0,
                      f & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemRenamed
                           | kFSEventStreamEventFlagItemXattrMod) != 0 else { continue } // XattrMod: a removed flag comes back
                if QuarantineWatcher.mark(list[i], under: QuarantineWatcher.root) == false { QuarantineWatcher.failed(list[i]) }
            }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        guard let stream, case let queue = DispatchQueue(label: "v2mac.sandbox.quarantine"), (FSEventStreamSetDispatchQueue(stream, queue), FSEventStreamStart(stream)).1 else {
            log("quarantine watch failed")
            Task { @MainActor in Status.shared.problem = String(localized: "Files the mini VMs write are not being marked as downloaded. Use Export to copy them to your Mac.") }
            return
        }
    }

    private static func failed(_ path: String) {
        log("quarantine flag not set on \(path)")
        let name = (path as NSString).lastPathComponent
        Task { @MainActor in Status.shared.problem = String(localized: "“\(name)” could not be marked as downloaded, so macOS won't warn before opening it. Use Export to copy files to your Mac.") }
    }

    private static func markTree(_ path: String, under root: String) {
        guard mark(path, under: root) != false else { return failed(path) }
        let items = FileManager.default.enumerator(atPath: path)
        while let item = items?.nextObject() as? String {
            let full = path + "/" + item
            if mark(full, under: root) == false { failed(full) }
        }
    }

    /// Files, folders (an app bundle is one) and symlinks alike; always our value, so a flag the VM
    /// set itself (say, "already approved") never stands. True once the flag is read back, false when
    /// it could not be set, nil when the item is gone or no longer lies under `root`.
    @discardableResult static func mark(_ path: String, under root: String) -> Bool? {
        let name = "com.apple.quarantine"
        let value = String(format: "0083;%08x;V2Mac Sandbox;", Int(Date().timeIntervalSince1970))
        // One descriptor for check and write: the item itself (a symlink is not followed), and only
        // when it still lies under the watched folder. (O_SYMLINK opens a link itself; with O_NOFOLLOW it fails.)
        let fd = open(path, O_RDONLY | O_SYMLINK | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT || errno == ENOTDIR ? nil : false }
        defer { close(fd) }
        var real = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &real) == 0, String(cString: real).hasPrefix(root) else { return nil }
        func ours() -> Bool {
            var current = [CChar](repeating: 0, count: 128)
            let n = fgetxattr(fd, name, &current, current.count - 1, 0, 0)
            return n > 0 && String(cString: current).hasPrefix("0083;") && String(cString: current).hasSuffix(";V2Mac Sandbox;")
        }
        if ours() { return true } // stops the event loop
        _ = value.withCString { fsetxattr(fd, name, $0, strlen($0), 0, 0) }
        return ours()
    }

    enum ExportError: LocalizedError {
        case outside, notMarked(String)
        var errorDescription: String? {
            switch self {
            case .outside: String(localized: "Only files and folders inside this mini VM's Shared folder can be exported.")
            case .notMarked(let name): String(localized: "“\(name)” could not be marked as downloaded, so it was not exported.")
            }
        }
    }

    /// Copies `source` (in `shared`) to `target` through a hidden staging folder beside it: every item is
    /// flagged and read back before one rename puts it in place, so `target` never holds an unflagged file.
    static func export(_ source: URL, from shared: URL, to target: URL) throws {
        let fm = FileManager.default
        // The item itself, not what a symlink the VM made points to.
        guard real(source.deletingLastPathComponent()).hasPrefix(real(shared)),
              let type = try? fm.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType,
              type == .typeRegular || type == .typeDirectory else { throw ExportError.outside }
        let staging = target.deletingLastPathComponent().appendingPathComponent(".v2mac-export-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(target.lastPathComponent)
        try fm.copyItem(at: source, to: staged) // symlinks inside are copied as links, not followed
        let root = real(staging)
        guard mark(staged.path, under: root) == true else { throw ExportError.notMarked(target.lastPathComponent) }
        let items = fm.enumerator(atPath: staged.path)
        while let item = items?.nextObject() as? String {
            guard mark(staged.path + "/" + item, under: root) == true else { throw ExportError.notMarked(item) }
        }
        // The save panel already asked before replacing.
        if (try? target.checkResourceIsReachable()) == true { try fm.removeItem(at: target) }
        guard rename(staged.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path]) }
    }

    /// As F_GETPATH spells it (Foundation's resolvingSymlinksInPath drops `/private`), with a trailing slash.
    private static func real(_ url: URL) -> String {
        guard let p = realpath(url.path, nil) else { return "\u{0}" } // matches nothing
        defer { free(p) }
        return String(cString: p) + "/"
    }
}
