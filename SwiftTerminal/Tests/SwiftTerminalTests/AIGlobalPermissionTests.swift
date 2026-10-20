import Foundation
import Testing
@testable import SwiftTerminal

@Test("Local and SSH choices synchronize independently and survive history deletion and reopening")
@MainActor
func globalAIPermissionsSurviveDeletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GlobalPermission-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let profileStore = ModelProfileStore(directory: root.appendingPathComponent("profiles"))
    let profile = ModelProfile(name: "fixture", baseURL: "https://api.example.com/v1", model: "fixture", apiKey: "not-sent")
    try profileStore.saveAll([profile], activeID: profile.id)
    let store = AISessionStore(directory: root.appendingPathComponent("sessions"),
        executionHistoryTombstonesURL: root.appendingPathComponent("deleted-terminals.json"))
    let coordinator = AISessionCoordinator(store: store, legacyArchiveURL: root.appendingPathComponent("legacy.json"), resumeExecutionHistory: {})
    func model(_ host: SSHHost? = nil) -> TerminalAIModel {
        TerminalAIModel(target: host, terminalSessionID: UUID(), modelProfileStore: profileStore,
                        sessionCoordinator: coordinator, httpTransport: OpenPermissionTestTransport(), archiveLoader: { [] }, archiveWriter: { _ in })
    }
    let local = model(), secondLocal = model()
    let ssh = model(SSHHost(name: "A", address: "192.0.2.1", username: "fixture"))
    let secondSSH = model(SSHHost(name: "B", address: "192.0.2.2", username: "fixture"))
    for item in [local, secondLocal, ssh, secondSSH] {
        #expect(await item.selectModel(profile.id, sessionID: item.conversationID))
    }
    #expect(await local.setPermission(.fullAccess, sessionID: local.conversationID))
    #expect(secondLocal.permission == .fullAccess)
    #expect(ssh.permission == .readOnly)
    #expect(await ssh.setPermission(.terminalOnly, sessionID: ssh.conversationID))
    #expect(secondSSH.permission == .terminalOnly)
    #expect(local.permission == .fullAccess)

    let oldConversation = local.conversationID
    local.clearConversation()
    #expect(await local.selectModel(profile.id, sessionID: local.conversationID))
    #expect(local.permission == .fullAccess)
    #expect(await secondLocal.send("fixture local request"))
    #expect(await ssh.send("fixture SSH request"))
    #expect(secondLocal.isWorking && ssh.isWorking)
    #expect(await local.setPermission(.readOnly, sessionID: local.conversationID))
    #expect(!secondLocal.isWorking)
    #expect(ssh.isWorking) // Local downgrade does not cancel SSH work.
    ssh.stop()
    local.loadConversation(id: oldConversation)
    #expect(await local.selectModel(profile.id, sessionID: oldConversation))
    #expect(local.permission == .readOnly) // Historical full access cannot overwrite the shared choice.
    #expect(await local.setPermission(.fullAccess, sessionID: oldConversation))
    for item in [local, secondLocal, ssh, secondSSH] {
        await item.prepareForTerminalDeletion()
        try await coordinator.deleteTerminalHistory(terminalID: try #require(item.terminalSessionID))
    }
    #expect(try await store.list().isEmpty)
    // A fresh coordinator reads durable preferences instead of in-memory state.
    let reopened = AISessionCoordinator(store: store, legacyArchiveURL: root.appendingPathComponent("legacy.json"), resumeExecutionHistory: {})
    await reopened.bootstrap()
    #expect(reopened.permissionPreferences[.local]?.mode == .fullAccess)
    #expect(reopened.permissionPreferences[.ssh]?.mode == .terminalOnly)
    let newLocal = try #require(await reopened.ensureSession(id: UUID(), target: .local(workingDirectory: nil), profileID: nil))
    let newSSH = try #require(await reopened.ensureSession(id: UUID(), target: AITargetSnapshot(hostID: UUID(), terminalSessionID: UUID(), displayName: "new SSH"), profileID: nil))
    #expect(newLocal.permission == .fullAccess)
    #expect(newSSH.permission == .terminalOnly)
    await reopened.clearAll()
    #expect(try await store.permissionPreferences()[.local] == .fullAccess)
    #expect(try await store.permissionPreferences()[.ssh] == .terminalOnly)
}

@Test("Existing explicit permission choices migrate once, separately for local and SSH")
func globalAIPermissionsMigrateExistingChoices() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PermissionMigration-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AISessionStore(directory: root)
    let local = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let ssh = try await store.create(target: AITargetSnapshot(hostID: UUID(), terminalSessionID: UUID(), displayName: "SSH"), modelProfileID: nil)
    for (session, mode) in [(local, AIPermissionMode.fullAccess), (ssh, .terminalOnly)] {
        _ = try await store.append([AINewSessionEvent(sessionID: session.id, type: .permissionChanged,
                payload: AISessionEventPayload.permissionChanged(old: .readOnly, new: mode).data)], expectedRevision: session.revision)
    }
    _ = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let preferences = try await store.permissionPreferences()
    #expect(preferences[.local] == .fullAccess)
    #expect(preferences[.ssh] == .terminalOnly)
    try await store.clearAll()
    #expect(try await store.permissionPreferences() == preferences)
}

@Test("Permission choices survive a fresh database connection")
func globalAIPermissionsPersistAcrossStoreLifetime() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PermissionRestart-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    func save() async throws {
        let store = AISessionStore(directory: root)
        _ = try await store.permissionPreferences()
        let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
        _ = try await store.append([AINewSessionEvent(sessionID: session.id, type: .permissionChanged,
            payload: AISessionEventPayload.permissionChanged(old: .readOnly, new: .terminalOnly).data)],
            expectedRevision: session.revision, permissionPreference: (.local, .terminalOnly))
        try await store.clearAll()
    }
    try await save()
    let freshStore = AISessionStore(directory: root)
    #expect(try await freshStore.permissionPreferences()[.local] == .terminalOnly)
    #expect(try await freshStore.permissionPreferences()[.ssh] == .readOnly)
}

private struct OpenPermissionTestTransport: AIHTTPStreamTransport {
    func stream(for request: URLRequest) async throws -> AIHTTPStreamResponse {
        // No network is contacted. The response remains open until cancellation.
        AIHTTPStreamResponse(statusCode: 200, headers: [:], bytes: AsyncThrowingStream { _ in })
    }
}

@Test("A rejected permission transaction cannot change either preferences or session history")
func globalAIPermissionsRejectWrongScopeAtomically() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PermissionAtomic-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AISessionStore(directory: root)
    let original = try await store.permissionPreferences()
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let event = AINewSessionEvent(sessionID: session.id, type: .permissionChanged,
        payload: AISessionEventPayload.permissionChanged(old: .readOnly, new: .fullAccess).data)
    await #expect(throws: AISessionStoreError.invalidArguments) {
        try await store.append([event], expectedRevision: session.revision, permissionPreference: (.ssh, .fullAccess))
    }
    #expect(try await store.permissionPreferences() == original)
    #expect(try await store.load(sessionID: session.id).revision == session.revision)
    #expect(try await store.readEvents(sessionID: session.id).count == 1)
}
