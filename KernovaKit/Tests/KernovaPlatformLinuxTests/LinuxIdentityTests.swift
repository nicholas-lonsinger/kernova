#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import Foundation
import KernovaAgentCore
import KernovaDigest
import KernovaPlatformLinux
import Testing

@Suite("The Linux agent's identity")
struct LinuxIdentityTests {
    @Test("os-release fields parse bare, single-quoted and double-quoted with shell escapes")
    func osReleaseQuoting() {
        let text = #"""
            # a comment
            NAME="Ubuntu"
            ID=ubuntu
            VERSION_ID="26.04"
            PRETTY_NAME='Ubuntu 26.04 LTS'
            ESCAPED="a \"quoted\" \$word and \\ and \n"
              INDENTED=yes
            not a field
            2BAD=no
            ID_LIKE=debian
            """#
        let fields = LinuxIdentity.osRelease(parsing: text)
        #expect(fields["NAME"] == "Ubuntu")
        #expect(fields["ID"] == "ubuntu")
        #expect(fields["VERSION_ID"] == "26.04")
        #expect(fields["PRETTY_NAME"] == "Ubuntu 26.04 LTS")
        #expect(fields["ESCAPED"] == #"a "quoted" $word and \ and \n"#)
        #expect(fields["INDENTED"] == "yes")
        #expect(fields["2BAD"] == nil)
        #expect(fields["ID_LIKE"] == "debian")
        #expect(fields.count == 7)
    }

    @Test("Fedora's os-release gives its ID and VERSION_ID")
    func fedora() {
        let text = """
            NAME="Fedora Linux"
            VERSION="44 (Workstation Edition)"
            ID=fedora
            VERSION_ID=44
            """
        let fields = LinuxIdentity.osRelease(parsing: text)
        #expect(fields["ID"] == "fedora")
        #expect(fields["VERSION_ID"] == "44")
    }

    @Test("The distribution is os-release's ID, or linux when it names none")
    func distribution() {
        #expect(LinuxIdentity.distribution(["ID": "fedora"]) == "fedora")
        #expect(LinuxIdentity.distribution(["ID": ""]) == "linux")
        #expect(LinuxIdentity.distribution(["NAME": "Linux"]) == "linux")
    }

    @Test("The user root is under XDG_DATA_HOME when it is absolute, else under HOME")
    func userRoot() {
        #expect(
            LinuxIdentity.userInstallRoot(environment: ["HOME": "/home/u", "XDG_DATA_HOME": "/data"])
                == "/data/kernova-agent")
        #expect(
            LinuxIdentity.userInstallRoot(environment: ["HOME": "/home/u", "XDG_DATA_HOME": "relative"])
                == "/home/u/.local/share/kernova-agent")
        #expect(
            LinuxIdentity.userInstallRoot(environment: ["HOME": "/home/u"]) == "/home/u/.local/share/kernova-agent")
        #expect(LinuxIdentity.userInstallRoot(environment: [:]) == nil)
    }

    @Test("A slot of a root holding state.json is of system scope at the system root and user scope elsewhere")
    func scope() {
        let system = "/opt/kernova-agent"
        let roots: Set = ["/opt/kernova-agent/state.json", "/var/home/u/.data/kernova-agent/state.json"]
        func scope(_ executable: String) -> InstallScope {
            LinuxIdentity.scope(ofExecutable: executable, systemRoot: system) { roots.contains($0) }
        }
        #expect(scope("/opt/kernova-agent/slots/a/kernova-agent") == .system)
        // Wherever XDG_DATA_HOME pointed the install, the layout decides.
        #expect(scope("/var/home/u/.data/kernova-agent/slots/b/kernova-agent") == .user)
        #expect(scope("/var/home/u/.local/share/kernova-agent/slots/a/kernova-agent") == .unspecified)
        #expect(scope("/var/home/u/.data/kernova-agent/kernova-agent") == .unspecified)
        #expect(scope("/var/home/u/.data/kernova-agent/slots/a/other") == .unspecified)
        #expect(scope("/opt/checkout/KernovaKit/release/kernova-agent") == .unspecified)
    }

    @Test("A path of the slot layout's shape names its root and slot; any other names none")
    func slot() {
        let slot = LinuxIdentity.slot(ofExecutable: "/var/home/u/.data/kernova-agent/slots/b/kernova-agent")
        #expect(slot?.root == "/var/home/u/.data/kernova-agent")
        #expect(slot?.slot == "b")
        #expect(LinuxIdentity.slot(ofExecutable: "/opt/kernova-agent/kernova-agent") == nil)
        #expect(LinuxIdentity.slot(ofExecutable: "/opt/kernova-agent/slots/a/other") == nil)
        #expect(LinuxIdentity.slot(ofExecutable: "/slots/a/kernova-agent") == nil)
    }

    @Test("The payload hash is the file's SHA-256, and an unreadable file says why")
    func hash() throws {
        let digest = try LinuxIdentity.sha256(ofFileAt: "/dev/null")
        #expect(
            lowercaseHex(digest) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(throws: LinuxIdentityError.executableUnreadable(ENOENT)) {
            try LinuxIdentity.sha256(ofFileAt: "/nonexistent/kernova-agent")
        }
    }

    @Test("This process's own claim is a Linux one with a 32-byte payload hash and the kernel's release")
    func current() throws {
        let claim = try LinuxIdentity.current(role: .systemPeer, versionLabel: "1.0 (2)")
        #expect(claim.os == .linux)
        #expect(claim.role == .systemPeer)
        #expect(claim.payloadHash.count == 32)
        #expect(!claim.osBuild.isEmpty)
        #expect(claim.versionLabel == "1.0 (2)")
        #expect(claim.scope == .unspecified)
    }
}

@Suite("The Linux vsock dialer")
struct LinuxVsockDialerTests {
    @Test(
        "No vsock in the kernel or no transport is permanent; everything else is retried",
        arguments: [
            (EAFNOSUPPORT, DialFailure.permanent), (ENODEV, .permanent), (ECONNREFUSED, .transient),
            (ECONNRESET, .transient), (ETIMEDOUT, .transient), (EACCES, .transient), (EINTR, .transient),
        ])
    func errnoTable(errno: Int32, failure: DialFailure) {
        #expect(LinuxVsockDialer.failure(errno: errno) == failure)
    }
}
#endif
