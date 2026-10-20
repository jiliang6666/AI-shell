import Foundation
import Testing
@testable import SwiftTerminal

@Test("Read-only command classification", arguments: [
    "brew list",
    "brew list --versions",
    "brew search wget",
    "ls -la /tmp",
    "uname -a",
    "git status",
    "git log --oneline -5",
    "docker ps",
    "systemctl status nginx",
    "ls | wc -l",
    "cd /tmp && ls",
    "grep -r foo . 2>/dev/null",
    "uname -a; id; pwd",
    "defaults read com.apple.dock",
    "diskutil list",
])
func readOnlyCommandsAreClassifiedReadOnly(_ command: String) {
    #expect(ShellCommandSafety.isReadOnly(command))
}

@Test("Mutating commands are not classified read-only", arguments: [
    "brew install wget",
    "brew upgrade",
    "rm -rf /tmp/x",
    "touch /tmp/x",
    "git push",
    "git commit -m x",
    "git config --global user.name x",
    "docker rm container",
    "systemctl restart nginx",
    "ls > /tmp/out",
    "echo hi >> /tmp/log",
    "echo $(rm -rf x)",
    "sudo ls",
    "xargs rm < list",
    "sed -i '' s/a/b/ file",
    "find . -delete",
    "launchctl unload service",
])
func mutatingCommandsAreNotReadOnly(_ command: String) {
    #expect(!ShellCommandSafety.isReadOnly(command))
}

@Test("sudo is detected anywhere in a command, not only the first word", arguments: [
    "sudo ls",
    "sudo",
    "for p in disk19s1 disk19s2; do echo \"== $p ==\"; sudo dd if=/dev/r$p bs=4096 count=1; done",
    "cd /tmp && sudo rm -rf x",
    "cat list | sudo tee /etc/conf",
    "if true; then sudo ls; fi",
    "(sudo ls)",
    "echo $(sudo ls)",
])
func sudoIsDetectedInsideLargerCommands(_ command: String) {
    let proposal = ProposedShellCommand(id: "t", command: command, purpose: "x", targetName: "本机")
    #expect(proposal.requiresSudoPassword)
}

@Test("sudo used as an argument does not request a password", arguments: [
    "echo sudo",
    "man sudo",
    "grep sudo file.txt",
    "pseudo-sudo ls",
])
func sudoAsArgumentDoesNotRequestPassword(_ command: String) {
    let proposal = ProposedShellCommand(id: "t", command: command, purpose: "x", targetName: "本机")
    #expect(!proposal.requiresSudoPassword)
}
