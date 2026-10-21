import SwiftUI

struct AssistantPanel: View {
    let targetHost: SSHHost?
    let assistantFontSize: Double
    let panelWidth: CGFloat
    @Binding var quote: AIQuote?
    @ObservedObject var model: TerminalAIModel
    @State private var showSettings = false
    @State private var showContextPanel = false
    @State private var showModelPicker = false
    @State private var showHistory = false
    @State private var followsOutput = true

    init(
        targetHost: SSHHost?,
        model: TerminalAIModel,
        assistantFontSize: Double = 14,
        quote: Binding<AIQuote?> = .constant(nil),
        panelWidth: CGFloat = 344
    ) {
        self.targetHost = targetHost
        self.assistantFontSize = assistantFontSize
        self.panelWidth = panelWidth
        self._quote = quote
        _model = ObservedObject(wrappedValue: model)
    }

    private var isLocalTarget: Bool { targetHost == nil }
    private var targetName: String { targetHost?.displayName ?? "本机" }
    private var configured: Bool { model.profile.isConfigured }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if configured {
                conversation
                if let question = model.pendingQuestion {
                    AIUserQuestionCard(question: question, fontSize: assistantFontSize, isSubmitting: model.isAnsweringQuestion, errorMessage: model.errorMessage,
                        onAnswer: { optionID, text in Task { await model.answerQuestion(id: question.id, optionID: optionID, text: text) } },
                        onCancel: { model.stop() })
                        .id(question.id)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                } else if let pending = model.pendingCommand {
                    AICommandConfirmationCard(proposal: pending, fontSize: assistantFontSize,
                        onApprove: { password in Task { await model.approvePendingCommand(sudoPassword: password) } },
                        onReject: { model.rejectPendingCommand() })
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                quoteBanner
                composer
            } else {
                setupPrompt
            }
        }
        .frame(width: panelWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showSettings) {
            ModelSettingsSheet(model: model)
        }
        .sheet(isPresented: $showHistory) {
            TerminalConversationHistorySheet(
                terminalID: model.terminalSessionID,
                currentSessionID: model.conversationID,
                onSelect: { id in model.loadConversation(id: id); showHistory = false },
                onCreate: { model.clearConversation(); showHistory = false }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("AI 助手", systemImage: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            if configured {
                StateBadge(text: targetName, color: targetHost == nil ? .green : .blue)
            }
            Spacer()
            Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .help("当前终端的 AI 会话")
                .disabled(model.isDeletingTerminal)
            if configured {
                Button { model.clearConversation() } label: { Image(systemName: "plus.bubble") }
                    .help("新对话")
                    .disabled(model.isWorking || model.isWaitingForUser || model.isDeletingTerminal)
            }
            Button {
                model.reloadProfilesFromStore()
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("模型设置")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(.bar)
    }

    private var setupPrompt: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("连接你自己的模型")
                .font(.system(size: 14, weight: .semibold))
            Text("设置 OpenAI-compatible API 地址、模型名和 API Key。Key 保存在这台 Mac 的本地 SQLite 数据库中。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("配置模型") {
                model.reloadProfilesFromStore()
                showSettings = true
            }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(24)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.messages.isEmpty {
                        Text("描述你要完成的事情，例如：检查本机是否安装 Docker。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }

                    ForEach(model.presentedMessages) { row in
                        messageView(row)
                            .id(row.id)
                    }

                    if model.isWorking {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(model.executingCommand.map { "正在执行：\($0.purpose)" } ?? "AI 正在处理…")
                                    .font(.system(size: max(12, assistantFontSize - 1)))
                                    .foregroundStyle(.secondary)
                            }
                            if let command = model.executingCommand {
                                AICommandPreview(command: command.command, fontSize: assistantFontSize)
                            }
                        }
                        .id("working")
                    }

                    if let error = model.errorMessage {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("chat.bottom")
                }
                .background(AIChatScrollObserver { followsOutput = $0 })
                .padding(14)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear { proxy.scrollTo("chat.bottom", anchor: .bottom) }
            .onChange(of: model.messages.count) { _, _ in
                if model.messages.last?.role == "user" { followsOutput = true }
                if followsOutput { proxy.scrollTo("chat.bottom", anchor: .bottom) }
            }
            .onChange(of: model.messages.last?.content) { _, _ in
                if followsOutput { proxy.scrollTo("chat.bottom", anchor: .bottom) }
            }
            .onChange(of: model.conversationID) { _, _ in
                followsOutput = true
                proxy.scrollTo("chat.bottom", anchor: .bottom)
            }
            .onChange(of: model.executingCommand?.id) { _, _ in
                if followsOutput { proxy.scrollTo("chat.bottom", anchor: .bottom) }
            }
            .onChange(of: model.errorMessage) { _, _ in
                if followsOutput { proxy.scrollTo("chat.bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func messageView(_ row: AIChatMessageRow) -> some View {
        let message = row.message
        if message.role == "user", let content = message.content {
            HStack {
                Spacer(minLength: 32)
                Text(content)
                    .font(.system(size: assistantFontSize))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.055), lineWidth: 1)
                    }
            }
        } else if message.role == "assistant", let content = message.content, !content.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label("AI", systemImage: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.blue.opacity(0.82))
                MarkdownBlockView(markdown: content, fontSize: assistantFontSize).equatable()
                if let usage = model.usageSummary(after: message) {
                    AIUsageBadge(presentation: model.usagePresentation(for: message.turnID), fallback: usage)
                        .padding(.top, 4)
                }
            }
        } else if message.role == "tool", let content = message.content {
            if message.name == "ask_user" {
                VStack(alignment: .leading, spacing: 4) {
                    Label("你的选择", systemImage: "checkmark.bubble").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(AIUserAnswer.displayText(from: content)).font(.system(size: assistantFontSize)).textSelection(.enabled)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            } else {
                if let result = row.result {
                    AICommandOutputCard(presentation: result, fontSize: assistantFontSize)
                }
            }
        }
    }

    @ViewBuilder
    private var quoteBanner: some View {
        if let quote {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label("引用", systemImage: "text.quote")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(quote.displayLabel)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        self.quote = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("移除引用")
                }
                Text(quote.text)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .padding(1)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: targetHost == nil ? "laptopcomputer" : "server.rack")
                    .font(.system(size: 10))
                Text(targetHost.map { "AI 命令目标：\($0.displayName)（SSH）" } ?? "AI 命令目标：本机")
                    .font(.system(size: 10))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button { showContextPanel = true } label: {
                    Label("上下文", systemImage: "chart.pie")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("查看上下文内容与摘要")
                .popover(isPresented: $showContextPanel, arrowEdge: .bottom) { AIContextPanel(model: model) }
            }
            .foregroundStyle(.secondary)

            if targetHost != nil {
                Label("首次连接请先在终端确认此主机的 SSH 指纹", systemImage: "exclamationmark.shield")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 12) {
                if !model.isWaitingForUser {
                    ComposerTextField(
                        text: $model.draft,
                        placeholder: "输入任务，或 / 调用指令…",
                        font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                        disabled: model.isSubmitting || model.isWorking || model.isWaitingForUser,
                        onSubmit: send
                    )
                    .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("任务输入框")
                }

                HStack(alignment: .center, spacing: 6) {
                Menu {
                    Button("压缩上下文") {
                        dispatch(.compact)
                    }
                    .disabled(model.isWorking || model.isWaitingForUser || model.contextBudget.capacity == nil)
                    Button("模型") {
                        dispatch(.model(nil))
                    }
                    .disabled(!model.canSelectModel)
                    Button("上下文管理") {
                        dispatch(.context)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("更多操作")
                .help("压缩、模型和上下文管理")

                Menu {
                    ForEach(AIPermissionMode.allCases, id: \.self) { mode in
                        Button {
                            Task { _ = await model.setPermission(mode, sessionID: model.conversationID) }
                        } label: {
                            Label(mode.title, systemImage: mode.symbol)
                        }
                    }
                } label: {
                    Label(model.permission.title, systemImage: model.permission.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.isSavingPermission)
                .accessibilityLabel("AI 权限")
                .help(model.permissionHelp)

                Spacer(minLength: 3)
                modelSelector

                if model.isWorking || model.isWaitingForUser {
                    Button {
                        model.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("停止生成并保留已收到的内容")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("发送给模型服务")
                }
                }
            }
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5) }

            Text("按当前权限自动处理，必要时向你确认。对话发送至所选模型服务。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var modelSelector: some View {
        HStack(spacing: 2) {
            Button {
                model.reloadProfilesFromStore()
                showModelPicker = true
            } label: {
                Text(model.profile.model.isEmpty ? "选择模型" : model.profile.model)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 104, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help("选择模型：\(model.profile.name)")
            .accessibilityLabel("选择模型，当前为\(model.profile.model)")
            .popover(isPresented: $showModelPicker, arrowEdge: .bottom) { AIModelPicker(model: model) }

            Menu {
                ForEach(AIModelMenuOptions.groups(profiles: model.profiles, query: "")) { group in
                    Section(group.title) {
                        ForEach(group.profiles) { profile in
                            Button { Task { _ = await model.selectModel(profile.id, sessionID: model.conversationID) } } label: {
                                if profile.id == model.profile.id {
                                    Label("\(profile.name) · \(profile.model)", systemImage: "checkmark")
                                } else {
                                    Text("\(profile.name) · \(profile.model)")
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("搜索模型…") { showModelPicker = true }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("模型下拉选择")
        }
        .foregroundStyle(.secondary)
        .disabled(!model.canSelectModel)
    }

    private var canSend: Bool {
        !model.isWaitingForUser
            && !model.isWorking
            && !model.isSubmitting
            && (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || quote != nil)
    }

    private func send() {
        let value = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if AISlashCommandParser.isCandidate(value) {
            guard quote == nil else {
                model.errorMessage = "先移除引用，再运行本地指令。"
                return
            }
            switch AISlashCommandParser.parse(value) {
            case .success(let command):
                dispatch(command) { model.draft = "" }
            case .failure(let error):
                model.errorMessage = error == .unknownCommand ? "未知指令：\(value)" : "指令参数无效。"
            }
            return
        }
        let attached = quote
        guard !value.isEmpty || attached != nil else { return }
        var message = value
        if let attached {
            let header = "引用（\(attached.displayLabel)）："
            message = "\(header)\n```\n\(attached.text)\n```\n\n\(value)"
        }
        Task {
            let accepted = await model.send(message)
            if accepted {
                model.draft = ""
                quote = nil
            }
        }
    }

    private func dispatch(_ command: AISlashCommand, onAccepted: (() -> Void)? = nil) {
        Task {
            switch await model.dispatchCommand(command) {
            case .completed:
                onAccepted?()
            case .openModels:
                onAccepted?()
                showModelPicker = true
            case .openContext:
                onAccepted?()
                showContextPanel = true
            case .noChange(let message):
                model.errorMessage = message
            }
        }
    }
}

private struct AIUsageBadge: View {
    let presentation: AIUsagePresentation?
    let fallback: String
    @State private var showingDetails = false

    var body: some View {
        Button { showingDetails.toggle() } label: {
            Label(usageLabel, systemImage: "cylinder")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("本轮用量，\(presentation?.total ?? fallback)，缓存命中率 \(cacheHitRateText ?? "未提供")，点击查看明细")
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            AIUsageDetailsCard(presentation: presentation, fallback: fallback)
        }
    }

    private var usageLabel: String {
        let total = presentation?.compactTotal ?? (fallback.contains("统计中") ? "统计中…" : "未提供")
        guard let cacheHitRateText else { return "用量 \(total)" }
        return "用量 \(total) · 命中 \(cacheHitRateText)"
    }

    private var cacheHitRateText: String? {
        presentation?.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) }
    }
}

struct AIUsageDetailsCard: View {
    let presentation: AIUsagePresentation?
    let fallback: String

    var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("本轮用量", systemImage: "cylinder").font(.headline)
                    Spacer(minLength: 8)
                    Text(presentation?.total ?? "未提供").font(.system(size: 13, weight: .medium)).multilineTextAlignment(.trailing)
                }
                Divider()
                if let presentation {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                        ForEach(presentation.rows) { row in
                            GridRow {
                                Text(row.label).foregroundStyle(.secondary)
                                Text(row.value).frame(maxWidth: .infinity, alignment: .trailing)
                                    .multilineTextAlignment(.trailing).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.system(size: 12))
                    if !presentation.requestRows.isEmpty {
                        Divider()
                        Text("逐次请求缓存").font(.caption.weight(.medium))
                        ForEach(presentation.requestRows) { row in
                            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                                GridRow {
                                    Text(row.label).foregroundStyle(.secondary)
                                    Text(row.value).frame(maxWidth: .infinity, alignment: .trailing)
                                        .multilineTextAlignment(.trailing).textSelection(.enabled)
                                }
                            }
                            .font(.system(size: 11))
                        }
                    }
                    if presentation.modelRows.count > 1 {
                        Divider()
                        Text("按模型统计").font(.caption.weight(.medium))
                        ForEach(presentation.modelRows) { row in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.label).font(.caption.weight(.medium))
                                Text(row.value).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else { Text(fallback).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(16).frame(width: 320).fixedSize(horizontal: false, vertical: true)
    }
}

struct AIContextPanel: View {
    @ObservedObject var model: TerminalAIModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("上下文").font(.headline)
                    Spacer()
                    Button("完成") { dismiss() }.buttonStyle(.bordered)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("模型").foregroundStyle(.secondary)
                        Text(model.profile.model.isEmpty ? "未配置" : model.profile.model)
                    }
                    ForEach(Array(model.contextComponentEstimates.enumerated()), id: \.offset) { _, component in
                        GridRow {
                            Text(component.name).foregroundStyle(.secondary)
                            Text("约 \(component.tokens) tokens")
                        }
                    }
                }
                .font(.system(size: 12))
                if let summary = model.contextSummaryForDisplay, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("当前摘要").font(.caption.weight(.semibold))
                        Text(summary)
                            .font(.caption)
                            .textSelection(.enabled)
                            .lineLimit(6)
                    }
                }
                Text("以上为估算值。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(width: 320, height: 300)
    }
}

struct AIModelPicker: View {
    @ObservedObject var model: TerminalAIModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selecting = false

    private var groups: [AIModelMenuGroup] { AIModelMenuOptions.groups(profiles: model.profiles, query: search) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择模型").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("关闭模型选择")
            }
            .padding(.bottom, 10)
            TextField("搜索模型…", text: $search)
                .textFieldStyle(.roundedBorder).accessibilityLabel("搜索模型").padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if groups.isEmpty {
                        Text(search.isEmpty ? "还没有保存的模型配置。" : "没有匹配的模型。")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 18)
                    }
                    ForEach(groups) { group in
                        Text(group.title).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 6)
                        ForEach(group.profiles) { profile in
                            Button {
                                selecting = true
                                Task {
                                    if await model.selectModel(profile.id, sessionID: model.conversationID) { dismiss() }
                                    selecting = false
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.model.isEmpty ? "未设置模型" : profile.model).font(.system(size: 13, weight: .medium))
                                        Text(profile.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    if profile.id == model.profile.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
                                .background(profile.id == model.profile.id ? Color.primary.opacity(0.055) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain).disabled(!model.canSelectModel || selecting)
                            .accessibilityLabel("\(profile.name)，\(profile.model)\(profile.id == model.profile.id ? "，当前模型" : "")")
                        }
                    }
                }
            }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red).padding(.top, 8) }
        }
        .padding(14).frame(width: 310, height: 340)
    }
}

private struct ModelSettingsSheet: View {
    @ObservedObject var model: TerminalAIModel
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ModelProfile
    @State private var profiles: [ModelProfile]
    @State private var contextCapacityTexts: [UUID: String] = [:]
    @State private var saveError: String?
    @State private var pendingProfileDelete = false
    @State private var testingConnection = false
    @State private var saving = false
    @State private var connectionResult: String?

    init(model: TerminalAIModel) {
        self.model = model
        _profile = State(initialValue: model.profile)
        _profiles = State(initialValue: model.profiles)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("模型 API")
                .font(.system(size: 17, weight: .semibold))
            Text("支持 OpenAI Chat Completions 及兼容接口。可填服务根地址或完整的 `/chat/completions` 地址；需要 `/v1` 的服务请把 `/v1` 写入 Base URL。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack {
                Picker("配置", selection: Binding(
                    get: { profile.id },
                    set: { selected in
                        profiles = profiles.map { $0.id == profile.id ? profile : $0 }
                        if let value = profiles.first(where: { $0.id == selected }) { profile = value }
                    }
                )) {
                    ForEach(profiles) { value in Text(value.name).tag(value.id) }
                }
                Button("新增") {
                    let value = ModelProfile(name: "新模型", baseURL: "https://api.openai.com/v1")
                    profiles.append(value)
                    profile = value
                }
                Button("删除") {
                    pendingProfileDelete = true
                }
                .disabled(profiles.count < 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("配置名称") {
                    TextField("例如 DeepSeek", text: $profile.name).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Base URL") {
                    TextField("https://api.example.com/v1", text: $profile.baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("模型名") {
                    TextField("model-id", text: $profile.model)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("上下文容量") {
                    TextField("例如 1m、256k；留空表示未知", text: Binding(
                        get: { contextCapacityTexts[profile.id] ?? ModelContextCapacity.display(profile.contextWindow) },
                        set: { contextCapacityTexts[profile.id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("模型上下文容量")
                }
                LabeledContent("API Key") {
                    SecureField("sk-…", text: $profile.apiKey)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("模型配置与 API Key 保存在当前用户的本机 SQLite 数据库（model-library.sqlite3）；目录权限为 700、数据库文件权限为 600。安装包不含个人模型配置。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Button(testingConnection ? "正在测试…" : "测试连接") {
                    testingConnection = true
                    connectionResult = nil
                    Task {
                        connectionResult = await model.testConnection(profile)
                        testingConnection = false
                    }
                }
                .disabled(!profile.isConfigured || testingConnection)
                if testingConnection { ProgressView().controlSize(.small) }
                if let connectionResult { Text(connectionResult).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Text("测试会发送一条不含终端资料的短请求，只检查认证、接口和流式响应，不运行工具。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            if let saveError {
                Text(saveError).font(.system(size: 11)).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    saving = true
                    Task { @MainActor in
                        defer { saving = false }
                        do {
                            guard profiles.contains(where: { $0.id == profile.id }) else { throw ModelSettingsError.missingProfile }
                            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  !profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                throw ModelSettingsError.missingNameOrAddress
                            }
                            let updated = try profiles.map { value -> ModelProfile in
                                var candidate = value.id == profile.id ? profile : value
                                if let text = contextCapacityTexts[candidate.id] {
                                    candidate.contextWindow = try ModelContextCapacity.parse(text)
                                }
                                return candidate
                            }
                            guard let active = updated.first(where: { $0.id == profile.id }) else {
                                throw ModelSettingsError.missingProfile
                            }
                            try model.saveProfiles(updated, active: active)
                            if model.canSelectModel {
                                guard await model.selectModel(profile.id, sessionID: model.conversationID) else {
                                    saveError = "模型库已保存，但当前会话切换失败。请重试选择模型。"
                                    return
                                }
                            }
                            dismiss()
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving || profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .confirmationDialog("删除这套模型配置？", isPresented: $pendingProfileDelete, titleVisibility: .visible) {
            Button("删除配置", role: .destructive) {
                guard profiles.count > 1 else { return }
                profiles.removeAll { $0.id == profile.id }
                profile = profiles[0]
            }
            Button("取消", role: .cancel) { pendingProfileDelete = false }
        } message: {
            Text("配置会在你保存设置后从本机移除。")
        }
    }
}

private enum ModelSettingsError: LocalizedError {
    case missingProfile
    case missingNameOrAddress
    var errorDescription: String? {
        switch self {
        case .missingProfile: "模型配置已移除，请选择或新建配置。"
        case .missingNameOrAddress: "请填写模型名称和 API 地址。"
        }
    }
}


struct TerminalConversationHistorySheet: View {
    let terminalID: UUID?
    let currentSessionID: UUID
    let onSelect: (UUID) -> Void
    let onCreate: () -> Void
    var loadSessions: @MainActor (UUID) async throws -> [AISessionSummary] = { terminalID in
        await AISessionCoordinator.shared.bootstrap()
        return try await AISessionCoordinator.shared.listForTerminal(terminalID)
    }
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [AISessionSummary] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("当前终端的 AI 会话").font(.title3.weight(.semibold))
                Spacer()
                Button { onCreate() } label: { Label("新对话", systemImage: "plus") }
                    .disabled(loading || error != nil)
            }
            .padding(18)
            Divider()
            Group {
            if loading {
                ProgressView("正在读取会话…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("无法读取会话", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if sessions.isEmpty {
                ContentUnavailableView("还没有保存的会话", systemImage: "clock.arrow.circlepath", description: Text("发送第一条消息后，会话会显示在这里。"))
            } else {
                List(sessions) { session in
                    Button { onSelect(session.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: session.id == currentSessionID ? "checkmark.circle.fill" : "bubble.left")
                                .foregroundStyle(session.id == currentSessionID ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title).lineLimit(1).foregroundStyle(.primary)
                                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(session.title)，\(session.updatedAt.formatted(date: .abbreviated, time: .shortened))\(session.id == currentSessionID ? "，当前会话" : "")")
                }
                .listStyle(.inset)
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 420, height: 520, alignment: .topLeading)
        .task(id: terminalID) { await load() }
    }

    private func load() async {
        guard let terminalID else { loading = false; error = "终端身份不可用。"; return }
        loading = true
        error = nil
        do {
            sessions = try await loadSessions(terminalID)
            loading = false
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
    }
}
