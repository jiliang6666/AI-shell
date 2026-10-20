import Foundation
import NetFS

struct SavedCommand: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var description: String
    var command: String
    var parameters: [CommandParameter] = []
    var hostID: UUID?
    var workingDirectory: String
    var updatedAt = Date()

    private enum CodingKeys: String, CodingKey {
        case id, name, description, command, parameters, hostID, workingDirectory, updatedAt
    }

    init(
        id: UUID = UUID(), name: String, description: String, command: String,
        parameters: [CommandParameter] = [], hostID: UUID?, workingDirectory: String, updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.command = command
        self.parameters = parameters
        self.hostID = hostID
        self.workingDirectory = workingDirectory
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? ""
        parameters = try values.decodeIfPresent([CommandParameter].self, forKey: .parameters) ?? []
        hostID = try values.decodeIfPresent(UUID.self, forKey: .hostID)
        workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory) ?? "~"
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

struct CommandParameter: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var prompt: String
    var defaultValue: String
}

struct CommandTemplateResolver {
    static func resolve(template: String, parameters: [CommandParameter], values: [UUID: String]) -> Result<String, Error> {
        var parametersByName: [String: CommandParameter] = [:]
        for parameter in parameters {
            let name = parameter.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.range(of: #"^[\p{L}_][\p{L}\p{N}_]*$"#, options: .regularExpression) != nil else {
                return .failure(ResolutionError.invalidParameterName(parameter.name))
            }
            guard parametersByName[name] == nil else { return .failure(ResolutionError.duplicateParameterName(name)) }
            parametersByName[name] = parameter
        }

        let expression = try! NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#)
        let source = template as NSString
        let matches = expression.matches(in: template, range: NSRange(location: 0, length: source.length))
        var result = template
        for match in matches.reversed() {
            let name = source.substring(with: match.range(at: 1))
            guard let parameter = parametersByName[name] else {
                return .failure(ResolutionError.unknownParameter(name))
            }
            let value = values[parameter.id] ?? parameter.defaultValue
            result = (result as NSString).replacingCharacters(in: match.range, with: shellQuoted(value))
        }
        guard !result.contains("{{"), !result.contains("}}") else {
            return .failure(ResolutionError.unresolvedPlaceholder)
        }
        return .success(result)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum ResolutionError: LocalizedError {
        case invalidParameterName(String)
        case duplicateParameterName(String)
        case unknownParameter(String)
        case unresolvedPlaceholder

        var errorDescription: String? {
            switch self {
            case .invalidParameterName(let name): return "参数名“\(name)”无效；请使用字母、数字和下划线，并以字母或下划线开头。"
            case .duplicateParameterName(let name): return "参数“\(name)”重复定义，请修改后再运行。"
            case .unknownParameter(let name): return "命令使用了未定义的参数“\(name)”，请补充参数定义。"
            case .unresolvedPlaceholder: return "命令中存在未定义的 {{参数名}} 占位符，请补充参数定义。"
            }
        }
    }
}

struct SMBMountProfile: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var server: String
    var share: String
    var username: String
    var password: String
    var mountPath: String
    var mountMode: SMBMountMode = .system
    var initialSubdirectory: String = ""
    var updatedAt = Date()

    init(id: UUID = UUID(), name: String, server: String, share: String, username: String,
         password: String, mountPath: String, mountMode: SMBMountMode? = nil,
         initialSubdirectory: String = "", updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.server = server; self.username = username
        self.password = password; self.mountPath = mountPath; self.updatedAt = updatedAt
        self.mountMode = mountMode ?? (mountPath.isEmpty || mountPath.hasPrefix("/Volumes/") ? .system : .custom)
        let parts = share.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").map(String.init)
        self.share = parts.first ?? ""
        self.initialSubdirectory = initialSubdirectory.isEmpty ? parts.dropFirst().joined(separator: "/") : initialSubdirectory
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, server, share, username, password, mountPath, mountMode, initialSubdirectory, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  server: try c.decode(String.self, forKey: .server), share: try c.decode(String.self, forKey: .share),
                  username: try c.decode(String.self, forKey: .username), password: try c.decode(String.self, forKey: .password),
                  mountPath: try c.decode(String.self, forKey: .mountPath),
                  mountMode: try c.decodeIfPresent(SMBMountMode.self, forKey: .mountMode),
                  initialSubdirectory: try c.decodeIfPresent(String.self, forKey: .initialSubdirectory) ?? "",
                  updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date())
    }
}

struct WorkspaceData: Codable {
    var savedCommands: [SavedCommand] = []
    var smbMounts: [SMBMountProfile] = []
}

enum HistoryRetentionPolicy {
    static func apply<Element>(
        to entries: [Element],
        days: Int,
        now: Date = Date(),
        date: KeyPath<Element, Date>,
        maximumCount: Int = 300
    ) -> [Element] {
        let withinAge = days > 0
            ? entries.filter { $0[keyPath: date] >= now.addingTimeInterval(-Double(days) * 86_400) }
            : entries
        return Array(withinAge.sorted { $0[keyPath: date] > $1[keyPath: date] }.prefix(max(0, maximumCount)))
    }
}

private struct PersistedTerminalSession: Codable {
    var id: UUID
    var hostID: UUID?
    var startingDirectory: String?
}

private struct PersistedTerminalState: Codable {
    var sessions: [PersistedTerminalSession]
    var selectedID: UUID?
}

enum TerminalSessionStore {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftTerminal", isDirectory: true)
    }
    private static var file: URL { directory.appendingPathComponent("terminal-sessions.json") }

    static func load(hosts: [SSHHost]) -> (sessions: [TerminalSession], selectedID: UUID?) {
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONDecoder().decode(PersistedTerminalState.self, from: data) else {
            let session = TerminalSession(host: nil)
            return ([session], session.id)
        }
        let sessions = state.sessions.compactMap { saved -> TerminalSession? in
            if let hostID = saved.hostID {
                guard let host = hosts.first(where: { $0.id == hostID }) else { return nil }
                return TerminalSession(id: saved.id, host: host, startingDirectory: saved.startingDirectory)
            }
            return TerminalSession(id: saved.id, host: nil, startingDirectory: saved.startingDirectory)
        }
        guard !sessions.isEmpty else {
            let session = TerminalSession(host: nil)
            return ([session], session.id)
        }
        return (sessions, sessions.contains(where: { $0.id == state.selectedID }) ? state.selectedID : sessions[0].id)
    }

    static func save(sessions: [TerminalSession], selectedID: UUID?) {
        let state = PersistedTerminalState(
            sessions: sessions.map { PersistedTerminalSession(id: $0.id, hostID: $0.host?.id, startingDirectory: $0.startingDirectory) },
            selectedID: selectedID
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { NSLog("SwiftTerminal: could not save terminal tabs: %@", String(describing: error)) }
    }
}

struct ExecutionRecord: Codable, Identifiable {
    var id = UUID()
    var targetName: String
    var hostID: UUID?
    var command: String
    var output: String
    var exitCode: Int32
    var startedAt: Date
    var workingDirectory: String?
    var terminalSessionID: UUID?

    enum CodingKeys: String, CodingKey { case id, targetName, hostID, command, output, exitCode, startedAt, workingDirectory, terminalSessionID }

    init(
        id: UUID = UUID(),
        targetName: String,
        hostID: UUID?,
        command: String,
        output: String,
        exitCode: Int32,
        startedAt: Date,
        workingDirectory: String? = nil,
        terminalSessionID: UUID? = nil
    ) {
        self.id = id
        self.targetName = targetName
        self.hostID = hostID
        self.command = command
        self.output = output
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.workingDirectory = workingDirectory
        self.terminalSessionID = terminalSessionID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        targetName = try values.decode(String.self, forKey: .targetName)
        hostID = try values.decodeIfPresent(UUID.self, forKey: .hostID)
        command = try values.decode(String.self, forKey: .command)
        output = try values.decode(String.self, forKey: .output)
        exitCode = try values.decode(Int32.self, forKey: .exitCode)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory)
        terminalSessionID = try values.decodeIfPresent(UUID.self, forKey: .terminalSessionID)
    }
}

struct ConversationRecord: Codable, Identifiable {
    var id: UUID
    var targetHostID: UUID?
    var targetName: String
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date
    var terminalSessionID: UUID? = nil
}

enum ConversationArchive {
    private static let lock = NSLock()
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftTerminal", isDirectory: true)
    }
    private static var file: URL { directory.appendingPathComponent("conversations.json") }

    static func loadAll() -> [ConversationRecord] {
        if newStoreIsReady {
            let state = MainActor.assumeIsolated {
                let coordinator = AISessionCoordinator.shared
                return (coordinator.records, coordinator.bootstrapErrorMessage != nil)
            }
            if state.0.isEmpty && state.1 { return loadLegacyReadOnly() }
            return pruned(state.0)
        }
        return loadLegacyReadOnly()
    }

    private static func loadLegacyReadOnly() -> [ConversationRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([ConversationRecord].self, from: data) else { return [] }
        return pruned(entries)
    }

    static func latest(targetHostID: UUID?) -> ConversationRecord? {
        loadAll().first { $0.targetHostID == targetHostID }
    }

    static func save(_ record: ConversationRecord) {
        if newStoreIsReady {
            Task { await AISessionCoordinator.shared.sync(record) }
            return
        }
        lock.lock()
        defer { lock.unlock() }
        var entries: [ConversationRecord] = []
        if let data = try? Data(contentsOf: file) {
            entries = (try? JSONDecoder().decode([ConversationRecord].self, from: data)) ?? []
        }
        if let index = entries.firstIndex(where: { $0.id == record.id }) { entries[index] = record }
        else { entries.insert(record, at: 0) }
        entries = pruned(entries)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { NSLog("SwiftTerminal: could not archive conversation: %@", String(describing: error)) }
        notifyChanged()
        Task { await AISessionCoordinator.shared.sync(record) }
    }

    static func delete(id: UUID) {
        if newStoreIsReady {
            Task { await AISessionCoordinator.shared.delete(id: id) }
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file),
              var entries = try? JSONDecoder().decode([ConversationRecord].self, from: data) else { return }
        entries.removeAll { $0.id == id }
        do {
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { NSLog("SwiftTerminal: could not delete conversation: %@", String(describing: error)) }
        notifyChanged()
        Task { await AISessionCoordinator.shared.delete(id: id) }
    }

    static func clearAll() {
        if newStoreIsReady {
            Task { await AISessionCoordinator.shared.clearAll() }
            return
        }
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode([ConversationRecord]()).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { NSLog("SwiftTerminal: could not clear conversations: %@", String(describing: error)) }
        notifyChanged()
        Task { await AISessionCoordinator.shared.clearAll() }
    }

    static func pruneExpired() {
        if newStoreIsReady {
            Task { await AISessionCoordinator.shared.pruneExpired() }
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([ConversationRecord].self, from: data) else { return }
        do {
            try JSONEncoder().encode(pruned(entries)).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { NSLog("SwiftTerminal: could not prune conversations: %@", String(describing: error)) }
        Task { await AISessionCoordinator.shared.pruneExpired() }
    }

    private static func pruned(_ entries: [ConversationRecord]) -> [ConversationRecord] {
        HistoryRetentionPolicy.apply(to: entries, days: AppPreferences.load().historyRetentionDays, date: \.updatedAt)
    }

    private static var newStoreIsReady: Bool {
        Thread.isMainThread && MainActor.assumeIsolated { AISessionCoordinator.shared.didBootstrap }
    }

    /// The lock above is not recursive, so observers are notified on the next
    /// main-queue turn instead of while the file operation still holds it.
    private static func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .conversationArchiveChanged, object: nil)
        }
    }
}

enum ExecutionHistoryStore {
    private static let lock = NSLock()
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftTerminal", isDirectory: true)
    }
    private static var file: URL { directory.appendingPathComponent("execution-history.json") }
    private static var deletedTerminalsFile: URL { directory.appendingPathComponent("execution-history-deleted-terminals.json") }

    static func load() -> [ExecutionRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([ExecutionRecord].self, from: data),
              let deletedTerminalIDs = try? readDeletedTerminalIDs(from: deletedTerminalsFile) else { return [] }
        return pruned(entries.filter { record in
            guard let terminalSessionID = record.terminalSessionID else { return true }
            return !deletedTerminalIDs.contains(terminalSessionID)
        })
    }

    static func append(_ record: ExecutionRecord, at historyURL: URL? = nil, tombstonesAt tombstonesURL: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let destination = historyURL ?? file
        let tombstones = tombstonesURL ?? deletedTerminalsFile
        if let terminalSessionID = record.terminalSessionID {
            guard let deletedTerminalIDs = try? readDeletedTerminalIDs(from: tombstones),
                  !deletedTerminalIDs.contains(terminalSessionID) else { return }
        }
        var entries: [ExecutionRecord] = []
        if let data = try? Data(contentsOf: destination) {
            entries = (try? JSONDecoder().decode([ExecutionRecord].self, from: data)) ?? []
        }
        entries.insert(record, at: 0)
        entries = pruned(entries)
        do {
            try prepareDirectory(for: destination)
            try JSONEncoder().encode(entries).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch { NSLog("SwiftTerminal: could not save execution history: %@", String(describing: error)) }
    }

    static func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode([ExecutionRecord]()).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { NSLog("SwiftTerminal: could not clear execution history: %@", String(describing: error)) }
    }

    /// Remove every command/output copy owned by a terminal before its tab is discarded.
    static func markTerminalDeleted(_ terminalSessionID: UUID, tombstonesAt tombstonesURL: URL? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        try markTerminalDeleted(terminalSessionID, in: tombstonesURL ?? deletedTerminalsFile)
    }

    static func deleteHistory(
        terminalSessionID: UUID,
        at historyURL: URL? = nil,
        tombstonesAt tombstonesURL: URL? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let destination = historyURL ?? file
        let tombstones = tombstonesURL ?? deletedTerminalsFile
        do {
            try markTerminalDeleted(terminalSessionID, in: tombstones)
            try removeDeletedTerminalRecords(from: destination, tombstones: tombstones)
        } catch let error as AISessionStoreError {
            throw error
        } catch {
            throw AISessionStoreError.persistenceFailed(String(describing: error))
        }
    }

    /// Retry a prior deletion after a crash or file-system error. Tombstones are durable and
    /// also prevent a late command completion from recreating deleted terminal history.
    static func resumeTerminalDeletions(at historyURL: URL? = nil, tombstonesAt tombstonesURL: URL? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try removeDeletedTerminalRecords(from: historyURL ?? file, tombstones: tombstonesURL ?? deletedTerminalsFile)
        } catch let error as AISessionStoreError {
            throw error
        } catch {
            throw AISessionStoreError.persistenceFailed(String(describing: error))
        }
    }

    private static func markTerminalDeleted(_ terminalSessionID: UUID, in tombstonesURL: URL) throws {
        var deletedTerminalIDs = try readDeletedTerminalIDs(from: tombstonesURL)
        guard deletedTerminalIDs.insert(terminalSessionID).inserted else { return }
        try prepareDirectory(for: tombstonesURL)
        try JSONEncoder().encode(deletedTerminalIDs.map(\.uuidString).sorted()).write(to: tombstonesURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tombstonesURL.path)
    }

    private static func readDeletedTerminalIDs(from url: URL) throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw AISessionStoreError.persistenceFailed("终端删除标记不是普通文件。")
        }
        let values = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        let ids = values.compactMap(UUID.init(uuidString:))
        guard ids.count == values.count else {
            throw AISessionStoreError.persistenceFailed("终端删除标记格式无效。")
        }
        return Set(ids)
    }

    private static func removeDeletedTerminalRecords(from historyURL: URL, tombstones tombstonesURL: URL) throws {
        let deletedTerminalIDs = try readDeletedTerminalIDs(from: tombstonesURL)
        guard !deletedTerminalIDs.isEmpty, FileManager.default.fileExists(atPath: historyURL.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: historyURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw AISessionStoreError.persistenceFailed("执行历史路径不是普通文件，删除尚未完成。")
        }
        let entries = try JSONDecoder().decode([ExecutionRecord].self, from: Data(contentsOf: historyURL))
        let remaining = entries.filter { record in
            guard let terminalSessionID = record.terminalSessionID else { return true }
            return !deletedTerminalIDs.contains(terminalSessionID)
        }
        guard remaining.count != entries.count else { return }
        try JSONEncoder().encode(remaining).write(to: historyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
    }

    private static func prepareDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    }

    static func pruneExpired() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([ExecutionRecord].self, from: data) else { return }
        do {
            try JSONEncoder().encode(pruned(entries)).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { NSLog("SwiftTerminal: could not prune execution history: %@", String(describing: error)) }
    }

    private static func pruned(_ entries: [ExecutionRecord]) -> [ExecutionRecord] {
        HistoryRetentionPolicy.apply(to: entries, days: AppPreferences.load().historyRetentionDays, date: \.startedAt)
    }
}

enum WorkspaceDataStore {
    private static var directory: URL {
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftTerminal", isDirectory: true)
    }
    private static var file: URL { directory.appendingPathComponent("workspace-data.json") }

    static var loadFailureMessage: String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do { _ = try JSONDecoder().decode(WorkspaceData.self, from: Data(contentsOf: file)); return nil }
        catch { return "工作区连接资料无法读取。原文件已保留，请检查文件权限或恢复备份；不会用空资料覆盖它。" }
    }

    static func load() -> WorkspaceData {
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(WorkspaceData.self, from: data) else { return WorkspaceData() }
        return value
    }

    static func save(_ value: WorkspaceData) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if FileManager.default.fileExists(atPath: file.path) {
            let previous = try Data(contentsOf: file)
            guard (try? JSONDecoder().decode(WorkspaceData.self, from: previous)) != nil else {
                throw SMBMountFailure(message: "工作区资料损坏，原文件已保留。请恢复备份后再保存，避免丢失连接资料。")
            }
            let backup = directory.appendingPathComponent("workspace-data.before-smb-v2.json")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try previous.write(to: backup, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
        }
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
