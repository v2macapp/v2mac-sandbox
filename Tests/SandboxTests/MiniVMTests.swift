import Foundation
import Testing
@testable import SandboxHelper

/// Mini VMs made in quick succession, before the VM has set up the first one.
@MainActor @Suite struct MiniVMTests {
    @Test func namesAreUniqueAsFileNames() {
        let work = MiniVM.new(name: "Work", exit: nil, taken: [])!
        #expect(MiniVM.unique("Work", among: [work]) == "Work 2")
        #expect(MiniVM.unique("work", among: [work]) == "work 2")
        #expect(MiniVM.unique("Home", among: [work]) == "Home")
        let slash = MiniVM.new(name: "a/b", exit: nil, taken: [])!
        #expect(MiniVM.unique("a:b", among: [slash]) == "a:b 2")
    }

    @Test func addsBeforeSetupGetTheirOwnIndexAndName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minivm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = Gateway(vm: SandboxVM(root: root), root: root)
        let a = try #require(gateway.add(name: "Work"))
        let b = try #require(gateway.add(name: "Work"))
        let c = try #require(gateway.add(cloning: a))
        let d = try #require(gateway.add(cloning: a))
        #expect(Set([a, b, c, d].map(\.index)).count == 4)
        #expect([a, b, c, d].map(\.name) == ["Work", "Work 2", "Work copy", "Work copy 2"])
    }
}
