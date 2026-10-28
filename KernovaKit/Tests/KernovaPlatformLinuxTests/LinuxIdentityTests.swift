#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import Foundation
import KernovaAgentCore
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

    @Test("A binary under the system root is of system scope, under the user root of user scope, else unspecified")
    func scope() {
        let system = "/var/lib/kernova-agent"
        let user = "/var/home/u/.local/share/kernova-agent"
        func scope(_ executable: String, userRoot: String? = user) -> InstallScope {
            LinuxIdentity.scope(ofExecutable: executable, systemRoot: system, userRoot: userRoot)
        }
        #expect(scope("/var/lib/kernova-agent/slots/a/kernova-agent") == .system)
        #expect(scope("/var/home/u/.local/share/kernova-agent/slots/b/kernova-agent") == .user)
        #expect(scope("/var/home/u/.local/share/kernova-agent-dev/kernova-agent") == .unspecified)
        #expect(scope("/var/home/u/.local/share/kernova-agent/slots/a/kernova-agent", userRoot: nil) == .unspecified)
        #expect(scope("/opt/checkout/KernovaKit/release/kernova-agent") == .unspecified)
    }

    @Test("The payload hash is the file's SHA-256, and an unreadable file says why")
    func hash() throws {
        let digest = try LinuxIdentity.sha256(ofFileAt: "/dev/null")
        #expect(
            digest.map { String(format: "%02x", $0) }.joined()
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
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
