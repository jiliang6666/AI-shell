import Foundation
import CSQLite

struct ModelProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "默认模型"
    var baseURL = "https://api.openai.com/v1"
    var model = ""
    var apiKey = ""
    var contextWindow: Int64?

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey { case id, name, baseURL, model, apiKey, contextWindow }

    init(id: UUID = UUID(), name: String = "默认模型", baseURL: String = "https://api.openai.com/v1", model: String = "", apiKey: String = "", contextWindow: Int64? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.contextWindow = contextWindow
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "默认模型"
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com/v1"
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        contextWindow = try values.decodeIfPresent(Int64.self, forKey: .contextWindow)
    }
}

enum ModelContextCapacity {
    static let supportedRange: ClosedRange<Int64> = 1024...2_097_152

    static func parse(_ input: String) throws -> Int64? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        let multiplier: Double
        let number: String
        switch text.last {
        case "k": multiplier = 1_000; number = String(text.dropLast())
        case "m": multiplier = 1_000_000; number = String(text.dropLast())
        default: multiplier = 1; number = text
        }
        guard number.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Double(number) else { throw CapacityError.invalid }
        let tokens = value * multiplier
        guard tokens.isFinite, tokens.rounded() == tokens,
              tokens >= Double(supportedRange.lowerBound),
              tokens <= Double(supportedRange.upperBound) else { throw CapacityError.invalid }
        return Int64(tokens)
    }

    static func display(_ capacity: Int64?) -> String {
        guard let capacity else { return "" }
        if capacity % 1_000_000 == 0 { return "\(capacity / 1_000_000)m" }
        if capacity % 1_000 == 0 { return "\(capacity / 1_000)k" }
        return String(capacity)
    }

    enum CapacityError: LocalizedError {
        case invalid
        var errorDescription: String? {
            "上下文容量请输入 1024～2097152 token，可使用 256k、1m。"
        }
    }
}

/// SQLite-backed per-user model library. The API key intentionally lives in
/// this local database, whose directory and file are restricted to the owner.
struct ModelProfileStore {
    private let directory: URL
    private let fileManager: FileManager

    static var live: ModelProfileStore { ModelProfileStore() }

    init(
        directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftTerminal", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    private var databaseFile: URL { directory.appendingPathComponent("model-library.sqlite3") }
    private var profilesFile: URL { directory.appendingPathComponent("model-profiles.json") }
    private var legacyProfileFile: URL { directory.appendingPathComponent("model-profile.json") }
    private var activeFile: URL { directory.appendingPathComponent("active-model-id") }

    func loadAll() throws -> [ModelProfile] {
        let database = try openDatabase()
        let savedProfiles = try readProfiles(from: database)
        if !savedProfiles.isEmpty {
            try removeLegacyFiles()
            return savedProfiles
        }

        let legacyProfiles: [ModelProfile]
        let legacySource: URL
        if fileManager.fileExists(atPath: profilesFile.path) {
            legacyProfiles = try JSONDecoder().decode([ModelProfile].self, from: Data(contentsOf: profilesFile))
            legacySource = profilesFile
        } else if fileManager.fileExists(atPath: legacyProfileFile.path) {
            legacyProfiles = [try JSONDecoder().decode(ModelProfile.self, from: Data(contentsOf: legacyProfileFile))]
            legacySource = legacyProfileFile
        } else {
            return [ModelProfile()]
        }

        guard !legacyProfiles.isEmpty else { return [ModelProfile()] }
        let oldActiveID = (try? String(contentsOf: activeFile, encoding: .utf8)).flatMap(UUID.init(uuidString:))
        let activeID = legacyProfiles.first(where: { $0.id == oldActiveID })?.id ?? legacyProfiles[0].id
        try writeProfiles(legacyProfiles, activeID: activeID, to: database)
        try fileManager.removeItem(at: legacySource)
        if fileManager.fileExists(atPath: activeFile.path) { try fileManager.removeItem(at: activeFile) }
        return legacyProfiles
    }

    func active(from profiles: [ModelProfile]) -> ModelProfile {
        let id = try? activeProfileID()
        return profiles.first(where: { $0.id == id }) ?? profiles.first ?? ModelProfile()
    }

    func saveAll(_ profiles: [ModelProfile], activeID: UUID) throws {
        guard !profiles.isEmpty, profiles.contains(where: { $0.id == activeID }) else {
            throw ModelProfileStoreError.activeProfileMissing
        }
        let database = try openDatabase()
        try writeProfiles(profiles, activeID: activeID, to: database)
        try removeLegacyFiles()
        NotificationCenter.default.post(name: .modelProfilesChanged, object: nil)
    }

    private func openDatabase() throws -> SQLiteConnection {
        try createSecureDirectory()
        let wasCreated = !fileManager.fileExists(atPath: databaseFile.path)
        let database = try SQLiteConnection(url: databaseFile)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseFile.path)
        if wasCreated {
            try database.execute("PRAGMA journal_mode = DELETE;")
        }
        try database.execute("PRAGMA secure_delete = ON;")
        try database.execute("PRAGMA foreign_keys = ON;")
        switch try database.schemaVersion() {
        case 0:
            try database.execute("BEGIN IMMEDIATE TRANSACTION;")
            do {
                try database.execute("CREATE TABLE model_profiles (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, base_url TEXT NOT NULL, model TEXT NOT NULL, api_key TEXT NOT NULL, context_window INTEGER);")
                try database.execute("CREATE TABLE model_library_settings (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);")
                try database.execute("PRAGMA user_version = 2;")
                try database.execute("COMMIT;")
            } catch {
                try? database.execute("ROLLBACK;")
                throw error
            }
        case 1:
            try database.execute("BEGIN IMMEDIATE TRANSACTION;")
            do {
                try database.execute("ALTER TABLE model_profiles ADD COLUMN context_window INTEGER;")
                try database.execute("PRAGMA user_version = 2;")
                try database.execute("COMMIT;")
            } catch {
                try? database.execute("ROLLBACK;")
                throw error
            }
        case 2:
            break
        case let version:
            throw ModelProfileStoreError.unsupportedSchemaVersion(version)
        }
        return database
    }

    private func readProfiles(from database: SQLiteConnection) throws -> [ModelProfile] {
        let statement = try database.prepare("SELECT id, name, base_url, model, api_key, context_window FROM model_profiles ORDER BY rowid;")
        var profiles: [ModelProfile] = []
        while try statement.stepRow() {
            guard let id = UUID(uuidString: statement.text(at: 0)) else {
                throw ModelProfileStoreError.invalidProfileID
            }
            profiles.append(ModelProfile(
                id: id,
                name: statement.text(at: 1),
                baseURL: statement.text(at: 2),
                model: statement.text(at: 3),
                apiKey: statement.text(at: 4),
                contextWindow: statement.optionalInt64(at: 5)
            ))
        }
        return profiles
    }

    private func activeProfileID() throws -> UUID? {
        let database = try openDatabase()
        let statement = try database.prepare("SELECT value FROM model_library_settings WHERE key = 'active_profile_id' LIMIT 1;")
        guard try statement.stepRow() else { return nil }
        return UUID(uuidString: statement.text(at: 0))
    }

    private func writeProfiles(_ profiles: [ModelProfile], activeID: UUID, to database: SQLiteConnection) throws {
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try database.execute("DELETE FROM model_profiles;")
            let insert = try database.prepare("INSERT INTO model_profiles (id, name, base_url, model, api_key, context_window) VALUES (?, ?, ?, ?, ?, ?);")
            for profile in profiles {
                try insert.bind(profile.id.uuidString, at: 1)
                try insert.bind(profile.name, at: 2)
                try insert.bind(profile.baseURL, at: 3)
                try insert.bind(profile.model, at: 4)
                try insert.bind(profile.apiKey, at: 5)
                try insert.bind(profile.contextWindow, at: 6)
                try insert.stepDone()
                try insert.reset()
            }
            let setting = try database.prepare("INSERT INTO model_library_settings (key, value) VALUES ('active_profile_id', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;")
            try setting.bind(activeID.uuidString, at: 1)
            try setting.stepDone()
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    private func createSecureDirectory() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func removeLegacyFiles() throws {
        for url in [profilesFile, legacyProfileFile, activeFile] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

enum ModelProfileStoreError: LocalizedError {
    case activeProfileMissing
    case invalidProfileID
    case connectionClosed
    case sqlite(Int32, String)
    case unsupportedSchemaVersion(Int32)

    var errorDescription: String? {
        switch self {
        case .activeProfileMissing: return "当前模型配置不在保存列表中，请重新选择模型后再保存。"
        case .invalidProfileID: return "本机模型数据库中存在无效的配置 ID。"
        case .connectionClosed: return "本机 SQLite 数据库连接已关闭。"
        case .sqlite(let code, let message): return "本机模型数据库操作失败（SQLite \(code)）：\(message)"
        case .unsupportedSchemaVersion(let version): return "本机模型数据库版本 \(version) 高于当前应用支持的版本。请更新应用后重试。"
        }
    }
}

private final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let status = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开 SQLite 数据库。"
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw ModelProfileStoreError.sqlite(status, message)
        }
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw ModelProfileStoreError.connectionClosed }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw ModelProfileStoreError.sqlite(status, message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw ModelProfileStoreError.connectionClosed }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw error(status)
        }
        return SQLiteStatement(handle: statement, database: self)
    }

    func schemaVersion() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version;")
        guard try statement.stepRow() else { throw ModelProfileStoreError.sqlite(SQLITE_ERROR, "无法读取模型数据库版本。") }
        return statement.integer(at: 0)
    }

    fileprivate func error(_ status: Int32) -> ModelProfileStoreError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite 操作失败。"
        return .sqlite(status, message)
    }

    fileprivate func step(_ statement: OpaquePointer) throws -> Int32 {
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw error(status) }
        return status
    }
}

private final class SQLiteStatement {
    private let handle: OpaquePointer
    private unowned let database: SQLiteConnection

    init(handle: OpaquePointer, database: SQLiteConnection) {
        self.handle = handle
        self.database = database
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ value: String, at index: Int32) throws {
        let status = value.withCString { sqlite3_bind_text(handle, index, $0, -1, Self.transient) }
        guard status == SQLITE_OK else { throw database.error(status) }
    }

    func bind(_ value: Int64?, at index: Int32) throws {
        let status = value.map { sqlite3_bind_int64(handle, index, $0) } ?? sqlite3_bind_null(handle, index)
        guard status == SQLITE_OK else { throw database.error(status) }
    }

    func optionalInt64(at column: Int32) -> Int64? {
        sqlite3_column_type(handle, column) == SQLITE_NULL ? nil : sqlite3_column_int64(handle, column)
    }

    func stepRow() throws -> Bool { try database.step(handle) == SQLITE_ROW }

    func stepDone() throws {
        guard try database.step(handle) == SQLITE_DONE else {
            throw ModelProfileStoreError.sqlite(SQLITE_MISUSE, "SQLite 写入没有完成。")
        }
    }

    func reset() throws {
        let status = sqlite3_reset(handle)
        guard status == SQLITE_OK else { throw database.error(status) }
        let clearStatus = sqlite3_clear_bindings(handle)
        guard clearStatus == SQLITE_OK else { throw database.error(clearStatus) }
    }

    func text(at column: Int32) -> String {
        guard let value = sqlite3_column_text(handle, column) else { return "" }
        return String(cString: UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self))
    }

    func integer(at column: Int32) -> Int32 { sqlite3_column_int(handle, column) }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
