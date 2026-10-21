import CSQLite
import Foundation
import Testing
@testable import SwiftTerminal

@Test("Command timeout presentation supports current and saved result envelopes", arguments: ["执行超时", "超过 180 秒"])
func commandTimeoutPresentation(_ status: String) {
    let result = "退出码：未知（\(status)）\n采集范围：完整输出\n\nfixture output"
    #expect(AICommandResultPresentation.content(result) == "命令执行超时。\n\nfixture output")
    #expect(AICommandResultPresentation.content("执行超时\n\n普通输出") == "执行超时\n\n普通输出")
}

@Test("Hidden-file preference is backward compatible and round trips", arguments: [true, false])
func hiddenFilePreferenceRoundTrip(_ show: Bool) throws {
    #expect(try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8)).showHiddenFiles == false)
    var preferences = AppPreferences()
    preferences.showHiddenFiles = show
    #expect(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences)).showHiddenFiles == show)
}

@Test("Dot files and directories share the visibility rule and fixture cleanup completes")
func hiddenFileVisibilityAndCleanup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalVisibility-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".config"), withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: root.appendingPathComponent(".secret"))
    try Data("fixture".utf8).write(to: root.appendingPathComponent("notes.txt"))
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(names.filter { FileVisibilityPolicy.isVisible(name: $0, showHiddenFiles: false) } == ["notes.txt"])
    #expect(names.filter { FileVisibilityPolicy.isVisible(name: $0, showHiddenFiles: true) }.sorted() == [".config", ".secret", "notes.txt"])
    #expect(!FileVisibilityPolicy.isVisible(name: ".", showHiddenFiles: true))
    #expect(!FileVisibilityPolicy.isVisible(name: "..", showHiddenFiles: true))
    #expect(FileVisibilityPolicy.isVisible(name: "notes.hidden.txt", showHiddenFiles: false))
    try FileManager.default.removeItem(at: root)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test("Model search groups providers and preserves distinct configurations with the same model")
func modelMenuSearchPreservesConfigurationIDs() {
    let a = ModelProfile(name: "工作账号", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat", apiKey: "fixture")
    let b = ModelProfile(name: "私人账号", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat", apiKey: "fixture")
    let c = ModelProfile(name: "开发", baseURL: "https://api.openai.com/v1", model: "test-model", apiKey: "fixture")
    let all = AIModelMenuOptions.groups(profiles: [a, b, c], query: "")
    #expect(all.map(\.title) == ["DeepSeek", "OpenAI"])
    #expect(all[0].profiles.map(\.id) == [a.id, b.id])
    #expect(AIModelMenuOptions.groups(profiles: [a, b, c], query: "DEEPSEEK 私人").flatMap(\.profiles).map(\.id) == [b.id])
    #expect(AIModelMenuOptions.groups(profiles: [a, b, c], query: "missing").isEmpty)
}

@Test("Usage card shows the reported total and marks the derived cache write")
func usageCardKnownAndUnknownFields() throws {
    let envelope = try #require(AIUsageNormalizer.decode(
        UsageWire(promptTokens: 7168, completionTokens: 445, totalTokens: 7613, promptCacheHitTokens: 6528, promptCacheMissTokens: 640),
        context: AIUsageRequestContext(provider: "deepseek_chat", requestedModel: "fixture-model", profileID: UUID(), usageMapping: "deepseek_chat")))
    var aggregator = AIUsageAggregator()
    aggregator.add(envelope)
    let card = AIUsagePresentation(aggregator: aggregator, requestCount: 1, modelRequestCounts: ["fixture-model": 1])
    #expect(card.total == "7,613 tok")
    #expect(card.compactTotal == "7.6K tok")
    #expect(card.cacheHitRate == 6528.0 / 7168.0)
    #expect(card.rows.first(where: { $0.label == "缓存命中" })?.value == "91.1%")
    #expect(card.rows.first(where: { $0.label == "缓存写入" })?.value == "640 tok（推算）")
    #expect(card.rows.first(where: { $0.label == "未缓存输入" })?.value == "640 tok")
    #expect(card.rows.first(where: { $0.label == "缓存读取" })?.value == "6,528 tok")
}

@Test("Usage card marks missing-request coverage partial instead of presenting a complete total")
func usageCardPartialCoverage() throws {
    let envelope = try #require(AIUsageNormalizer.decode(UsageWire(promptTokens: 10, completionTokens: 2, totalTokens: 12),
        context: AIUsageRequestContext(provider: "fixture", requestedModel: "model-A", profileID: UUID(), usageMapping: "openai_chat")))
    var aggregator = AIUsageAggregator()
    aggregator.add(envelope)
    let card = AIUsagePresentation(aggregator: aggregator, requestCount: 2, modelRequestCounts: ["model-A": 1, "model-B": 1])
    #expect(card.total.contains("部分"))
    #expect(card.cacheHitRate == nil)
    #expect(card.rows.first(where: { $0.label == "缓存命中" })?.value == "数据不完整")
    #expect(card.rows.first(where: { $0.label == "请求覆盖" })?.value == "1 / 2 次")
    #expect(card.modelRows.first(where: { $0.label == "model-B" })?.value.contains("未提供") == true)
}

@Test("Permission downgrade write failure stays visible and blocks sending until the retry succeeds")
@MainActor
func permissionDowngradeWriteFailureStaysVisibleAndBlocksSending() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIPermissionFault-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let profileStore = ModelProfileStore(directory: root.appendingPathComponent("profiles"))
    let profile = ModelProfile(name: "故障账号", baseURL: "https://api.example.com/v1", model: "fixture-model", apiKey: "fixture-not-sent")
    try profileStore.saveAll([profile], activeID: profile.id)
    let store = AISessionStore(directory: root.appendingPathComponent("sessions"))
    let coordinator = AISessionCoordinator(store: store,
        legacyArchiveURL: root.appendingPathComponent("legacy.json"), resumeExecutionHistory: {})
    let model = TerminalAIModel(terminalSessionID: UUID(), modelProfileStore: profileStore,
        sessionCoordinator: coordinator, archiveLoader: { [] }, archiveWriter: { _ in })
    #expect(await model.selectModel(profile.id, sessionID: model.conversationID))
    let secondLocal = TerminalAIModel(terminalSessionID: UUID(), modelProfileStore: profileStore,
        sessionCoordinator: coordinator, archiveLoader: { [] }, archiveWriter: { _ in })
    let ssh = TerminalAIModel(target: SSHHost(name: "fixture", address: "192.0.2.1", username: "fixture"),
        terminalSessionID: UUID(), modelProfileStore: profileStore, sessionCoordinator: coordinator,
        archiveLoader: { [] }, archiveWriter: { _ in })
    #expect(await secondLocal.selectModel(profile.id, sessionID: secondLocal.conversationID))
    #expect(await ssh.selectModel(profile.id, sessionID: ssh.conversationID))
    #expect(await model.setPermission(.fullAccess, sessionID: model.conversationID))
    #expect(secondLocal.permission == .fullAccess)

    var blocker: OpaquePointer?
    let databaseFile = root.appendingPathComponent("sessions/ai-sessions.sqlite3").path
    #expect(sqlite3_open(databaseFile, &blocker) == SQLITE_OK)
    defer { sqlite3_close(blocker) }
    #expect(sqlite3_exec(blocker, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)

    let failedDowngrade = await model.setPermission(.readOnly, sessionID: model.conversationID)
    #expect(!failedDowngrade)
    #expect(model.permission == .readOnly)
    #expect(secondLocal.permission == .readOnly)
    #expect(ssh.permission == .readOnly)
    #expect(!(await secondLocal.send("不应接受另一个终端的任务")))
    #expect(secondLocal.errorMessage?.contains("尚未保存") == true)
    #expect(model.errorMessage?.contains("权限保存失败") == true)
    let blockedSend = await model.send("这轮不应被接受")
    #expect(!blockedSend)
    #expect(model.errorMessage?.contains("尚未保存") == true)

    #expect(sqlite3_exec(blocker, "ROLLBACK;", nil, nil, nil) == SQLITE_OK)
    let retriedDowngrade = await model.setPermission(.readOnly, sessionID: model.conversationID)
    #expect(retriedDowngrade)
    #expect(model.permission == .readOnly)
    #expect(model.errorMessage == nil)
    #expect(secondLocal.permission == .readOnly)
    #expect(secondLocal.errorMessage == nil)
    await model.waitForCurrentTurnCompletion()
}

@Test("An interrupted command reports its real cause instead of blaming the terminal")
func interruptedCommandReportsRealCause() {
    var result = ShellCommandResult(output: "Password:", exitCode: -1, timedOut: true)
    result.exitCodeUnknown = true
    result.interruptedNotice = "命令停在 sudo 密码提示上，已中断；请在命令确认时提供 sudo 密码，或先执行 sudo -v 后重试"
    result.terminalReturnedToPrompt = true
    let message = AICommandPausePresentation.message(for: result)
    #expect(message.contains("sudo 密码"))
    #expect(!message.contains("请检查绑定终端"))
    #expect(message.contains("继续"))
}

@Test("An unverified terminal keeps the binding warning")
func unverifiedTerminalKeepsBindingWarning() {
    var result = ShellCommandResult(output: "", exitCode: -1, timedOut: true)
    result.exitCodeUnknown = true
    result.interruptedNotice = "命令在超时内未返回完成证明"
    result.terminalReturnedToPrompt = false
    let message = AICommandPausePresentation.message(for: result)
    #expect(message.contains("请检查"))
    #expect(message.contains("命令在超时内未返回完成证明"))
}

@Test("A result with no reported reason keeps the unknown-state wording")
func unknownStateWithoutReasonKeepsWording() {
    let result = ShellCommandResult(output: "", exitCode: -1, timedOut: true)
    #expect(AICommandPausePresentation.message(for: result)
        == "命令完成状态未知，本轮已暂停。请检查绑定终端后再继续。")
}
