import Foundation

/// Classifies a shell command as read-only so the "仅可查看" permission can
/// auto-run queries while still requiring confirmation for anything that
/// writes, mutates state, or leaves the machine.
enum ShellCommandSafety {
    /// Programs that only inspect the system. Programs with mutating
    /// subcommands (brew, git, docker, systemctl) are checked further below.
    private static let readOnlyPrograms: Set<String> = [
        "ls", "cat", "head", "tail", "pwd", "uname", "whoami", "id", "groups",
        "date", "df", "du", "ps", "uptime", "env", "printenv", "which",
        "whereis", "file", "wc", "who", "w", "hostname", "sw_vers", "stat",
        "md5", "md5sum", "shasum", "sha256sum", "cksum", "grep", "egrep",
        "fgrep", "cut", "paste", "sort", "uniq", "diff", "comm", "cmp",
        "sleep", "true", "false", "test", "echo", "printf", "cal", "column",
        "jq", "tr", "basename", "dirname", "realpath", "readlink",
        "otool", "nm", "strings", "lipo", "lsof", "netstat",
        "vm_stat", "ioreg", "mount", "diskutil", "brew", "git", "docker",
        "kubectl", "systemctl", "launchctl", "ping", "dig", "nslookup",
        "host", "cd", "defaults",
    ]

    /// Programs that can mutate the system despite the whitelist above.
    private static let mutatingPrograms: Set<String> = [
        "rm", "mv", "cp", "mkdir", "rmdir", "touch", "chmod", "chown", "chgrp",
        "kill", "killall", "pkill", "dd", "mkfs", "hdiutil", "tmutil",
        "softwareupdate", "caffeinate", "open", "osascript", "launchctl",
        "plutil", "tee", "xargs", "eval", "source", "exec",
        "shutdown", "reboot", "halt", "csrutil", "spctl", "installer",
    ]

    private static let readOnlySubcommands: [String: Set<String>] = [
        "brew": ["list", "search", "info", "--version", "-v", "config", "doctor",
                 "prefix", "cellar", "uses", "installed", "outdated", "deps",
                 "options", "readall"],
        "git": ["status", "log", "diff", "show", "branch", "remote", "tag",
                "describe", "shortlog", "rev-parse", "ls-files", "blame",
                "grep", "stash list"],
        "docker": ["ps", "images", "version", "info", "logs", "top",
                   "inspect", "history", "port"],
        "kubectl": ["get", "version", "cluster-info"],
        "systemctl": ["status", "is-active", "is-enabled", "list-units",
                      "list-unit-files", "cat", "show"],
        "launchctl": ["list"],
        "diskutil": ["list", "info"],
        "defaults": ["read"],
    ]

    /// True when every segment of the command (split on `;`, `&&`, `||`, `|`,
    /// and newlines) only reads. Command substitution and output redirection
    /// make a command non-read-only, except for the ubiquitous `2>/dev/null`.
    static func isReadOnly(_ command: String) -> Bool {
        guard !command.contains("$("), !command.contains("`"), !command.contains(">") else {
            return onlyHarmlessRedirects(command)
        }
        return segments(of: command).allSatisfy(isReadOnlySegment)
    }

    private static func onlyHarmlessRedirects(_ command: String) -> Bool {
        guard !command.contains("$("), !command.contains("`") else { return false }
        // Strip the three safe stderr-silencing forms, then re-check: any
        // remaining `>` means output is being redirected somewhere.
        var cleaned = command
        for token in ["2>/dev/null", "2> /dev/null", "&>/dev/null", "&> /dev/null"] {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        guard !cleaned.contains(">"), !cleaned.contains("<") else { return false }
        return segments(of: cleaned).allSatisfy(isReadOnlySegment)
    }

    private static func segments(of command: String) -> [String] {
        command
            .split(whereSeparator: { $0 == ";" || $0 == "\n" })
            .flatMap { $0.split(separator: "&", omittingEmptySubsequences: true) }
            .flatMap { $0.split(separator: "|", omittingEmptySubsequences: true) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func isReadOnlySegment(_ segment: String) -> Bool {
        let tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let program = tokens.first else { return true }
        let name = (program as NSString).lastPathComponent
        guard !mutatingPrograms.contains(name), name != "sudo" else { return false }
        guard readOnlyPrograms.contains(name) else { return false }
        if let subcommands = readOnlySubcommands[name] {
            let arguments = tokens.dropFirst()
            let matched = subcommands.contains { sub in
                let parts = sub.split(separator: " ").map(String.init)
                guard parts.count <= arguments.count else { return false }
                return Array(arguments.prefix(parts.count)) == parts
            }
            guard matched else { return false }
        }
        switch name {
        case "git":
            // `git push`, `git commit`, `git config --global` … are mutations.
            guard let firstArg = tokens.dropFirst().first,
                  !["push", "commit", "merge", "rebase", "reset", "checkout",
                    "clean", "rm", "mv", "apply", "revert", "cherry-pick",
                    "config", "am", "rebase"].contains(firstArg) else { return false }
        case "sed":
            guard !tokens.contains("-i"), !tokens.contains("--in-place") else { return false }
        case "find":
            guard !tokens.contains("-delete"), !tokens.contains("-exec"),
                  !tokens.contains("-ok"), !tokens.contains("-fprint"),
                  !tokens.contains("-fprintf"), !tokens.contains("-fls") else { return false }
        default:
            break
        }
        return true
    }
}
