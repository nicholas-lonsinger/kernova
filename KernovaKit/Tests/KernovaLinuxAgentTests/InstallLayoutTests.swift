import Testing

@testable import KernovaLinuxAgent

@Suite("The installer's layout")
struct InstallLayoutTests {
    @Test("The user manager's environment reads back as systemctl show-environment prints it")
    func managerEnvironment() {
        let text = """
            HOME=/home/pbear
            XDG_CONFIG_HOME=/home/pbear/dotfiles/config
            XDG_DATA_HOME=$'/home/pbear/My Data\\\\x'
            LANG=en_US.UTF-8
            not a line

            """
        let environment = InstallLayout.environment(parsingShowEnvironment: text)
        #expect(
            environment == [
                "HOME": "/home/pbear", "XDG_CONFIG_HOME": "/home/pbear/dotfiles/config",
                "XDG_DATA_HOME": "/home/pbear/My Data\\x", "LANG": "en_US.UTF-8",
            ])
        #expect(InstallLayout.configHome(environment: environment) == "/home/pbear/dotfiles/config")
    }
}
