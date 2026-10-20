import CSQLite
import CryptoKit
import Darwin
import Foundation

private struct AIDatabaseError: Error {
    var code: Int32
    var message: String
}

private final class AIDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path,
            &pointer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let opened = pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(pointer)
            throw AIDatabaseError(code: status, message: message)
        }
        handle = opened
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw AIDatabaseError(code: SQLITE_MISUSE, message: "数据库已关闭") }
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(error)
            throw AIDatabaseError(code: status, message: message)
        }
    }

    func prepare(_ sql: String) throws -> AIStatement {
        guard let handle else { throw AIDatabaseError(code: SQLITE_MISUSE, message: "数据库已关闭") }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let prepared = statement else {
            sqlite3_finalize(statement)
            throw AIDatabaseError(code: status, message: String(cString: sqlite3_errmsg(handle)))
        }
        return AIStatement(statement: prepared, database: self)
    }

    func error(_ status: Int32) -> AIDatabaseError {
        AIDatabaseError(code: status, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库错误")
    }

    func step(_ statement: OpaquePointer) throws {
        guard handle != nil else { throw AIDatabaseError(code: SQLITE_MISUSE, message: "数据库已关闭") }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else {
            throw error(status)
        }
    }
}

private final class AIStatement {
    let raw: OpaquePointer
    private unowned let database: AIDatabase

    init(statement: OpaquePointer, database: AIDatabase) {
        raw = statement
        self.database = database
    }

    deinit { sqlite3_finalize(raw) }

    func bind(_ value: String?, at index: Int32) throws {
        if let value {
            let status = value.withCString { sqlite3_bind_text(raw, index, $0, -1, Self.transient) }
            guard status == SQLITE_OK else { throw database.error(status) }
        } else {
            guard sqlite3_bind_null(raw, index) == SQLITE_OK else { throw database.error(SQLITE_MISUSE) }
        }
    }

    func bind(_ value: Data?, at index: Int32) throws {
        if let value {
            let result = value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(raw, index, bytes.baseAddress, Int32(value.count), Self.transient)
            }
            guard result == SQLITE_OK else { throw database.error(result) }
        } else {
            guard sqlite3_bind_null(raw, index) == SQLITE_OK else { throw database.error(SQLITE_MISUSE) }
        }
    }

    func bind(_ value: Int64?, at index: Int32) throws {
        if let value {
            guard sqlite3_bind_int64(raw, index, value) == SQLITE_OK else { throw database.error(SQLITE_MISUSE) }
        } else {
            guard sqlite3_bind_null(raw, index) == SQLITE_OK else { throw database.error(SQLITE_MISUSE) }
        }
    }

    func bind(_ value: Int?, at index: Int32) throws {
        try bind(value.map(Int64.init), at: index)
    }

    func stepRow() throws -> Bool {
        let status = sqlite3_step(raw)
        if status == SQLITE_ROW { return true }
        if status == SQLITE_DONE { return false }
        throw database.error(status)
    }

    func stepDone() throws {
        let status = sqlite3_step(raw)
        guard status == SQLITE_DONE else { throw database.error(status) }
    }

    func text(_ column: Int32) -> String? {
        guard sqlite3_column_type(raw, column) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(raw, column))
    }

    func data(_ column: Int32) -> Data? {
        guard sqlite3_column_type(raw, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(raw, column))
        guard count > 0, let bytes = sqlite3_column_blob(raw, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    func int64(_ column: Int32) -> Int64? {
        guard sqlite3_column_type(raw, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(raw, column)
    }

    func int(_ column: Int32) -> Int? {
        int64(column).map(Int.init)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

actor AISessionStore {
    static let schemaVersion = 4
    private static let unassignedLegacyTerminalID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private let databaseFile: URL
    private let executionHistoryTombstonesURL: URL?
    private var database: AIDatabase?
    private var lockFileDescriptor: Int32?
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    init(directory: URL? = nil, executionHistoryTombstonesURL: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftTerminal", isDirectory: true)
        databaseFile = base.appendingPathComponent("ai-sessions.sqlite3")
        self.executionHistoryTombstonesURL = executionHistoryTombstonesURL
        jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = [.sortedKeys]
        jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
    }

    deinit {
        if let lockFileDescriptor {
            flock(lockFileDescriptor, LOCK_UN)
            Darwin.close(lockFileDescriptor)
        }
    }

    private func open() throws -> AIDatabase {
        if let database { return database }
        do {
            let directory = databaseFile.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw AISessionStoreError.persistenceFailed("数据库目录路径包含符号链接。")
            }
            try acquireProcessLock(in: directory)
            if FileManager.default.fileExists(atPath: databaseFile.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: databaseFile.path)
                if let type = attributes[.type] as? FileAttributeType, type == .typeSymbolicLink {
                    throw AISessionStoreError.persistenceFailed("数据库路径是符号链接。")
                }
            }
            let database = try AIDatabase(url: databaseFile)
            // Check compatibility before any PRAGMA can change the file format.
            guard try readSchemaVersion(in: database) <= Self.schemaVersion else {
                throw AISessionStoreError.unsupportedSchema
            }
            try database.execute("PRAGMA foreign_keys=ON; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000; PRAGMA secure_delete=ON;")
            try createSchema(in: database)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseFile.path)
            self.database = database
            return database
        } catch let error as AISessionStoreError {
            releaseProcessLock()
            throw error
        } catch {
            releaseProcessLock()
            throw AISessionStoreError.persistenceFailed(String(describing: error))
        }
    }

    private func releaseProcessLock() {
        guard let descriptor = lockFileDescriptor else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        lockFileDescriptor = nil
    }

    private func acquireProcessLock(in directory: URL) throws {
        guard lockFileDescriptor == nil else { return }
        let path = directory.appendingPathComponent("ai-sessions.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AISessionStoreError.persistenceFailed("无法安全打开 AI 会话锁文件。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw AISessionStoreError.persistenceFailed("AI 会话数据库已由另一个进程使用。")
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw AISessionStoreError.persistenceFailed("无法设置 AI 会话锁文件权限。")
        }
        lockFileDescriptor = descriptor
    }

    private func createSchema(in database: AIDatabase) throws {
        let version = try readSchemaVersion(in: database)
        guard version <= Self.schemaVersion else { throw AISessionStoreError.unsupportedSchema }
        try database.execute("""
        CREATE TABLE IF NOT EXISTS permission_preferences (
          scope TEXT PRIMARY KEY,
          permission TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions (
          session_id TEXT PRIMARY KEY,
          target_json BLOB NOT NULL,
          title TEXT NOT NULL,
          permission TEXT NOT NULL,
          permission_version INTEGER NOT NULL DEFAULT 1,
          profile_id TEXT,
          configuration_by_profile_json BLOB NOT NULL,
          revision INTEGER NOT NULL,
          context_revision INTEGER NOT NULL,
          updated_at TEXT NOT NULL,
          parent_session_id TEXT,
          fork_sequence INTEGER
        );
        CREATE TABLE IF NOT EXISTS events (
          event_id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          sequence INTEGER NOT NULL,
          event_type TEXT NOT NULL,
          turn_id TEXT,
          request_id TEXT,
          timestamp TEXT NOT NULL,
          payload_version INTEGER NOT NULL,
          payload_json BLOB NOT NULL,
          UNIQUE(session_id, sequence)
        );
        CREATE INDEX IF NOT EXISTS events_session_order ON events(session_id, sequence);
        CREATE TABLE IF NOT EXISTS requests (
          request_id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          turn_id TEXT,
          maintenance_id TEXT,
          step_index INTEGER,
          attempt_index INTEGER NOT NULL DEFAULT 0,
          purpose TEXT NOT NULL,
          provider TEXT NOT NULL,
          profile_id TEXT NOT NULL,
          requested_model TEXT NOT NULL,
          actual_model TEXT,
          status TEXT NOT NULL,
          usage_json BLOB,
          request_body BLOB
        );
        CREATE TABLE IF NOT EXISTS compactions (
          compaction_id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          source_revision INTEGER NOT NULL,
          source_event_ids_json BLOB NOT NULL,
          summary_event_id TEXT,
          status TEXT NOT NULL,
          before_estimate INTEGER NOT NULL DEFAULT 0,
          after_estimate INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS migrations (
          migration_key TEXT PRIMARY KEY,
          source_digest TEXT NOT NULL,
          completed_at TEXT NOT NULL,
          imported_session_count INTEGER NOT NULL,
          imported_event_count INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS deleted_terminals (
          terminal_id TEXT PRIMARY KEY,
          cleanup_pending INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS deleted_sessions (
          session_id TEXT PRIMARY KEY,
          terminal_id TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS sessions_terminal ON sessions(JSON_EXTRACT(target_json, '$.terminalSessionID'));
        """)
        let requestColumns = try database.prepare("PRAGMA table_info(requests);")
        var hasRequestBody = false
        while try requestColumns.stepRow() {
            if requestColumns.text(1) == "request_body" { hasRequestBody = true }
        }
        if !hasRequestBody { try database.execute("ALTER TABLE requests ADD COLUMN request_body BLOB;") }
        if version < Self.schemaVersion {
            try database.execute("PRAGMA user_version=\(Self.schemaVersion);")
        }
    }

    private func readSchemaVersion(in database: AIDatabase) throws -> Int {
        let statement = try database.prepare("PRAGMA user_version;")
        guard try statement.stepRow(), let value = statement.int(0) else {
            throw AISessionStoreError.persistenceFailed("无法读取数据库版本。")
        }
        return value
    }

    /// Migrate the latest explicit choice once per scope; never infer a choice
    /// from a new conversation's default. These rows have no session foreign key.
    func permissionPreferences() throws -> [AIPermissionScope: AIPermissionMode] {
        let database = try open()
        do {
            try database.execute("BEGIN IMMEDIATE;")
            var result: [AIPermissionScope: AIPermissionMode] = [:]
            for scope in AIPermissionScope.allCases {
                let saved = try database.prepare("SELECT permission FROM permission_preferences WHERE scope=?;")
                try saved.bind(scope.rawValue, at: 1)
                if try saved.stepRow() {
                    guard let raw = saved.text(0), let mode = AIPermissionMode(rawValue: raw) else {
                        throw AISessionStoreError.persistenceFailed("AI 权限设置无法读取。")
                    }
                    result[scope] = mode
                    continue
                }
                let history = try database.prepare("""
                SELECT s.target_json, e.payload_json FROM events e JOIN sessions s ON s.session_id=e.session_id
                WHERE e.event_type=? ORDER BY e.timestamp DESC, e.rowid DESC;
                """)
                try history.bind(AISessionEventType.permissionChanged.rawValue, at: 1)
                var mode: AIPermissionMode = .readOnly
                while try history.stepRow() {
                    guard let targetData = history.data(0), let payloadData = history.data(1) else {
                        throw AISessionStoreError.persistenceFailed("历史权限记录无法读取。")
                    }
                    let target = try decodeJSON(AITargetSnapshot.self, targetData)
                    guard AIPermissionScope(hostID: target.hostID) == scope else { continue }
                    let payload = try decodeJSON(AISessionEventPayload.self, payloadData)
                    if case .permissionChanged(_, let chosen) = payload { mode = chosen; break }
                }
                try writePermission(mode, scope: scope, in: database)
                result[scope] = mode
            }
            try database.execute("COMMIT;")
            return result
        } catch {
            try? database.execute("ROLLBACK;")
            throw persistence(error)
        }
    }

    private func writePermission(_ mode: AIPermissionMode, scope: AIPermissionScope, in database: AIDatabase) throws {
        let statement = try database.prepare("""
        INSERT INTO permission_preferences(scope,permission) VALUES(?,?)
        ON CONFLICT(scope) DO UPDATE SET permission=excluded.permission;
        """)
        try statement.bind(scope.rawValue, at: 1)
        try statement.bind(mode.rawValue, at: 2)
        try statement.stepDone()
    }

    func create(
        sessionID: UUID? = nil,
        target: AITargetSnapshot,
        modelProfileID: UUID?,
        permission: AIPermissionMode = .readOnly,
        configuration: AIContextConfiguration = .standard
    ) async throws -> AISessionSnapshot {
        let sessionID = sessionID ?? UUID()
        let now = Date()
        let database = try open()
        try requireWritableIdentity(sessionID: sessionID, terminalID: target.terminalSessionID, in: database)
        do {
            try database.execute("BEGIN IMMEDIATE;")
            let statement = try database.prepare("""
            INSERT INTO sessions
            (session_id, target_json, title, permission, permission_version,
             configuration_by_profile_json, revision, context_revision, updated_at)
            VALUES (?,?,?,?,?,?,1,0,?);
            """)
            let configurationJSON = try encodeJSON([modelProfileID?.uuidString ?? "current": configuration])
            try statement.bind(sessionID.uuidString, at: 1)
            try statement.bind(try encodeJSON(target), at: 2)
            try statement.bind("新对话", at: 3)
            try statement.bind(permission.rawValue, at: 4)
            try statement.bind(Int64(1), at: 5)
            try statement.bind(configurationJSON, at: 6)
            try statement.bind(ISODate.encode(now), at: 7)
            try statement.stepDone()

            let payload = AISessionEventPayload.sessionCreated(
                target: target,
                permission: permission,
                profileID: modelProfileID
            ).data
            let event = AINewSessionEvent(sessionID: sessionID, type: .sessionCreated, payload: payload)
            try insert(event, nextSequence: 1, timestamp: now, in: database)
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw persistence(error)
        }
        return AISessionSnapshot(
            id: sessionID,
            target: target,
            permission: permission,
            permissionVersion: 1,
            modelProfileID: modelProfileID,
            configuration: configuration,
            revision: 1,
            contextRevision: 0,
            messages: [],
            turnStates: [:],
            summaryIDs: [],
            contextSummary: nil,
            summarizedMessageIDs: [],
            parentSessionID: nil,
            forkSequence: nil
        )
    }

    func append(_ events: [AINewSessionEvent], expectedRevision: Int64,
                permissionPreference: (scope: AIPermissionScope, mode: AIPermissionMode)? = nil) async throws -> AIAppendReceipt {
        guard !events.isEmpty else { throw AISessionStoreError.invalidArguments }
        let sessionID = events[0].sessionID
        guard events.allSatisfy({ $0.sessionID == sessionID }) else { throw AISessionStoreError.invalidArguments }
        let database = try open()
        do {
            try database.execute("BEGIN IMMEDIATE;")
            guard let current = try readSessionCore(sessionID, in: database) else {
                throw AISessionStoreError.sessionMissing
            }
            try requireWritableIdentity(sessionID: sessionID, terminalID: nil, in: database)

            var unique: [AINewSessionEvent] = []
            var duplicateEvents: [UUID: AINewSessionEvent] = [:]
            for event in events {
                if let existing = try readEvent(event.eventID, in: database) {
                    guard existing.sessionID == event.sessionID,
                          existing.type == event.type,
                          existing.turnID == event.turnID,
                          existing.requestID == event.requestID,
                          existing.payload == event.payload,
                          existing.payloadVersion == event.payloadVersion else {
                        throw AISessionStoreError.staleRevision
                    }
                    duplicateEvents[event.eventID] = event
                } else {
                    unique.append(event)
                }
            }

            guard duplicateEvents.isEmpty || unique.isEmpty else {
                throw AISessionStoreError.staleRevision
            }
            if unique.isEmpty {
                try database.execute("COMMIT;")
                let sequences = events.compactMap { event in
                    try? readEvent(event.eventID, in: database)?.sequence
                }
                return AIAppendReceipt(
                    revision: current.revision,
                    contextRevision: current.contextRevision,
                    eventIDs: events.map(\.eventID),
                    firstSequence: sequences.min() ?? 0,
                    lastSequence: sequences.max() ?? 0,
                    deduplicated: true
                )
            }
            guard current.revision == expectedRevision else { throw AISessionStoreError.staleRevision }
            if let preference = permissionPreference {
                let session = try snapshot(sessionID, in: database)
                guard AIPermissionScope(hostID: session.target.hostID) == preference.scope,
                      unique.count == 1, unique[0].type == .permissionChanged,
                      case .permissionChanged(_, let mode) = try decodeJSON(AISessionEventPayload.self, unique[0].payload),
                      mode == preference.mode else { throw AISessionStoreError.invalidArguments }
                try writePermission(mode, scope: preference.scope, in: database)
            }

            var nextSequence = try maxSequence(sessionID, in: database) + 1
            let firstSequence = nextSequence
            var contextDelta: Int64 = 0
            let timestamp = Date()
            for event in unique {
                try insert(event, nextSequence: nextSequence, timestamp: timestamp, in: database)
                if event.type.advancesModelContext { contextDelta += 1 }
                nextSequence += 1
            }
            let newRevision = current.revision + Int64(unique.count)
            let newContextRevision = current.contextRevision + contextDelta
            let existingTitle = try readSessionTitle(sessionID, in: database)
            let newTitle: String? = existingTitle == "新对话"
                ? unique.lazy.compactMap { event -> String? in
                    guard event.type == .userMessage,
                          let payload = try? self.decodeJSON(AISessionEventPayload.self, event.payload),
                          case .userMessage(_, let content) = payload else { return nil }
                    let title = content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80).description
                    return title.isEmpty ? nil : title
                }.first
                : nil
            let update = try database.prepare("""
            UPDATE sessions SET revision=?, context_revision=?, updated_at=?, title=COALESCE(?,title) WHERE session_id=?;
            """)
            try update.bind(newRevision, at: 1)
            try update.bind(newContextRevision, at: 2)
            try update.bind(ISODate.encode(timestamp), at: 3)
            try update.bind(newTitle, at: 4)
            try update.bind(sessionID.uuidString, at: 5)
            try update.stepDone()
            try database.execute("COMMIT;")
            return AIAppendReceipt(
                revision: newRevision,
                contextRevision: newContextRevision,
                eventIDs: events.map(\.eventID),
                firstSequence: firstSequence,
                lastSequence: nextSequence - 1,
                deduplicated: false
            )
        } catch {
            try? database.execute("ROLLBACK;")
            throw persistence(error)
        }
    }

    func load(sessionID: UUID) async throws -> AISessionSnapshot {
        let database = try open()
        return try snapshot(sessionID, in: database)
    }

    func list(filter: AISessionFilter = .all, limit: Int = 50, offset: Int = 0) async throws -> [AISessionSummary] {
        guard (1...200).contains(limit), offset >= 0 else { throw AISessionStoreError.invalidArguments }
        let database = try open()
        var sql = """
        SELECT session_id, target_json, title, permission, profile_id, updated_at
        FROM sessions
        """
        var parameters: [String] = []
        switch filter {
        case .all:
            break
        case .local:
            sql += " WHERE JSON_EXTRACT(target_json, '$.hostID') IS NULL"
        case .host(let hostID):
            sql += " WHERE JSON_EXTRACT(target_json, '$.hostID') = ?"
            parameters = [hostID.uuidString]
        case .terminal(let terminalID):
            sql += " WHERE JSON_EXTRACT(target_json, '$.terminalSessionID') = ?"
            parameters = [terminalID.uuidString]
        }
        sql += " ORDER BY updated_at DESC, session_id ASC LIMIT ? OFFSET ?;"
        let statement = try database.prepare(sql)
        var index: Int32 = 1
        for parameter in parameters {
            try statement.bind(parameter, at: index)
            index += 1
        }
        try statement.bind(Int64(limit), at: index)
        try statement.bind(Int64(offset), at: index + 1)

        var summaries: [AISessionSummary] = []
        while try statement.stepRow() {
            guard let idText = statement.text(0),
                  let id = UUID(uuidString: idText),
                  let targetData = statement.data(1),
                  let target = try? decodeJSON(AITargetSnapshot.self, targetData),
                  let permissionText = statement.text(3),
                  let permission = AIPermissionMode(rawValue: permissionText),
                  let updatedText = statement.text(5),
                  let updated = ISODate.decode(updatedText) else { continue }
            let profileID = statement.text(4).flatMap(UUID.init(uuidString:))
            summaries.append(AISessionSummary(
                id: id,
                title: statement.text(2) ?? "新对话",
                targetHostID: target.hostID,
                targetName: target.displayName,
                updatedAt: updated,
                permission: permission,
                modelProfileID: profileID,
                terminalSessionID: target.terminalSessionID
            ))
        }
        return summaries
    }

    func readEvents(sessionID: UUID, afterSequence: Int64 = 0, limit: Int = 100) async throws -> [AISessionEvent] {
        guard afterSequence >= 0, (1...500).contains(limit) else { throw AISessionStoreError.invalidArguments }
        let database = try open()
        let statement = try database.prepare("""
        SELECT event_id, session_id, sequence, timestamp, event_type, turn_id, request_id, payload_version, payload_json
        FROM events WHERE session_id=? AND sequence>? ORDER BY sequence ASC LIMIT ?;
        """)
        try statement.bind(sessionID.uuidString, at: 1)
        try statement.bind(afterSequence, at: 2)
        try statement.bind(Int64(limit), at: 3)
        return try events(from: statement)
    }

    private func requireWritableIdentity(sessionID: UUID, terminalID: UUID?, in database: AIDatabase) throws {
        let deleted = try database.prepare("SELECT 1 FROM deleted_sessions WHERE session_id=? UNION ALL SELECT 1 FROM deleted_terminals WHERE terminal_id=? LIMIT 1;")
        try deleted.bind(sessionID.uuidString, at: 1)
        try deleted.bind(terminalID?.uuidString, at: 2)
        guard try !deleted.stepRow() else { throw AISessionStoreError.sessionMissing }
    }

    /// User-approved removal of legacy histories with no reliable terminal owner.
    func deleteUnassignedHistory() async throws {
        let database = try open()
        let hasUnassigned: Bool = try {
            let query = try database.prepare("SELECT 1 FROM sessions WHERE JSON_EXTRACT(target_json, '$.terminalSessionID') IS NULL LIMIT 1;")
            return try query.stepRow()
        }()
        guard hasUnassigned else { return }
        let legacyTerminal = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let update = try database.prepare("UPDATE sessions SET target_json=JSON_SET(target_json, '$.terminalSessionID', ?) WHERE JSON_EXTRACT(target_json, '$.terminalSessionID') IS NULL;")
        try update.bind(legacyTerminal.uuidString, at: 1)
        try update.stepDone()
        try await deleteTerminalHistory(terminalID: legacyTerminal)
    }

    /// Durable deletion barrier contains identifiers only, never conversation content.
    /// Any stale archive task trying to recreate these identities is rejected by create().
    func deleteTerminalHistory(terminalID: UUID) async throws {
        let database = try open()
        do {
            try database.execute("BEGIN IMMEDIATE;")
            let barrier = try database.prepare("INSERT INTO deleted_terminals(terminal_id,cleanup_pending) VALUES (?,1) ON CONFLICT(terminal_id) DO UPDATE SET cleanup_pending=1;")
            try barrier.bind(terminalID.uuidString, at: 1)
            try barrier.stepDone()
            let sessions = try database.prepare("SELECT session_id FROM sessions WHERE JSON_EXTRACT(target_json, '$.terminalSessionID')=?;")
            try sessions.bind(terminalID.uuidString, at: 1)
            var ids: [UUID] = []
            while try sessions.stepRow() {
                guard let raw = sessions.text(0), let id = UUID(uuidString: raw) else { throw AISessionStoreError.persistenceFailed("会话标识损坏。") }
                ids.append(id)
            }
            for id in ids {
                let deleted = try database.prepare("INSERT OR IGNORE INTO deleted_sessions(session_id,terminal_id) VALUES (?,?);")
                try deleted.bind(id.uuidString, at: 1)
                try deleted.bind(terminalID.uuidString, at: 2)
                try deleted.stepDone()
                try delete(sessionID: id, in: database)
            }
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw persistence(error)
        }
        do {
            if terminalID != Self.unassignedLegacyTerminalID {
                try ExecutionHistoryStore.markTerminalDeleted(terminalID, tombstonesAt: executionHistoryTombstonesURL)
            }
            try finishPendingTerminalCleanup(in: database)
        } catch {
            throw persistence(error)
        }
    }

    func resumeTerminalCleanup() async throws {
        do {
            let database = try open()
            let pending = try database.prepare("SELECT terminal_id FROM deleted_terminals WHERE cleanup_pending=1;")
            var terminalIDs: [UUID] = []
            while try pending.stepRow() {
                guard let text = pending.text(0), let id = UUID(uuidString: text) else {
                    throw AISessionStoreError.persistenceFailed("删除标识损坏。")
                }
                terminalIDs.append(id)
            }
            for terminalID in terminalIDs {
                if terminalID != Self.unassignedLegacyTerminalID {
                    try ExecutionHistoryStore.markTerminalDeleted(terminalID, tombstonesAt: executionHistoryTombstonesURL)
                }
            }
            try finishPendingTerminalCleanup(in: database)
        } catch {
            throw persistence(error)
        }
    }

    private func finishPendingTerminalCleanup(in database: AIDatabase) throws {
        let hasPending: Bool = try {
            let statement = try database.prepare("SELECT 1 FROM deleted_terminals WHERE cleanup_pending=1 LIMIT 1;")
            return try statement.stepRow()
        }()
        guard hasPending else { return }
        let ids: Set<UUID> = try {
            let statement = try database.prepare("SELECT session_id FROM deleted_sessions;")
            var result = Set<UUID>()
            while try statement.stepRow() {
                guard let text = statement.text(0), let id = UUID(uuidString: text) else { throw AISessionStoreError.persistenceFailed("删除标识损坏。") }
                result.insert(id)
            }
            return result
        }()
        let directory = databaseFile.deletingLastPathComponent()
        let source = directory.appendingPathComponent("conversations.json")
        let backupDirectory = directory.appendingPathComponent("ai-session-migration-backups", isDirectory: true)
        var copies: [URL] = []
        if FileManager.default.fileExists(atPath: source.path) { copies.append(source) }
        if FileManager.default.fileExists(atPath: backupDirectory.path) {
            copies += try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for url in copies {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw AISessionStoreError.persistenceFailed("旧记录路径不是普通文件，删除尚未完成。") }
            let data = try Data(contentsOf: url)
            let records = try decodeLegacyRecords(data)
            let retained = records.filter { !ids.contains($0.id) }
            if retained.count != records.count {
                try encoder.encode(retained).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        if FileManager.default.fileExists(atPath: source.path) {
            let sanitized = try Data(contentsOf: source)
            let digest = AISessionIdentity.digest(sanitized)
            let marker = try database.prepare("UPDATE migrations SET source_digest=? WHERE migration_key LIKE 'legacy-conversations-%';")
            try marker.bind(digest, at: 1)
            try marker.stepDone()
            // Preserve a valid remaining-record backup at the newly verified digest.
            if FileManager.default.fileExists(atPath: backupDirectory.path) {
                let remainingBackup = backupDirectory.appendingPathComponent("\(digest).json")
                try sanitized.write(to: remainingBackup, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: remainingBackup.path)
            }
        }
        // secure_delete overwrites removed database cells; VACUUM removes free pages.
        // This does not promise erasure of OS snapshots, SSD remapping or external backups.
        try database.execute("VACUUM;")
        try database.execute("UPDATE deleted_terminals SET cleanup_pending=0;")
    }

    func delete(sessionID: UUID) async throws {
        let database = try open()
        do {
            try database.execute("BEGIN IMMEDIATE;")
            guard try !hasActiveWork(sessionID: sessionID, in: database) else { throw AISessionStoreError.busy }
            let event = try database.prepare("DELETE FROM events WHERE session_id=?;")
            try event.bind(sessionID.uuidString, at: 1)
            try event.stepDone()
            let request = try database.prepare("DELETE FROM requests WHERE session_id=?;")
            try request.bind(sessionID.uuidString, at: 1)
            try request.stepDone()
            let compaction = try database.prepare("DELETE FROM compactions WHERE session_id=?;")
            try compaction.bind(sessionID.uuidString, at: 1)
            try compaction.stepDone()
            let session = try database.prepare("DELETE FROM sessions WHERE session_id=?;")
            try session.bind(sessionID.uuidString, at: 1)
            try session.stepDone()
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw persistence(error)
        }
    }

    func clearAll() async throws {
        let database = try open()
        do {
            try database.execute("BEGIN IMMEDIATE;")
            let sessions = try database.prepare("SELECT session_id FROM sessions;")
            while try sessions.stepRow() {
                guard let text = sessions.text(0), let id = UUID(uuidString: text) else {
                    throw AISessionStoreError.persistenceFailed("会话标识损坏。")
                }
                guard try !hasActiveWork(sessionID: id, in: database) else { throw AISessionStoreError.busy }
            }
            try database.execute("DELETE FROM events; DELETE FROM requests; DELETE FROM compactions; DELETE FROM sessions;")
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw persistence(error)
        }
    }

    /// Called inside the same transaction as deletion so admission cannot race cleanup.
    private func hasActiveWork(sessionID: UUID, in database: AIDatabase) throws -> Bool {
        let statement = try database.prepare("""
        SELECT event_type, turn_id, payload_json FROM events
        WHERE session_id=? AND event_type IN ('turn_started','turn_ended','compaction_started','compaction_ended')
        ORDER BY sequence;
        """)
        try statement.bind(sessionID.uuidString, at: 1)
        var turns = Set<UUID>()
        var compactions = Set<UUID>()
        while try statement.stepRow() {
            switch statement.text(0) {
            case "turn_started", "turn_ended":
                guard let text = statement.text(1), let id = UUID(uuidString: text) else {
                    throw AISessionStoreError.persistenceFailed("轮次标识损坏，拒绝清理。")
                }
                if statement.text(0) == "turn_started" { turns.insert(id) } else { turns.remove(id) }
            case "compaction_started", "compaction_ended":
                guard let data = statement.data(2) else { throw AISessionStoreError.persistenceFailed("压缩记录损坏。") }
                let id = try decodeJSON(CompactionIDPayload.self, data).compactionID
                if statement.text(0) == "compaction_started" { compactions.insert(id) } else { compactions.remove(id) }
            default: break
            }
        }
        return !turns.isEmpty || !compactions.isEmpty
    }

    func pruneExpired(retentionDays: Int, now: Date = Date(), maximumInactiveSessions: Int = 300) async throws -> [UUID] {
        guard retentionDays >= 0, maximumInactiveSessions >= 0 else { throw AISessionStoreError.invalidArguments }
        let database = try open()
        let cutoff = retentionDays == 0 ? nil : now.addingTimeInterval(-Double(retentionDays) * 86_400)
        do {
            try database.execute("BEGIN IMMEDIATE;")
            let statement = try database.prepare("""
            SELECT session_id, updated_at FROM sessions
            ORDER BY updated_at DESC, session_id ASC;
            """)
            var retainedCount = 0
            var deletable: [UUID] = []
            while try statement.stepRow() {
                guard let text = statement.text(0), let id = UUID(uuidString: text),
                      let dateText = statement.text(1), let updated = ISODate.decode(dateText) else {
                    throw AISessionStoreError.persistenceFailed("会话记录损坏，拒绝清理。")
                }
                if try hasActiveWork(sessionID: id, in: database) { continue }
                let expired = cutoff.map { updated < $0 } ?? false
                if expired || retainedCount >= maximumInactiveSessions {
                    deletable.append(id)
                } else {
                    retainedCount += 1
                }
            }
            for id in deletable { try delete(sessionID: id, in: database) }
            try database.execute("COMMIT;")
            return deletable
        } catch {
            try? database.execute("ROLLBACK;")
            throw persistence(error)
        }
    }

    func migrateLegacyArchive(sourceURL: URL, backupURL: URL? = nil) async throws -> AIMigrationReport {
        let data = try? Data(contentsOf: sourceURL)
        guard let sourceData = data, !sourceData.isEmpty else {
            throw AISessionStoreError.migrationFailed("无法读取旧会话文件。")
        }
        guard sourceData.count <= 64 * 1024 * 1024 else {
            throw AISessionStoreError.migrationFailed("旧会话文件超过 64 MiB。")
        }
        let digest = AISessionIdentity.digest(sourceData)
        let database = try open()
        let marker = try readMigrationMarker(sourceDigest: digest, in: database)
        if let marker {
            return AIMigrationReport(
                importedSessions: 0,
                importedEvents: 0,
                skippedSessions: 0,
                backupPath: marker.backupPath,
                completed: true,
                errorCodes: []
            )
        }

        guard let records = try? decodeLegacyRecords(sourceData) else {
            throw AISessionStoreError.migrationFailed("旧会话文件格式无法识别或必要字段缺失。")
        }
        let backupDirectory = backupURL ?? sourceURL.deletingLastPathComponent()
            .appendingPathComponent("ai-session-migration-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let resolvedBackup = backupDirectory.appendingPathComponent("\(digest).json")
        if !FileManager.default.fileExists(atPath: resolvedBackup.path) {
            try sourceData.write(to: resolvedBackup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resolvedBackup.path)
        }

        var importedSessions = 0
        var importedEvents = 0
        do {
            try database.execute("BEGIN IMMEDIATE;")
            for record in records {
                if try sessionExists(record.id, in: database) {
                    throw AISessionStoreError.migrationFailed("旧会话 ID 与现有会话冲突。")
                }
                let statement = try database.prepare("""
                INSERT INTO sessions
                (session_id, target_json, title, permission, permission_version,
                 configuration_by_profile_json, revision, context_revision, updated_at)
                VALUES (?,?,?,?,1,?,?,0,?);
                """)
                let target = AITargetSnapshot(
                    hostID: record.targetHostID,
                    terminalSessionID: record.terminalSessionID,
                    workingDirectory: nil,
                    displayName: record.targetName
                )
                try statement.bind(record.id.uuidString, at: 1)
                try statement.bind(try encodeJSON(target), at: 2)
                try statement.bind(record.title, at: 3)
                try statement.bind(AIPermissionMode.readOnly.rawValue, at: 4)
                try statement.bind(try encodeJSON(["current": AIContextConfiguration.standard]), at: 5)
                try statement.bind(Int64(2 + record.messages.count), at: 6)
                try statement.bind(ISODate.encode(record.updatedAt), at: 7)
                try statement.stepDone()
                importedSessions += 1

                var sequence: Int64 = 1
                let now = Date()
                try insert(AINewSessionEvent(
                    sessionID: record.id,
                    type: .sessionCreated,
                    payload: AISessionEventPayload.sessionCreated(
                        target: target,
                        permission: .readOnly,
                        profileID: nil
                    ).data
                ), nextSequence: sequence, timestamp: now, in: database)
                sequence += 1
                importedEvents += 1

                for (index, message) in record.messages.enumerated() {
                    var stored = AIStoredMessage(message: message)
                    let messageID = AISessionIdentity.stableMessageID(
                        sessionID: record.id,
                        index: index,
                        // ChatMessage's wire representation excludes the random
                        // in-memory ID assigned when a legacy message is decoded.
                        content: try encodeJSON(message)
                    )
                    stored.id = messageID
                    let payload: AISessionEventPayload
                    switch message.role {
                    case "user":
                        payload = .userMessage(messageID: messageID, content: message.content ?? "")
                    case "assistant":
                        payload = .assistantMessage(messageID: messageID, stored: stored)
                    default:
                        payload = .legacyMessage(messageID: messageID, stored: stored)
                    }
                    try insert(AINewSessionEvent(
                        sessionID: record.id,
                        type: message.role == "user" ? .userMessage : (message.role == "assistant" ? .assistantMessage : .migrationImported),
                        payload: payload.data
                    ), nextSequence: sequence, timestamp: now, in: database)
                    sequence += 1
                    importedEvents += 1
                }
                try insert(AINewSessionEvent(
                    sessionID: record.id,
                    type: .migrationImported,
                    payload: AISessionEventPayload.migrationImported(
                        sourceRecordID: record.id,
                        sourceDigest: digest,
                        legacyBoundary: true
                    ).data
                ), nextSequence: sequence, timestamp: now, in: database)
                importedEvents += 1
            }

            let markerStatement = try database.prepare("""
            INSERT INTO migrations
            (migration_key, source_digest, completed_at, imported_session_count, imported_event_count)
            VALUES (?,?,?,?,?);
            """)
            try markerStatement.bind("legacy-conversations-\(digest)", at: 1)
            try markerStatement.bind(digest, at: 2)
            try markerStatement.bind(ISODate.encode(Date()), at: 3)
            try markerStatement.bind(Int64(importedSessions), at: 4)
            try markerStatement.bind(Int64(importedEvents), at: 5)
            try markerStatement.stepDone()
            try database.execute("COMMIT;")
            return AIMigrationReport(
                importedSessions: importedSessions,
                importedEvents: importedEvents,
                skippedSessions: 0,
                backupPath: resolvedBackup.path,
                completed: true,
                errorCodes: []
            )
        } catch {
            try? database.execute("ROLLBACK;")
            if error is AISessionStoreError {
                throw error
            }
            throw AISessionStoreError.migrationFailed(String(describing: error))
        }
    }

    func recoverInterruptedSessions() async throws -> AIRecoveryReport {
        let database = try open()
        let sessionStatement = try database.prepare("SELECT session_id FROM sessions ORDER BY session_id;")
        var ids: [UUID] = []
        while try sessionStatement.stepRow() {
            if let text = sessionStatement.text(0), let id = UUID(uuidString: text) { ids.append(id) }
        }
        var interrupted: [UUID] = []
        var recoveredSessionIDs: [UUID] = []
        var unknownCalls: [String] = []
        var discarded: [UUID] = []
        for id in ids {
            let events = try events(sessionID: id, in: database)
            var openTurns = Set<UUID>()
            var openCompactions: [UUID: Bool] = [:]
            var intents = Set<String>()
            var results = Set<String>()
            for event in events {
                switch event.type {
                case .turnStarted:
                    if let turnID = event.turnID { openTurns.insert(turnID) }
                case .turnEnded:
                    if let turnID = event.turnID { openTurns.remove(turnID) }
                case .toolIntent:
                    if let payload = try? decodeJSON(ToolIntentPayload.self, event.payload) {
                        intents.insert(toolCallKey(requestID: event.requestID, callID: payload.callID))
                    }
                case .toolResult:
                    if let payload = try? decodeJSON(ToolResultPayload.self, event.payload) {
                        results.insert(toolCallKey(requestID: event.requestID, callID: payload.callID))
                    }
                case .compactionStarted:
                    let payload = try decodeJSON(CompactionIDPayload.self, event.payload)
                    openCompactions[payload.compactionID] = false
                case .contextProjected:
                    let payload = try decodeJSON(AIContextProjectionPayload.self, event.payload)
                    if openCompactions[payload.compactionID] != nil {
                        openCompactions[payload.compactionID] = true
                    }
                case .compactionEnded:
                    let payload = try decodeJSON(CompactionIDPayload.self, event.payload)
                    openCompactions.removeValue(forKey: payload.compactionID)
                default:
                    break
                }
            }
            let unmatched = intents.subtracting(results)
            unknownCalls.append(contentsOf: unmatched.map { "\(id.uuidString)/\($0)" })
            guard !openTurns.isEmpty || !openCompactions.isEmpty else { continue }
            do {
                try database.execute("BEGIN IMMEDIATE;")
                let core = try readSessionCore(id, in: database)
                var revision = core?.revision ?? 0
                let timestamp = Date()
                for turnID in openTurns.sorted(by: { $0.uuidString < $1.uuidString }) {
                    let payload = AISessionEventPayload.turnEnded(turnID: turnID, status: "interrupted", errorCode: nil).data
                    try insert(AINewSessionEvent(sessionID: id, type: .turnEnded, turnID: turnID, payload: payload), nextSequence: try maxSequence(id, in: database) + 1, timestamp: timestamp, in: database)
                    revision += 1
                    interrupted.append(turnID)
                }
                for compactionID in openCompactions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                    let committed = openCompactions[compactionID] == true
                    let payload = try encodeJSON(CompactionEndedValidationPayload(
                        compactionID: compactionID, status: committed ? "completed" : "interrupted"
                    ))
                    try insert(AINewSessionEvent(sessionID: id, type: .compactionEnded, payload: payload),
                        nextSequence: try maxSequence(id, in: database) + 1, timestamp: timestamp, in: database)
                    revision += 1
                    if !committed { discarded.append(compactionID) }
                }
                let update = try database.prepare("UPDATE sessions SET revision=?, updated_at=? WHERE session_id=?;")
                try update.bind(revision, at: 1)
                try update.bind(ISODate.encode(timestamp), at: 2)
                try update.bind(id.uuidString, at: 3)
                try update.stepDone()
                try database.execute("COMMIT;")
                recoveredSessionIDs.append(id)
            } catch {
                try? database.execute("ROLLBACK;")
                throw persistence(error)
            }
        }
        return AIRecoveryReport(
            sessionIDs: recoveredSessionIDs,
            interruptedTurnIDs: interrupted,
            unknownCallKeys: unknownCalls,
            discardedCompactionIDs: discarded
        )
    }

    func fork(sessionID: UUID, throughSequence: Int64) async throws -> AISessionSnapshot {
        let database = try open()
        let source = try snapshot(sessionID, in: database)
        let sourceEvents = try events(sessionID: sessionID, in: database)
        let prefix = sourceEvents.filter { $0.sequence <= throughSequence }
        guard prefix.last?.sequence == throughSequence else { throw AISessionStoreError.invalidArguments }
        let sourceMetadata = try database.prepare("SELECT profile_id,configuration_by_profile_json FROM sessions WHERE session_id=?;")
        try sourceMetadata.bind(sessionID.uuidString, at: 1)
        guard try sourceMetadata.stepRow(), let configurationData = sourceMetadata.data(1) else {
            throw AISessionStoreError.sessionMissing
        }
        var forkProfileID = sourceMetadata.text(0).flatMap(UUID.init(uuidString:))
        var forkConfigurations = try decodeJSON([String: AIContextConfiguration].self, configurationData)
        var openTurns = Set<UUID>()
        var intents = Set<String>()
        var results = Set<String>()
        var openCompactions = Set<UUID>()
        var forkTitle: String?
        for event in prefix {
            if let payload = try? decodeJSON(AISessionEventPayload.self, event.payload) {
                switch payload {
                case .sessionCreated(_, _, let profileID): forkProfileID = profileID
                case .modelSelected(let profileID, _): forkProfileID = profileID
                case .userMessage(_, let content):
                    if forkTitle == nil { forkTitle = String(content.prefix(80)) }
                case .contextConfigured(let configuration):
                    forkConfigurations[forkProfileID?.uuidString ?? "current"] = configuration
                case .profileContextConfigured(let profileID, let configuration):
                    forkConfigurations[profileID.uuidString] = configuration
                default: break
                }
            }
            switch event.type {
            case .turnStarted:
                if let id = event.turnID { openTurns.insert(id) }
            case .turnEnded:
                if let id = event.turnID { openTurns.remove(id) }
            case .toolIntent:
                if let payload = try? decodeJSON(ToolIntentPayload.self, event.payload) {
                    intents.insert(toolCallKey(requestID: event.requestID, callID: payload.callID))
                }
            case .toolResult:
                if let payload = try? decodeJSON(AIToolResultEventPayload.self, event.payload) {
                    results.insert(toolCallKey(requestID: event.requestID, callID: payload.callID))
                }
            case .compactionStarted:
                if let payload = try? decodeJSON(CompactionIDPayload.self, event.payload) { openCompactions.insert(payload.compactionID) }
            case .compactionEnded:
                if let payload = try? decodeJSON(CompactionIDPayload.self, event.payload) { openCompactions.remove(payload.compactionID) }
            default:
                break
            }
        }
        guard openTurns.isEmpty, openCompactions.isEmpty, intents.isSubset(of: results) else {
            throw AISessionStoreError.invalidArguments
        }
        let newID = UUID()
        let now = Date()
        do {
            try database.execute("BEGIN IMMEDIATE;")
            let statement = try database.prepare("""
            INSERT INTO sessions
            (session_id, target_json, title, permission, permission_version,
             profile_id, configuration_by_profile_json, revision, context_revision, updated_at,
             parent_session_id, fork_sequence)
            VALUES (?,?,?,?,1,?,?,0,0,?,?,?);
            """)
            try statement.bind(newID.uuidString, at: 1)
            try statement.bind(try encodeJSON(source.target), at: 2)
            try statement.bind(forkTitle ?? "分叉对话", at: 3)
            try statement.bind(AIPermissionMode.readOnly.rawValue, at: 4)
            try statement.bind(forkProfileID?.uuidString, at: 5)
            if forkConfigurations[forkProfileID?.uuidString ?? "current"] == nil {
                forkConfigurations[forkProfileID?.uuidString ?? "current"] = .standard
            }
            try statement.bind(try encodeJSON(forkConfigurations), at: 6)
            try statement.bind(ISODate.encode(now), at: 7)
            try statement.bind(sessionID.uuidString, at: 8)
            try statement.bind(throughSequence, at: 9)
            try statement.stepDone()
            try insert(AINewSessionEvent(
                sessionID: newID,
                type: .sessionCreated,
                payload: AISessionEventPayload.sessionCreated(target: source.target, permission: .readOnly, profileID: forkProfileID).data
            ), nextSequence: 1, timestamp: now, in: database)
            var nextSequence: Int64 = 2
            var contextRevision: Int64 = 0
            for event in prefix {
                if event.type == .permissionChanged { continue }
                try insert(AINewSessionEvent(
                    eventID: UUID(),
                    sessionID: newID,
                    type: event.type,
                    turnID: event.turnID,
                    requestID: event.requestID,
                    payload: event.payload,
                    payloadVersion: event.payloadVersion
                ), nextSequence: nextSequence, timestamp: now, in: database)
                if event.type.advancesModelContext { contextRevision += 1 }
                nextSequence += 1
            }
            let update = try database.prepare("UPDATE sessions SET revision=?, context_revision=? WHERE session_id=?;")
            try update.bind(Int64(nextSequence - 1), at: 1)
            try update.bind(contextRevision, at: 2)
            try update.bind(newID.uuidString, at: 3)
            try update.stepDone()
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw persistence(error)
        }
        return try snapshot(newID, in: database)
    }

    private func insert(_ event: AINewSessionEvent, nextSequence: Int64, timestamp: Date, in database: AIDatabase) throws {
        try validateEventPayload(type: event.type, version: event.payloadVersion, payload: event.payload,
                                 turnID: event.turnID, requestID: event.requestID)
        let statement = try database.prepare("""
        INSERT INTO events
        (event_id, session_id, sequence, event_type, turn_id, request_id, timestamp, payload_version, payload_json)
        VALUES (?,?,?,?,?,?,?,?,?);
        """)
        try statement.bind(event.eventID.uuidString, at: 1)
        try statement.bind(event.sessionID.uuidString, at: 2)
        try statement.bind(nextSequence, at: 3)
        try statement.bind(event.type.rawValue, at: 4)
        try statement.bind(event.turnID?.uuidString, at: 5)
        try statement.bind(event.requestID?.uuidString, at: 6)
        try statement.bind(ISODate.encode(timestamp), at: 7)
        try statement.bind(Int64(event.payloadVersion), at: 8)
        try statement.bind(event.payload, at: 9)
        try statement.stepDone()
    }

    private func readEvent(_ id: UUID, in database: AIDatabase) throws -> AISessionEvent? {
        let statement = try database.prepare("""
        SELECT event_id, session_id, sequence, timestamp, event_type, turn_id, request_id, payload_version, payload_json
        FROM events WHERE event_id=?;
        """)
        try statement.bind(id.uuidString, at: 1)
        guard try statement.stepRow() else { return nil }
        return try event(from: statement)
    }

    private func events(from statement: AIStatement) throws -> [AISessionEvent] {
        var result: [AISessionEvent] = []
        while try statement.stepRow() {
            result.append(try event(from: statement))
        }
        return result
    }

    private func event(from statement: AIStatement) throws -> AISessionEvent {
        guard let eventIDText = statement.text(0), let eventID = UUID(uuidString: eventIDText),
              let sessionIDText = statement.text(1), let sessionID = UUID(uuidString: sessionIDText),
              let sequence = statement.int64(2), sequence > 0,
              let timestampText = statement.text(3), let timestamp = ISODate.decode(timestampText),
              let typeText = statement.text(4),
              let payloadVersion = statement.int(7),
              let payload = statement.data(8) else {
            throw AISessionStoreError.persistenceFailed("事件记录损坏。")
        }
        guard let type = AISessionEventType(rawValue: typeText), payloadVersion == 1 else {
            throw AISessionStoreError.unsupportedSchema
        }
        let turnID = try optionalEventID(statement.text(5))
        let requestID = try optionalEventID(statement.text(6))
        try validateEventPayload(type: type, version: payloadVersion, payload: payload,
                                 turnID: turnID, requestID: requestID)
        return AISessionEvent(
            eventID: eventID,
            sessionID: sessionID,
            sequence: sequence,
            timestamp: timestamp,
            type: type,
            turnID: turnID,
            requestID: requestID,
            payload: payload,
            payloadVersion: payloadVersion
        )
    }

    private func optionalEventID(_ value: String?) throws -> UUID? {
        guard let value else { return nil }
        guard let id = UUID(uuidString: value) else {
            throw AISessionStoreError.persistenceFailed("事件标识损坏。")
        }
        return id
    }

    private func validateEventPayload(
        type: AISessionEventType, version: Int, payload: Data, turnID: UUID?, requestID: UUID?
    ) throws {
        guard version == 1 else { throw AISessionStoreError.unsupportedSchema }
        do {
            switch type {
            case .toolIntent:
                let value = try decodeJSON(AIToolIntentEventPayload.self, payload)
                guard !value.callID.isEmpty, value.permissionVersion > 0 else { throw AISessionStoreError.invalidArguments }
            case .toolResult:
                let value = try decodeJSON(AIToolResultEventPayload.self, payload)
                guard !value.callID.isEmpty, value.capturedBytes >= 0, value.omittedBytes >= 0 else {
                    throw AISessionStoreError.invalidArguments
                }
            case .compactionStarted:
                _ = try decodeJSON(CompactionStartedValidationPayload.self, payload)
            case .compactionEnded:
                _ = try decodeJSON(CompactionEndedValidationPayload.self, payload)
            case .contextProjected, .compactionCommitted:
                let value = try decodeJSON(AIContextProjectionPayload.self, payload)
                guard value.sourceMessageIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else {
                    throw AISessionStoreError.invalidArguments
                }
            default:
                let value = try decodeJSON(AISessionEventPayload.self, payload)
                switch (type, value) {
                case (.sessionCreated, .sessionCreated), (.userMessage, .userMessage),
                     (.migrationImported, .migrationImported), (.permissionChanged, .permissionChanged),
                     (.modelSelected, .modelSelected), (.contextConfigured, .contextConfigured),
                     (.profileContextConfigured, .profileContextConfigured):
                    break
                case (.assistantMessage, .assistantMessage(_, let stored)),
                     (.migrationImported, .legacyMessage(_, let stored)):
                    // Older migrations kept the original ID inside `stored`.
                    // The event's message ID is authoritative during projection.
                    if let calls = stored.toolCallsJSON { _ = try decodeJSON([ChatToolCall].self, calls) }
                case (.turnStarted, .turnStarted(let id, _, _)), (.turnEnded, .turnEnded(let id, _, _)):
                    guard turnID == id else { throw AISessionStoreError.invalidArguments }
                case (.requestStarted, .requestStarted(let owner, _)),
                     (.requestSettled, .requestSettled(let owner, _, _, _)),
                     (.usageCorrected, .requestSettled(let owner, _, _, _)):
                    guard requestID != nil, turnID == owner.turnID else {
                        throw AISessionStoreError.invalidArguments
                    }
                default:
                    throw AISessionStoreError.invalidArguments
                }
            }
        } catch {
            throw AISessionStoreError.persistenceFailed("事件 \(type.rawValue) 的载荷与类型或标识不符。")
        }
    }

    private func events(sessionID: UUID, in database: AIDatabase) throws -> [AISessionEvent] {
        let statement = try database.prepare("""
        SELECT event_id, session_id, sequence, timestamp, event_type, turn_id, request_id, payload_version, payload_json
        FROM events WHERE session_id=? ORDER BY sequence;
        """)
        try statement.bind(sessionID.uuidString, at: 1)
        return try events(from: statement)
    }

    private func maxSequence(_ sessionID: UUID, in database: AIDatabase) throws -> Int64 {
        let statement = try database.prepare("SELECT COALESCE(MAX(sequence),0) FROM events WHERE session_id=?;")
        try statement.bind(sessionID.uuidString, at: 1)
        guard try statement.stepRow() else { return 0 }
        return statement.int64(0) ?? 0
    }

    private func readSessionCore(_ sessionID: UUID, in database: AIDatabase) throws -> (revision: Int64, contextRevision: Int64)? {
        let statement = try database.prepare("SELECT revision, context_revision FROM sessions WHERE session_id=?;")
        try statement.bind(sessionID.uuidString, at: 1)
        guard try statement.stepRow() else { return nil }
        return (statement.int64(0) ?? 0, statement.int64(1) ?? 0)
    }

    private func readSessionTitle(_ sessionID: UUID, in database: AIDatabase) throws -> String? {
        let statement = try database.prepare("SELECT title FROM sessions WHERE session_id=?;")
        try statement.bind(sessionID.uuidString, at: 1)
        guard try statement.stepRow() else { return nil }
        return statement.text(0)
    }

    private func snapshot(_ sessionID: UUID, in database: AIDatabase) throws -> AISessionSnapshot {
        let statement = try database.prepare("""
        SELECT target_json, permission, permission_version, profile_id, configuration_by_profile_json,
               revision, context_revision, updated_at, parent_session_id, fork_sequence
        FROM sessions WHERE session_id=?;
        """)
        try statement.bind(sessionID.uuidString, at: 1)
        guard try statement.stepRow() else { throw AISessionStoreError.sessionMissing }
        guard let targetData = statement.data(0),
              let target = try? decodeJSON(AITargetSnapshot.self, targetData),
              let permissionText = statement.text(1), let permission = AIPermissionMode(rawValue: permissionText),
              let configData = statement.data(4),
              var configs = try? decodeJSON([String: AIContextConfiguration].self, configData) else {
            throw AISessionStoreError.persistenceFailed("会话元数据损坏。")
        }
        let profileID = try optionalEventID(statement.text(3))
        let configuration = configs[profileID?.uuidString ?? "current"] ?? .standard
        let events = try events(sessionID: sessionID, in: database)
        var messages: [ChatMessage] = []
        var messageIndexes: [UUID: Int] = [:]
        var turnStates: [UUID: String] = [:]
        var summaryIDs: [UUID] = []
        var contextSummary: String?
        var summarizedMessageIDs = Set<UUID>()
        var projectedPermission = permission
        var projectedPermissionVersion = statement.int64(2) ?? 1
        var projectedProfileID = profileID
        var projectedConfiguration = configuration
        for event in events {
            switch event.type {
            case .sessionCreated:
                if let payload = try? decodeJSON(AISessionEventPayload.self, event.payload),
                   case .sessionCreated(_, _, let createdProfileID) = payload {
                    projectedProfileID = createdProfileID
                    projectedConfiguration = configs[createdProfileID?.uuidString ?? "current"] ?? .standard
                }
            case .userMessage:
                if let payload = try? decodeJSON(AISessionEventPayload.self, event.payload),
                   case .userMessage(let id, let content) = payload {
                    var message = ChatMessage(id: id, role: "user", content: content)
                    message.turnID = event.turnID
                    upsertMessage(message, in: &messages, indexes: &messageIndexes)
                }
            case .assistantMessage, .migrationImported:
                if let payload = try? decodeJSON(AISessionEventPayload.self, event.payload) {
                    switch payload {
                    case .assistantMessage(let id, let stored), .legacyMessage(let id, let stored):
                        var message = stored.message
                        message.id = id
                        message.turnID = event.turnID
                        message.requestID = event.requestID
                        upsertMessage(message, in: &messages, indexes: &messageIndexes)
                    default: break
                    }
                }
            case .toolResult:
                if let payload = try? decodeJSON(AIToolResultEventPayload.self, event.payload) {
                    var message = ChatMessage(
                        id: payload.messageID,
                        role: "tool",
                        content: payload.content,
                        name: payload.name,
                        toolCallID: payload.callID
                    )
                    message.commandResult = payload.commandResult
                    message.turnID = event.turnID
                    message.requestID = event.requestID
                    upsertMessage(message, in: &messages, indexes: &messageIndexes)
                }
            case .turnStarted:
                if let turnID = event.turnID { turnStates[turnID] = "open" }
            case .turnEnded:
                if let turnID = event.turnID, let payload = try? decodeJSON(AISessionEventPayload.self, event.payload),
                   case .turnEnded(_, let status, _) = payload {
                    turnStates[turnID] = status
                }
            case .compactionCommitted:
                if let payload = try? decodeJSON(CompactionIDPayload.self, event.payload) {
                    summaryIDs.append(payload.compactionID)
                }
            case .contextProjected:
                if let payload = try? decodeJSON(AIContextProjectionPayload.self, event.payload) {
                    contextSummary = payload.summary
                    summarizedMessageIDs = payload.summarizedMessageIDs
                }
            case .permissionChanged:
                if let payload = try? decodeJSON(AISessionEventPayload.self, event.payload),
                   case .permissionChanged(_, let mode) = payload {
                    projectedPermission = mode
                    projectedPermissionVersion += 1
                }
            case .modelSelected:
                if let payload = try? decodeJSON(AISessionEventPayload.self, event.payload),
                   case .modelSelected(let newProfileID, _) = payload {
                    projectedProfileID = newProfileID
                    projectedConfiguration = configs[newProfileID.uuidString] ?? .standard
                }
            case .contextConfigured:
                if let payload = try? decodeJSON(AISessionEventPayload.self, event.payload),
                   case .contextConfigured(let mode) = payload {
                    projectedConfiguration = mode
                    configs[projectedProfileID?.uuidString ?? "current"] = mode
                }
            case .profileContextConfigured:
                if let payload = try? decodeJSON(AISessionEventPayload.self, event.payload),
                   case .profileContextConfigured(let profileID, let mode) = payload {
                    configs[profileID.uuidString] = mode
                    if projectedProfileID == profileID { projectedConfiguration = mode }
                }
            default: break
            }
        }
        return AISessionSnapshot(
            id: sessionID,
            target: target,
            permission: projectedPermission,
            permissionVersion: projectedPermissionVersion,
            modelProfileID: projectedProfileID,
            configuration: projectedConfiguration,
            revision: statement.int64(5) ?? 0,
            contextRevision: statement.int64(6) ?? 0,
            messages: messages,
            turnStates: turnStates,
            summaryIDs: summaryIDs,
            contextSummary: contextSummary,
            summarizedMessageIDs: summarizedMessageIDs,
            parentSessionID: statement.text(8).flatMap(UUID.init(uuidString:)),
            forkSequence: statement.int64(9)
        )
    }

    private func upsertMessage(_ message: ChatMessage, in messages: inout [ChatMessage], indexes: inout [UUID: Int]) {
        if let index = indexes[message.id] {
            messages[index] = message
        } else {
            indexes[message.id] = messages.count
            messages.append(message)
        }
    }

    private func toolCallKey(requestID: UUID?, callID: String) -> String {
        "\(requestID?.uuidString ?? "legacy")/\(callID)"
    }

    private func sessionExists(_ sessionID: UUID, in database: AIDatabase) throws -> Bool {
        let statement = try database.prepare("SELECT 1 FROM sessions WHERE session_id=?;")
        try statement.bind(sessionID.uuidString, at: 1)
        return try statement.stepRow()
    }

    private func delete(sessionID: UUID, in database: AIDatabase) throws {
        for sql in ["DELETE FROM events WHERE session_id=?;", "DELETE FROM requests WHERE session_id=?;", "DELETE FROM compactions WHERE session_id=?;", "DELETE FROM sessions WHERE session_id=?;"] {
            let statement = try database.prepare(sql)
            try statement.bind(sessionID.uuidString, at: 1)
            try statement.stepDone()
        }
    }

    private struct LegacyMigrationMarker {
        var backupPath: String
    }

    private func readMigrationMarker(sourceDigest: String, in database: AIDatabase) throws -> LegacyMigrationMarker? {
        let statement = try database.prepare("SELECT source_digest FROM migrations WHERE migration_key LIKE 'legacy-conversations-%' ORDER BY completed_at DESC LIMIT 1;")
        if try statement.stepRow() {
            guard statement.text(0) == sourceDigest else { throw AISessionStoreError.legacySourceChanged }
            let backup = databaseFile.deletingLastPathComponent()
                .appendingPathComponent("ai-session-migration-backups", isDirectory: true)
                .appendingPathComponent("\(sourceDigest).json")
            return LegacyMigrationMarker(backupPath: backup.path)
        }
        return nil
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        try jsonEncoder.encode(value)
    }

    private func decodeLegacyRecords(_ data: Data) throws -> [ConversationRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            // Old archives used Foundation's default seconds-since-2001
            // encoding. Migration backups use ISO 8601; accept both per record.
            if let seconds = try? value.decode(Double.self), seconds.isFinite {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let text = try value.decode(String.self)
            if let date = ISODate.decode(text) { return date }
            if let date = ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unsupported legacy date")
        }
        return try decoder.decode([ConversationRecord].self, from: data)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try jsonDecoder.decode(type, from: data)
    }

    private func persistence(_ error: Error) -> Error {
        if let sessionError = error as? AISessionStoreError { return sessionError }
        if let databaseError = error as? AIDatabaseError {
            return AISessionStoreError.persistenceFailed(databaseError.message)
        }
        return AISessionStoreError.persistenceFailed(String(describing: error))
    }
}

private enum ISODate {
    static var formatter: ISO8601DateFormatter {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }

    static func encode(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func decode(_ value: String) -> Date? {
        formatter.date(from: value)
    }
}

private struct ToolIntentPayload: Codable {
    var callID: String
}

private struct ToolResultPayload: Codable {
    var callID: String
}

private struct CompactionIDPayload: Codable {
    var compactionID: UUID
}

private struct CompactionStartedValidationPayload: Decodable {
    var compactionID: UUID
    var sourceContextRevision: Int64
}

private struct CompactionEndedValidationPayload: Codable {
    var compactionID: UUID
    var status: String
}

extension AISessionStore {
    private struct StoredRequest {
        var purpose: String
        var requestedModel: String
        var envelope: AIUsageEnvelope?
    }

    private func readRequests(sessionID: UUID, turnID: UUID?, in database: AIDatabase) throws -> [StoredRequest] {
        let statement = try database.prepare("""
        SELECT purpose, usage_json, requested_model FROM requests
        WHERE session_id=? AND (? IS NULL OR turn_id=?)
        ORDER BY request_id;
        """)
        try statement.bind(sessionID.uuidString, at: 1)
        try statement.bind(turnID?.uuidString, at: 2)
        try statement.bind(turnID?.uuidString, at: 3)
        var result: [StoredRequest] = []
        while try statement.stepRow() {
            guard let purpose = statement.text(0), let requestedModel = statement.text(2) else { continue }
            let usage = statement.data(1).flatMap { try? decodeJSON(AIUsageEnvelope.self, $0) }
            result.append(StoredRequest(purpose: purpose, requestedModel: requestedModel, envelope: usage))
        }
        return result
    }

    private func aggregateRequests(_ requests: [StoredRequest]) -> AIUsageAggregate {
        var aggregator = AIUsageAggregator()
        for request in requests {
            if let envelope = request.envelope {
                aggregator.add(envelope)
            }
        }
        return AIUsageAggregate(
            usage: aggregator.usage,
            envelopes: aggregator.envelopes,
            cacheHitRate: aggregator.cacheHitRate,
            requestCount: requests.count,
            modelRequestCounts: Dictionary(grouping: requests, by: \.requestedModel).mapValues(\.count)
        )
    }

    func usageForTurn(sessionID: UUID, turnID: UUID) async throws -> AIUsageAggregate {
        let database = try open()
        return aggregateRequests(try readRequests(sessionID: sessionID, turnID: turnID, in: database))
    }

    func usageForSession(sessionID: UUID) async throws -> AIUsageAggregate {
        let database = try open()
        return aggregateRequests(try readRequests(sessionID: sessionID, turnID: nil, in: database))
    }

    func commitContextProjection(
        sessionID: UUID,
        events: [AINewSessionEvent],
        expectedContextRevision: Int64
    ) async throws -> (revision: Int64, contextRevision: Int64) {
        guard !events.isEmpty else { throw AISessionStoreError.invalidArguments }
        let database = try open()
        do {
            try database.execute("BEGIN IMMEDIATE;")
            guard let current = try readSessionCore(sessionID, in: database) else {
                throw AISessionStoreError.sessionMissing
            }
            try requireWritableIdentity(sessionID: sessionID, terminalID: nil, in: database)
            guard current.contextRevision == expectedContextRevision else {
                throw AISessionStoreError.staleRevision
            }
            var nextSequence = try maxSequence(sessionID, in: database) + 1
            var contextDelta: Int64 = 0
            let timestamp = Date()
            for event in events {
                try insert(event, nextSequence: nextSequence, timestamp: timestamp, in: database)
                if event.type.advancesModelContext { contextDelta += 1 }
                nextSequence += 1
            }
            let revision = current.revision + Int64(events.count)
            let contextRevision = current.contextRevision + contextDelta
            let update = try database.prepare("UPDATE sessions SET revision=?, context_revision=?, updated_at=? WHERE session_id=?;")
            try update.bind(revision, at: 1)
            try update.bind(contextRevision, at: 2)
            try update.bind(ISODate.encode(timestamp), at: 3)
            try update.bind(sessionID.uuidString, at: 4)
            try update.stepDone()
            try database.execute("COMMIT;")
            return (revision, contextRevision)
        } catch {
            try? database.execute("ROLLBACK;")
            throw persistence(error)
        }
    }

    func startRequest(owner: AIRequestOwner, requestID: UUID, model: AIModelSnapshot, requestBody: Data) async throws {
        guard owner.attemptIndex >= 0,
              (owner.turnID == nil) != (owner.maintenanceID == nil) else {
            throw AISessionStoreError.invalidArguments
        }
        let database = try open()
        do {
            try database.execute("BEGIN IMMEDIATE;")
            guard let current = try readSessionCore(owner.sessionID, in: database) else {
                throw AISessionStoreError.sessionMissing
            }
            try requireWritableIdentity(sessionID: owner.sessionID, terminalID: nil, in: database)
            let existing = try database.prepare("SELECT session_id,turn_id,maintenance_id,step_index,attempt_index,purpose FROM requests WHERE request_id=?;")
            try existing.bind(requestID.uuidString, at: 1)
            if try existing.stepRow() {
                guard existing.text(0) == owner.sessionID.uuidString,
                      existing.text(1) == owner.turnID?.uuidString,
                      existing.text(2) == owner.maintenanceID?.uuidString,
                      existing.int64(3) == owner.stepIndex.map(Int64.init),
                      existing.int64(4) == Int64(owner.attemptIndex),
                      existing.text(5) == owner.purpose else {
                    throw AISessionStoreError.invalidArguments
                }
                try database.execute("COMMIT;")
                return
            }
            let insertRequest = try database.prepare("""
            INSERT INTO requests
            (request_id,session_id,turn_id,maintenance_id,step_index,attempt_index,purpose,
             provider,profile_id,requested_model,actual_model,status,usage_json,request_body)
            VALUES (?,?,?,?,?,?,?,?,?,?,NULL,'started',NULL,?);
            """)
            try insertRequest.bind(requestID.uuidString, at: 1)
            try insertRequest.bind(owner.sessionID.uuidString, at: 2)
            try insertRequest.bind(owner.turnID?.uuidString, at: 3)
            try insertRequest.bind(owner.maintenanceID?.uuidString, at: 4)
            try insertRequest.bind(owner.stepIndex.map(Int64.init), at: 5)
            try insertRequest.bind(Int64(owner.attemptIndex), at: 6)
            try insertRequest.bind(owner.purpose, at: 7)
            try insertRequest.bind(model.provider, at: 8)
            try insertRequest.bind(model.profileID.uuidString, at: 9)
            try insertRequest.bind(model.requestedModel, at: 10)
            try insertRequest.bind(requestBody, at: 11)
            try insertRequest.stepDone()
            let event = AINewSessionEvent(
                sessionID: owner.sessionID,
                type: .requestStarted,
                turnID: owner.turnID,
                requestID: requestID,
                payload: AISessionEventPayload.requestStarted(owner: owner, model: model).data
            )
            try insert(event, nextSequence: try maxSequence(owner.sessionID, in: database) + 1, timestamp: Date(), in: database)
            let update = try database.prepare("UPDATE sessions SET revision=?,updated_at=? WHERE session_id=?;")
            try update.bind(current.revision + 1, at: 1)
            try update.bind(ISODate.encode(Date()), at: 2)
            try update.bind(owner.sessionID.uuidString, at: 3)
            try update.stepDone()
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw persistence(error)
        }
    }

    func finishRequest(owner: AIRequestOwner, requestID: UUID, status: String) async throws {
        guard ["completed", "failed", "cancelled", "deadline_exceeded", "invalid_response"].contains(status) else {
            throw AISessionStoreError.invalidArguments
        }
        let database = try open()
        do {
            try database.execute("BEGIN IMMEDIATE;")
            guard let current = try readSessionCore(owner.sessionID, in: database) else {
                throw AISessionStoreError.sessionMissing
            }
            try requireWritableIdentity(sessionID: owner.sessionID, terminalID: nil, in: database)
            let query = try database.prepare("SELECT status,usage_json FROM requests WHERE request_id=? AND session_id=?;")
            try query.bind(requestID.uuidString, at: 1)
            try query.bind(owner.sessionID.uuidString, at: 2)
            guard try query.stepRow() else { throw AISessionStoreError.invalidArguments }
            let previousStatus = query.text(0) ?? "started"
            if previousStatus == "settled", status == "completed" {
                try database.execute("COMMIT;")
                return
            }
            let usage = query.data(1).flatMap { try? decodeJSON(AIUsageEnvelope.self, $0) }
            let updateRequest = try database.prepare("UPDATE requests SET status=? WHERE request_id=?;")
            try updateRequest.bind(status, at: 1)
            try updateRequest.bind(requestID.uuidString, at: 2)
            try updateRequest.stepDone()
            let payload = AISessionEventPayload.requestSettled(owner: owner, usage: usage, status: status, errorCode: nil).data
            let event = AINewSessionEvent(
                sessionID: owner.sessionID,
                type: .requestSettled,
                turnID: owner.turnID,
                requestID: requestID,
                payload: payload
            )
            try insert(event, nextSequence: try maxSequence(owner.sessionID, in: database) + 1, timestamp: Date(), in: database)
            let updateSession = try database.prepare("UPDATE sessions SET revision=?,updated_at=? WHERE session_id=?;")
            try updateSession.bind(current.revision + 1, at: 1)
            try updateSession.bind(ISODate.encode(Date()), at: 2)
            try updateSession.bind(owner.sessionID.uuidString, at: 3)
            try updateSession.stepDone()
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw persistence(error)
        }
    }

    func settleUsage(owner: AIRequestOwner, envelope: AIUsageEnvelope?) async throws {
        guard let envelope, owner.attemptIndex >= 0,
              (owner.turnID == nil) != (owner.maintenanceID == nil) else {
            throw AISessionStoreError.invalidArguments
        }
        let database = try open()
        do {
            try database.execute("BEGIN IMMEDIATE;")
            guard let current = try readSessionCore(owner.sessionID, in: database) else {
                throw AISessionStoreError.sessionMissing
            }
            try requireWritableIdentity(sessionID: owner.sessionID, terminalID: nil, in: database)
            let requestID = try database.prepare("""
            SELECT session_id, turn_id, maintenance_id, step_index, attempt_index, purpose, status, usage_json
            FROM requests WHERE request_id=?;
            """)
            try requestID.bind(envelope.requestID.uuidString, at: 1)
            let exists = try requestID.stepRow()
            var previous: AIUsageEnvelope?
            if exists {
                guard requestID.text(0) == owner.sessionID.uuidString,
                      requestID.text(1) == owner.turnID?.uuidString,
                      requestID.text(2) == owner.maintenanceID?.uuidString,
                      requestID.int64(3) == owner.stepIndex.map(Int64.init),
                      requestID.int64(4) == Int64(owner.attemptIndex),
                      requestID.text(5) == owner.purpose else {
                    throw AISessionStoreError.invalidArguments
                }
                previous = requestID.data(7).flatMap { try? decodeJSON(AIUsageEnvelope.self, $0) }
            }
            let merged = AIUsageSnapshotMerger.merge(earlier: previous, later: envelope)
            if previous == merged {
                try database.execute("COMMIT;")
                return
            }
            let usageJSON = try encodeJSON(merged)
            if exists {
                let updateRequest = try database.prepare("""
                UPDATE requests SET provider=?, profile_id=?, requested_model=?, actual_model=?, status='settled', usage_json=?
                WHERE request_id=?;
                """)
                try updateRequest.bind(merged.provider, at: 1)
                try updateRequest.bind(merged.profileID.uuidString, at: 2)
                try updateRequest.bind(merged.requestedModel, at: 3)
                try updateRequest.bind(merged.actualModel, at: 4)
                try updateRequest.bind(usageJSON, at: 5)
                try updateRequest.bind(merged.requestID.uuidString, at: 6)
                try updateRequest.stepDone()
            } else {
                let insertRequest = try database.prepare("""
                INSERT INTO requests
                (request_id, session_id, turn_id, maintenance_id, step_index, attempt_index, purpose,
                 provider, profile_id, requested_model, actual_model, status, usage_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,'settled',?);
                """)
                try insertRequest.bind(merged.requestID.uuidString, at: 1)
                try insertRequest.bind(owner.sessionID.uuidString, at: 2)
                try insertRequest.bind(owner.turnID?.uuidString, at: 3)
                try insertRequest.bind(owner.maintenanceID?.uuidString, at: 4)
                try insertRequest.bind(owner.stepIndex.map(Int64.init), at: 5)
                try insertRequest.bind(Int64(owner.attemptIndex), at: 6)
                try insertRequest.bind(owner.purpose, at: 7)
                try insertRequest.bind(merged.provider, at: 8)
                try insertRequest.bind(merged.profileID.uuidString, at: 9)
                try insertRequest.bind(merged.requestedModel, at: 10)
                try insertRequest.bind(merged.actualModel, at: 11)
                try insertRequest.bind(usageJSON, at: 12)
                try insertRequest.stepDone()
            }
            let payload = AISessionEventPayload.requestSettled(
                owner: owner,
                usage: merged,
                status: "settled",
                errorCode: nil
            ).data
            let event = AINewSessionEvent(
                sessionID: owner.sessionID,
                type: previous == nil ? .requestSettled : .usageCorrected,
                turnID: owner.turnID,
                requestID: merged.requestID,
                payload: payload
            )
            try insert(event, nextSequence: try maxSequence(owner.sessionID, in: database) + 1, timestamp: Date(), in: database)
            let updateSession = try database.prepare("UPDATE sessions SET revision=?, updated_at=? WHERE session_id=?;")
            try updateSession.bind(current.revision + 1, at: 1)
            try updateSession.bind(ISODate.encode(Date()), at: 2)
            try updateSession.bind(owner.sessionID.uuidString, at: 3)
            try updateSession.stepDone()
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw persistence(error)
        }
    }
}
