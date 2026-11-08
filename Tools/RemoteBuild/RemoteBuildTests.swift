import Testing

@testable import remote_build

/// The guard checks a directory on the host and rsync mirrors into it; both
/// must name the same one, so only paths the host's shell reads unchanged go
/// to rsync.
@Suite struct HostPathTests {
    @Test(arguments: ["/Users/me/src/meerkat", "/Volumes/Work/meerkat-2.0_x", "/a/../b", "/u@h,v+w"])
    func readAsWritten(path: String) {
        #expect(RemoteBuild.isHostPath(path))
    }

    @Test(arguments: [
        // The shell expands `~`, quoted by the guard but not by rsync.
        "~/src/meerkat", "/Users/me/~", "src/meerkat", "",
        // Split or expanded by the shell.
        "/Users/me/my src", "/Users/me/src\tx", "/Users/me/*", "/Users/me/$HOME", "/Users/me/`x`",
        "/Users/me/a;b", "/Users/me/a'b", "/Users/me/a\"b", "/Users/me/a\\b",
        // Outside the set, so not left to how a given shell or rsync reads them.
        "/Users/me/a:b", "/Users/me/caf\u{E9}",
    ])
    func refused(path: String) {
        #expect(!RemoteBuild.isHostPath(path))
    }
}

/// A pin reaches the host as `buck2 -c section.key=value`; one without a
/// value would leave the host's own setting in force.
@Suite struct PinTests {
    @Test(arguments: [
        "swift.xcode_build=27B52", "rust.release=1.99.1", "buck2_release.version_macos_arm64=2026-10-14-9a18=x",
    ])
    func accepted(pin: String) {
        #expect(RemoteBuild.isPin(pin))
    }

    @Test(arguments: ["swift.xcode_build=", "swift.xcode_build", "xcode_build=27B52", ".x=1", "a.b.c=1", "a.=1"])
    func refused(pin: String) {
        #expect(!RemoteBuild.isPin(pin))
    }
}
