import Foundation
import Testing
@testable import SwiftTerminal

struct AICommandScanPolicyTests {
    @Test func boundedAndTargetedScansAreAllowed() {
        let commands = [
            "find /Users/mac/Projects/App -maxdepth 3 -type f",
            "find /opt/example -maxdepth 3 -type f -name '*.swift'",
            "find /opt/example -maxdepth=3 -type f -name '*.swift'",
            "rg --max-depth 2 TODO /Users/mac/Projects/App",
            "du -sh /Users/mac/Projects/App",
            "du -sh /Users/mac/Projects/App 2>/dev/null",
            "rg --files --max-depth 2 -g '*.swift' /Users/mac/Projects/App",
            "env -C / du -sh /opt/example",
            "rg -n version Makefile",
            "rg -n version Justfile",
            "git status --short | rg modified",
            "printf '%s\\n' modified | rg modified",
            "git diff --name-only | grep -n modified",
            "printf '%s\\n' foo | xargs echo",
            "ssh root@node2 'find /opt/example -maxdepth 2 -name app.log'",
        ]

        for command in commands {
            #expect(AICommandScanPolicy.violation(for: command) == nil)
        }
    }

    @Test func unboundedWideScansAreRejected() {
        let commands = [
            "find /",
            "du -sh /",
            "du -sh /root",
            "du -sh /proc",
            "du -sh /var/lib/docker/*",
            "du -d 1 /",
            "timeout 15s find /",
            "rg --files /",
            "grep -R needle /Users",
            "ls -R /Volumes",
            "find \"$HOME\" -maxdepth 3 -name Example.app",
            "find /Users/mac/Projects/App -type f | head -20",
            "find /Users/mac/Projects/App -maxdepth 3",
            "rg needle /Users/mac/Projects/App",
            "ssh root@node2 'find . -maxdepth 3 -type f'",
            "cd /; find . -maxdepth 2 -type f",
            "false || rg needle",
            "git diff --name-only | grep -R modified",
        ]

        for command in commands {
            #expect(AICommandScanPolicy.violation(for: command) != nil)
        }
    }

    @Test func unwrapsSSHAndCommonCommandWrappers() {
        let incident = "ssh admin@center 'du -sh /var/lib/docker/* 2>/dev/null; du -sh /var/lib/docker/overlay2 2>/dev/null' | tail -20"
        let incidentViolation = AICommandScanPolicy.violation(for: incident)

        #expect(incidentViolation?.contains("docker system df") == true)
        #expect(AICommandScanPolicy.violation(for: "sudo timeout 10s bash -lc 'find /'") != nil)
    }

    @Test func recognizesFindTraversalBoundsAndWorkingDirectory() {
        #expect(AICommandScanPolicy.violation(for: "find / -maxdepth 2 -type f") != nil)
        #expect(AICommandScanPolicy.violation(for: "find / -prune -type f") != nil)
        #expect(AICommandScanPolicy.violation(for: "find .", workingDirectory: "/") != nil)
        #expect(AICommandScanPolicy.violation(
            for: "find . -maxdepth 2 -type f",
            workingDirectory: "/Users/mac/Projects/App"
        ) != nil)
        #expect(AICommandScanPolicy.violation(
            for: "find . -maxdepth 2 -type f",
            workingDirectory: "/Users/mac/Projects/App",
            workingDirectoryIsTrusted: true
        ) == nil)
        #expect(AICommandScanPolicy.violation(for: "", workingDirectory: "/") == nil)
    }

    @Test func relativeTargetsRequireATrustedWorkingDirectory() {
        #expect(AICommandScanPolicy.violation(
            for: "du -sh .",
            workingDirectory: "/Users/mac/Projects/App"
        ) != nil)
        #expect(AICommandScanPolicy.violation(for: "du -sh /opt/example") == nil)
        #expect(AICommandScanPolicy.violation(
            for: "du -sh .",
            workingDirectory: "/opt/example",
            workingDirectoryIsTrusted: true
        ) == nil)
    }

    @Test func envChdirDoesNotHideRelativeScanTargets() {
        let commands = [
            "env -C / du -sh .",
            "env --chdir / du -sh .",
            "env --chdir= du -sh .",
            "env -C '' du -sh .",
        ]
        for command in commands {
            #expect(AICommandScanPolicy.violation(for: command) != nil)
        }

        #expect(AICommandScanPolicy.violation(for: "env -C / du -sh /opt/example") == nil)
    }

    @Test func dynamicScansAndDepthExhaustionFailClosed() {
        #expect(AICommandScanPolicy.violation(for: "echo / | xargs du -sh") != nil)
        #expect(AICommandScanPolicy.violation(for: #"echo "$(du -sh /)""#) != nil)
        #expect(AICommandScanPolicy.violation(
            for: "echo / | xargs du -sh /opt/example",
            workingDirectory: "/opt/example",
            workingDirectoryIsTrusted: true
        ) != nil)
        #expect(AICommandScanPolicy.violation(
            for: #"echo `du -sh /`"#,
            workingDirectory: "/opt/example",
            workingDirectoryIsTrusted: true
        ) != nil)
        #expect(AICommandScanPolicy.violation(
            for: #"echo "`du -sh /`""#,
            workingDirectory: "/opt/example",
            workingDirectoryIsTrusted: true
        ) != nil)
        #expect(AICommandScanPolicy.violation(
            for: "timeout 1s timeout 1s timeout 1s timeout 1s timeout 1s timeout 1s timeout 1s timeout 1s timeout 1s find /opt/example -maxdepth 3 -type f -name '*.swift'"
        ) != nil)
    }

    @Test func findRequiresMaxDepthAndSelectionFilter() {
        #expect(AICommandScanPolicy.violation(for: "find /opt/example -type f -prune") != nil)
        #expect(AICommandScanPolicy.violation(
            for: "find /opt/example -type d -name node_modules -prune -o -type f"
        ) != nil)
        #expect(AICommandScanPolicy.violation(for: "find /opt/example -maxdepth 3") != nil)
        #expect(AICommandScanPolicy.violation(for: "find /opt/example -maxdepth -1 -type f") != nil)
        #expect(AICommandScanPolicy.violation(for: "find / -maxdepth 2 -type f") != nil)
    }

    @Test func macOSDataVolumeAliasUsesProtectedUserScope() {
        #expect(AICommandScanPolicy.violation(for: "du -sh /Users/mac") != nil)
        #expect(AICommandScanPolicy.violation(for: "du -sh /System/Volumes/Data/Users/mac") != nil)
        #expect(AICommandScanPolicy.violation(for: "du -sh /Users/mac/Projects/App") == nil)
    }

    @Test func extensionlessFilesAndPipedFiltersAreNotDirectoryScans() {
        #expect(AICommandScanPolicy.violation(for: "rg -n version Makefile") == nil)
        #expect(AICommandScanPolicy.violation(for: "rg -n version Dockerfile") == nil)
        #expect(AICommandScanPolicy.violation(for: "git status --short | rg modified") == nil)
        #expect(AICommandScanPolicy.violation(for: "git diff --name-only | grep -n modified") == nil)
        #expect(AICommandScanPolicy.violation(for: "tree") != nil)
    }

    @Test func metadataCommandsAndOutputStringsAreNotScans() {
        let commands = [
            "df -h",
            "docker system df",
            "mdfind 'kMDItemFSName == README.md'",
            "brew list",
            "echo 'du -sh /; find /'",
            "printf '%s\\n' 'find /'",
            #"echo '`du -sh /`'"#,
            "swift build",
            "find ''",
            "rg needle README.md",
            "grep needle README.md",
            "command -v find",
            "command -v du",
            "du --version",
        ]

        for command in commands {
            #expect(AICommandScanPolicy.violation(for: command) == nil)
        }
    }
}
