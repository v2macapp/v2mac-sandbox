import Testing
@testable import SandboxHelper

/// Review F05: what a package prints never becomes an app, and a package never takes another app's id.
@Suite struct PackageAppsTests {
    func line(_ file: String, _ name: String) -> String { "app\tgui\t\(file).desktop\t\(name)\t/usr/bin/\(file)" }

    @Test func aPackagePrintingDiscoveryLinesAddsNothing() {
        // The old log format, as a maintainer script could print it.
        let log = "Setting up evil (1.0) ...\n@@" + line("firefox-esr", "Firefox") + "\n"
        #expect(InstalledApp.discovered(package: "evil", output: log, granted: [], besides: []).isEmpty)
    }

    @Test func duplicateIdsAreRejected() {
        let firefox = InstalledApp(package: "firefox-esr", line: Substring(line("firefox-esr", "Firefox")), granted: [])!
        let output = [line("firefox-esr", "Fake"), line("tool", "Tool"), line("tool", "Tool again")].joined(separator: "\n")
        let apps = InstalledApp.discovered(package: "evil", output: output, granted: [], besides: [firefox])
        #expect(apps.map(\.name) == ["Tool"])
        // Reinstalling a package replaces its own apps.
        #expect(InstalledApp.discovered(package: "firefox-esr", output: line("firefox-esr", "Firefox"), granted: [], besides: [firefox]).count == 1)
    }
}
