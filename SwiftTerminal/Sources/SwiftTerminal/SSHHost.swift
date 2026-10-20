import Foundation

struct SSHHost: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var address: String
    var username: String
    var port: Int = 22
    var authentication: Authentication = .password
    var password = ""
    var privateKeyPath = ""
    var savePassword = true
    var group = ""
    var remoteShell = "bash"

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        username: String,
        port: Int = 22,
        authentication: Authentication = .password,
        password: String = "",
        privateKeyPath: String = "",
        savePassword: Bool = true,
        group: String = ""
        ,
        remoteShell: String = "bash"
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.username = username
        self.port = port
        self.authentication = authentication
        self.password = password
        self.privateKeyPath = privateKeyPath
        self.savePassword = savePassword
        self.group = group
        self.remoteShell = remoteShell
    }

    enum Authentication: String, Codable, CaseIterable, Identifiable, Sendable {
        case password = "密码"
        case privateKey = "私钥"
        case agent = "SSH Agent"
        var id: String { rawValue }
    }

    var displayName: String { name.isEmpty ? address : name }
    var endpoint: String { "\(username)@\(address):\(port)" }
    var trimmedGroup: String { group.trimmingCharacters(in: .whitespacesAndNewlines) }

    private enum CodingKeys: String, CodingKey {
        case id, name, address, username, port, authentication
        case password, privateKeyPath, savePassword, group
        case remoteShell
    }

    /// Older `hosts.json` files have no `group` key; every field falls back to
    /// its default instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        address = try values.decodeIfPresent(String.self, forKey: .address) ?? ""
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        authentication = try values.decodeIfPresent(Authentication.self, forKey: .authentication) ?? .password
        password = try values.decodeIfPresent(String.self, forKey: .password) ?? ""
        privateKeyPath = try values.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
        savePassword = try values.decodeIfPresent(Bool.self, forKey: .savePassword) ?? true
        group = try values.decodeIfPresent(String.self, forKey: .group) ?? ""
        remoteShell = try values.decodeIfPresent(String.self, forKey: .remoteShell) ?? "bash"
    }
}

enum SSHHostGrouping {
    static let ungroupedTitle = "未分组"

    static func filter(_ hosts: [SSHHost], query: String) -> [SSHHost] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return hosts }
        return hosts.filter { host in
            host.name.localizedCaseInsensitiveContains(trimmed)
                || host.address.localizedCaseInsensitiveContains(trimmed)
                || host.username.localizedCaseInsensitiveContains(trimmed)
                || host.trimmedGroup.localizedCaseInsensitiveContains(trimmed)
                || host.endpoint.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Hosts grouped by their group name; ungrouped hosts are listed last.
    static func grouped(_ hosts: [SSHHost]) -> [(title: String, hosts: [SSHHost])] {
        var buckets: [String: [SSHHost]] = [:]
        for host in hosts {
            buckets[host.trimmedGroup, default: []].append(host)
        }
        let named = buckets.keys
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var result = named.map { (title: $0, hosts: sorted(buckets[$0] ?? [])) }
        if let ungrouped = buckets[""], !ungrouped.isEmpty {
            result.append((title: ungroupedTitle, hosts: sorted(ungrouped)))
        }
        return result
    }

    static func knownGroups(_ hosts: [SSHHost]) -> [String] {
        Array(Set(hosts.map(\.trimmedGroup).filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func sorted(_ hosts: [SSHHost]) -> [SSHHost] {
        hosts.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

enum SSHHostStore {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftTerminal", isDirectory: true)
    }

    private static var file: URL { directory.appendingPathComponent("hosts.json") }

    static func load() -> [SSHHost] {
        guard let data = try? Data(contentsOf: file),
              var hosts = try? JSONDecoder().decode([SSHHost].self, from: data) else { return [] }
        var hasLegacyPasswords = false
        for index in hosts.indices where hosts[index].authentication == .password && hosts[index].savePassword {
            let url = credentialFile(for: hosts[index].id)
            if let credential = try? Data(contentsOf: url) {
                hosts[index].password = String(decoding: credential, as: UTF8.self)
            } else if !hosts[index].password.isEmpty {
                hasLegacyPasswords = true
            }
        }
        if hasLegacyPasswords { try? save(hosts) }
        return hosts
    }

    static func save(_ hosts: [SSHHost]) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for host in hosts {
            let credential = credentialFile(for: host.id)
            if host.authentication == .password && host.savePassword && !host.password.isEmpty {
                try Data(host.password.utf8).write(to: credential, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)
            } else {
                try? FileManager.default.removeItem(at: credential)
            }
        }
        let sanitizedHosts = hosts.map { host -> SSHHost in
            var sanitized = host
            sanitized.password = ""
            return sanitized
        }
        try JSONEncoder().encode(sanitizedHosts).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func credentialFile(for hostID: UUID) -> URL {
        directory.appendingPathComponent("ssh-\(hostID.uuidString).credential")
    }

    static func ensureAskpassHelper() throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let helper = directory.appendingPathComponent("ssh-askpass")
        let script = "#!/bin/sh\nexec /bin/cat \"$SWIFTTERMINAL_SSH_PASSWORD_FILE\"\n"
        try Data(script.utf8).write(to: helper, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return helper
    }

    static func askpassConfiguration(for host: SSHHost) throws -> [String] {
        let helper = try ensureAskpassHelper()
        let credential = credentialFile(for: host.id)
        try Data(host.password.utf8).write(to: credential, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)
        return [
            "SSH_ASKPASS=\(helper.path)",
            "SSH_ASKPASS_REQUIRE=force",
            "DISPLAY=SwiftTerminal",
            "SWIFTTERMINAL_SSH_PASSWORD_FILE=\(credential.path)"
        ]
    }

    static func deletePasswordFile(for hostID: UUID) {
        let credential = credentialFile(for: hostID)
        try? FileManager.default.removeItem(at: credential)
    }
}

struct AppPreferences: Codable, Equatable {
    var appearance = "system"
    var terminalFontSize = 13.0
    var assistantFontSize = 14.0
    var defaultPermissionMode = "修改前确认"
    var language = "简体中文"
    var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    var historyRetentionDays = 90
    var shellPath = "/bin/zsh"
    var startDirectory = ""
    var terminalPaletteID = TerminalPalette.system.id
    var terminalCursorID = TerminalCursorPreference.steadyBlock.rawValue
    var scrollbackLines = 5_000
    var showHiddenFiles = false
    var keepRecentTurns = 4
    var triggerRatio = 0.8
    /// How long the assistant waits for a terminal to come back to a prompt
    /// with no pending input before it refuses to type a command into it.
    var aiReadinessTimeoutSeconds = AIReadinessTimeout.defaultSeconds

    var terminalAppearance: TerminalAppearance {
        TerminalAppearance(
            fontSize: terminalFontSize,
            paletteID: terminalPaletteID,
            cursorID: terminalCursorID,
            scrollbackLines: scrollbackLines,
            shellPath: shellPath,
            startDirectory: startDirectory
        )
    }

    private enum CodingKeys: String, CodingKey {
        case appearance, terminalFontSize, assistantFontSize, defaultPermissionMode, language
        case workingDirectory, historyRetentionDays
        case shellPath, startDirectory, terminalPaletteID, terminalCursorID, scrollbackLines
        case showHiddenFiles
        case keepRecentTurns, triggerRatio, aiReadinessTimeoutSeconds
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try values.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        terminalFontSize = try values.decodeIfPresent(Double.self, forKey: .terminalFontSize) ?? 13
        assistantFontSize = try values.decodeIfPresent(Double.self, forKey: .assistantFontSize) ?? 14
        defaultPermissionMode = try values.decodeIfPresent(String.self, forKey: .defaultPermissionMode) ?? "修改前确认"
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "简体中文"
        workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory) ?? FileManager.default.homeDirectoryForCurrentUser.path
        historyRetentionDays = try values.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? 90
        shellPath = try values.decodeIfPresent(String.self, forKey: .shellPath) ?? "/bin/zsh"
        startDirectory = try values.decodeIfPresent(String.self, forKey: .startDirectory) ?? ""
        terminalPaletteID = try values.decodeIfPresent(String.self, forKey: .terminalPaletteID) ?? TerminalPalette.system.id
        terminalCursorID = try values.decodeIfPresent(String.self, forKey: .terminalCursorID) ?? TerminalCursorPreference.steadyBlock.rawValue
        scrollbackLines = try values.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? 5_000
        showHiddenFiles = try values.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? false
        keepRecentTurns = try values.decodeIfPresent(Int.self, forKey: .keepRecentTurns) ?? 4
        triggerRatio = try values.decodeIfPresent(Double.self, forKey: .triggerRatio) ?? 0.8
        let readiness = try values.decodeIfPresent(Int.self, forKey: .aiReadinessTimeoutSeconds) ?? AIReadinessTimeout.defaultSeconds
        aiReadinessTimeoutSeconds = AIReadinessTimeout.clamp(readiness)
    }

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftTerminal/preferences.json")
    }

    static func load() -> AppPreferences {
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(AppPreferences.self, from: data) else { return .init() }
        return value
    }

    func save() throws {
        defer { NotificationCenter.default.post(name: .preferencesChanged, object: nil) }
        let directory = Self.file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }
}
