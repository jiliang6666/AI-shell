import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SwiftTerminal

@Test("Native chat controls, history and detail cards render using isolated fixtures")
@MainActor
func assistantLayoutPreviewWithIsolatedData() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalLayoutFixture-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let profileStore = ModelProfileStore(directory: root.appendingPathComponent("profiles"))
    let profile = ModelProfile(name: "工作账号", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat", apiKey: "fixture-not-sent")
    let alternative = ModelProfile(name: "开发账号", baseURL: "https://api.deepseek.com/v1", model: "deepseek-reasoner", apiKey: "fixture-not-sent")
    try profileStore.saveAll([profile, alternative], activeID: profile.id)
    let coordinator = AISessionCoordinator(store: AISessionStore(directory: root.appendingPathComponent("sessions")),
        legacyArchiveURL: root.appendingPathComponent("legacy.json"), resumeExecutionHistory: {})
    let model = TerminalAIModel(terminalSessionID: UUID(), modelProfileStore: profileStore, sessionCoordinator: coordinator,
        archiveLoader: { [] }, archiveWriter: { _ in })
    #expect(await model.selectModel(profile.id, sessionID: model.conversationID))
    var configuration = AIContextConfiguration.standard
    configuration.contextWindowOverride = 32_768
    #expect(await model.updateContextConfiguration(configuration))
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let previewDirectory = ProcessInfo.processInfo.environment["AI_UI_PREVIEW_DIRECTORY"].map { URL(fileURLWithPath: $0) }
    if let previewDirectory { try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true) }

    func render<V: View>(_ view: V, size: NSSize, name: String) async throws {
        let hosting = NSHostingView(rootView: view.background(Color.white).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.frame = NSRect(origin: .zero, size: size)
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(size.width))
        #expect(bitmap.pixelsHigh >= Int(hosting.bounds.height))
        if let previewDirectory = ProcessInfo.processInfo.environment["AI_UI_PREVIEW_DIRECTORY"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: previewDirectory), withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: previewDirectory).appendingPathComponent(name + ".png"))
        }
    }
    for width in [344.0, 400.0, 520.0] {
        try await render(AssistantPanel(targetHost: nil, model: model, panelWidth: width),
            size: NSSize(width: width, height: 650), name: "composer-\(Int(width))")
        let question = AIUserQuestion(callID: "fixture", sessionID: UUID(), turnID: UUID(), requestID: UUID(),
            arguments: AIUserQuestionArguments(question: "检测到已有配置，如何安装？", reason: "覆盖会丢失现有设置，需要你选择。",
                options: [.init(id: "keep", label: "保留现有配置", description: "只补齐缺少的依赖，保留原来的设置。"),
                          .init(id: "replace", label: "重新配置", description: "替换现有配置，从默认设置开始。")], recommendedOptionID: "keep"))
        try await render(AIUserQuestionCard(question: question, onAnswer: { _, _ in }, onCancel: {}),
            size: NSSize(width: width, height: 360), name: "question-\(Int(width))")
        let longQuestion = AIUserQuestion(callID: "long", sessionID: UUID(), turnID: UUID(), requestID: UUID(),
            arguments: AIUserQuestionArguments(question: "发现已有多个环境配置，请选择需要继续使用的配置。",
                reason: "所选配置会决定接下来的安装目录和依赖版本。",
                options: (1...5).map { .init(id: "option-\($0)", label: "保留第 \($0) 套环境配置", description: "保留已安装的依赖和当前目录，只补齐这次任务需要的部分。") },
                recommendedOptionID: "option-1"))
        try await render(AIUserQuestionCard(question: longQuestion, fontSize: 20, onAnswer: { _, _ in }, onCancel: {}),
            size: NSSize(width: width, height: 520), name: "question-large-\(Int(width))")
        let proposal = ProposedShellCommand(id: "fixture", command: "mkdir -p '/tmp/project files'", purpose: "创建项目所需目录", targetName: "本机")
        try await render(AICommandConfirmationCard(proposal: proposal, onApprove: { _ in }, onReject: {}),
            size: NSSize(width: width, height: 290), name: "command-confirm-\(Int(width))")
        var message = ChatMessage(role: "tool", content: "退出码：1\n采集范围：进程输出\n\n依赖版本不匹配。")
        message.commandResult = AICommandResultMetadata(status: .failed, command: "example --version", purpose: "检查依赖版本")
        try await render(AICommandOutputCard(presentation: AICommandResultPresentation(message: message), fontSize: 20),
            size: NSSize(width: width, height: 140), name: "command-result-\(Int(width))")
    }
        try await render(TerminalConversationHistorySheet(terminalID: model.terminalSessionID, currentSessionID: model.conversationID,
        onSelect: { _ in }, onCreate: {}, loadSessions: { _ in [] }), size: NSSize(width: 420, height: 520), name: "history-empty")
    try await render(AIModelPicker(model: model), size: NSSize(width: 310, height: 340), name: "model-picker")
    try await render(AIContextPanel(model: model), size: NSSize(width: 320, height: 520), name: "context-budget")
    var aggregator = AIUsageAggregator()
    aggregator.add(try #require(AIUsageNormalizer.decode(UsageWire(promptTokens: 7168, completionTokens: 445, totalTokens: 7613, promptCacheHitTokens: 6528, promptCacheMissTokens: 640),
        context: AIUsageRequestContext(provider: "deepseek_chat", requestedModel: "deepseek-chat", profileID: profile.id, usageMapping: "deepseek_chat"))))
    try await render(AIUsageDetailsCard(presentation: AIUsagePresentation(aggregator: aggregator, requestCount: 1, modelRequestCounts: ["deepseek-chat": 1]), fallback: ""),
        size: NSSize(width: 320, height: 400), name: "usage-details")
    await model.waitForCurrentTurnCompletion()
    try FileManager.default.removeItem(at: root)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test("Chat composer and history render at accessibility text sizes in all three widths")
@MainActor
func assistantLayoutRendersAtAccessibilityTextSizes() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TerminalAccessibilityLayout-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let profileStore = ModelProfileStore(directory: root.appendingPathComponent("profiles"))
    let profile = ModelProfile(name: "长名称账号-deepseek-official-main", baseURL: "https://api.deepseek.com/v1", model: "deepseek-reasoner", apiKey: "fixture-not-sent")
    try profileStore.saveAll([profile], activeID: profile.id)
    let coordinator = AISessionCoordinator(store: AISessionStore(directory: root.appendingPathComponent("sessions")),
        legacyArchiveURL: root.appendingPathComponent("legacy.json"), resumeExecutionHistory: {})
    let model = TerminalAIModel(terminalSessionID: UUID(), modelProfileStore: profileStore, sessionCoordinator: coordinator,
        archiveLoader: { [] }, archiveWriter: { _ in })
    #expect(await model.selectModel(profile.id, sessionID: model.conversationID))
    model.draft = "动态大字渲染检查：权限全文、加号、模型名和草稿都保持可达。"
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)

    func render<V: View>(_ view: V, size: NSSize, name: String) async throws {
        let hosting = NSHostingView(rootView: view.background(Color.white)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .accessibility3))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.frame = NSRect(origin: .zero, size: size)
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(size.width))
        #expect(bitmap.pixelsHigh >= Int(hosting.bounds.height))
        if let previewDirectory = ProcessInfo.processInfo.environment["AI_UI_PREVIEW_DIRECTORY"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: previewDirectory), withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: previewDirectory).appendingPathComponent(name + ".png"))
        }
    }
    for width in [344.0, 400.0, 520.0] {
        try await render(AssistantPanel(targetHost: nil, model: model, panelWidth: width),
            size: NSSize(width: width, height: 760), name: "composer-a11y-\(Int(width))")
    }
    try await render(TerminalConversationHistorySheet(terminalID: model.terminalSessionID, currentSessionID: model.conversationID,
        onSelect: { _ in }, onCreate: {}, loadSessions: { _ in [] }),
        size: NSSize(width: 420, height: 620), name: "history-a11y")
    await model.waitForCurrentTurnCompletion()
    try FileManager.default.removeItem(at: root)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}
