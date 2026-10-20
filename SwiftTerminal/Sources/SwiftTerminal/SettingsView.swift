import AppKit
import SwiftUI

/// Native macOS settings window (`⌘,`), replacing the previous sheet. Changes
/// are written immediately and broadcast so open terminals update live.
struct SettingsView: View {
    @State private var preferences = AppPreferences.load()
    @State private var workingDirectoryDraft = AppPreferences.load().workingDirectory
    @State private var profiles: [ModelProfile] = []
    @State private var activeProfileID: UUID?
    @State private var error: String?
    @State private var status: String?
    @State private var pendingClear: Int?
    @State private var editingProfile: ModelProfile?
    @State private var pendingProfileDelete: ModelProfile?

    private static var dataDirectory: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftTerminal", isDirectory: true)
            .path
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
            terminalTab
                .tabItem { Label("终端", systemImage: "terminal") }
            modelTab
                .tabItem { Label("模型", systemImage: "sparkles") }
            UpdateSettingsPanel(updater: .shared)
                .tabItem { Label("更新", systemImage: "arrow.down.circle") }
            dataTab
                .tabItem { Label("数据", systemImage: "externaldrive") }
        }
        .frame(width: 560, height: 440)
        .task { reloadProfiles() }
        .onReceive(NotificationCenter.default.publisher(for: .modelProfilesChanged)) { _ in reloadProfiles() }
        .onChange(of: preferences) { _, _ in persist() }
        .confirmationDialog(
            pendingClear == 0 ? "清除所有命令历史？" : "清除所有 AI 对话？",
            isPresented: Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } }),
            titleVisibility: .visible
        ) {
            Button("永久清除", role: .destructive) {
                if pendingClear == 0 { ExecutionHistoryStore.clearAll(); status = "已清除命令历史。" }
                if pendingClear == 1 { ConversationArchive.clearAll(); status = "已清除 AI 对话记录。" }
                pendingClear = nil
            }
            Button("取消", role: .cancel) { pendingClear = nil }
        } message: {
            Text("此操作会删除本机对应历史记录，无法恢复。")
        }
        .sheet(item: $editingProfile) { draft in
            ModelProfileEditorSheet(profile: draft) { saved in
                saveProfile(saved, makeActive: !profiles.contains(where: { $0.id == saved.id }))
            }
        }
        .confirmationDialog(
            "删除这套模型配置？",
            isPresented: Binding(get: { pendingProfileDelete != nil }, set: { if !$0 { pendingProfileDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除配置", role: .destructive) { deletePendingProfile() }
            Button("取消", role: .cancel) { pendingProfileDelete = nil }
        } message: {
            Text("此配置会从本机模型数据库移除。")
        }
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $preferences.appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.radioGroup)
                Picker("界面语言", selection: $preferences.language) {
                    Text("简体中文").tag("简体中文")
                }
                .disabled(true)
            }
            Section("工作区") {
                Toggle("显示隐藏文件", isOn: $preferences.showHiddenFiles)
                Text("显示名称以“.”开头的文件和文件夹，适用于本机和 SSH 文件浏览。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("默认工作区") {
                    HStack(spacing: 8) {
                        TextField("路径", text: $workingDirectoryDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitWorkingDirectory)
                        Button("选择…") { chooseWorkingDirectory() }
                    }
                }
                Text("新的 AI 任务默认在此目录中执行；已打开的终端不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("AI 权限") {
                LabeledContent("新会话默认权限", value: AIPermissionMode.readOnly.title)
                Text("在聊天输入框下方选择每条会话的权限；固定只读检查自动执行，其他操作按会话权限自动路由。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("AI 上下文") {
                Stepper("保留最近 \(preferences.keepRecentTurns) 轮", value: $preferences.keepRecentTurns, in: 1...20)
                Slider(value: $preferences.triggerRatio, in: 0.5...0.95, step: 0.05) {
                    Text("自动压缩阈值")
                }
                Text("上下文达到预计输入的 \(Int(preferences.triggerRatio * 100))% 时自动压缩；保留最近 \(preferences.keepRecentTurns) 轮不参与摘要。适用于所有 AI 会话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("AI 执行") {
                Stepper("等待终端就绪 \(preferences.aiReadinessTimeoutSeconds) 秒",
                        value: $preferences.aiReadinessTimeoutSeconds,
                        in: AIReadinessTimeout.range,
                        step: 5)
                Text("AI 把命令键入你正在使用的终端，再读取屏幕上打印的结果。派发前会等待终端回到提示符并清空未提交的输入；超过这个时间就拒绝派发，并在对话里说明原因。适用于所有 AI 会话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 终端

    private var terminalTab: some View {
        Form {
            Section("字体") {
                LabeledContent("终端字号") {
                    HStack(spacing: 10) {
                        Slider(value: $preferences.terminalFontSize, in: 9...28, step: 1)
                        Text("\(Int(preferences.terminalFontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("AI 助手字号") {
                    HStack(spacing: 10) {
                        Slider(value: $preferences.assistantFontSize, in: 10...24, step: 1)
                        Text("\(Int(preferences.assistantFontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section("Shell") {
                TextField("本机 Shell 路径", text: $preferences.shellPath)
                    .textFieldStyle(.roundedBorder)
                TextField("起始目录", text: $preferences.startDirectory, prompt: Text("留空则使用默认目录"))
                    .textFieldStyle(.roundedBorder)
                Text("鼠标点击定位当前命令由本机的 zsh 集成提供；SSH 终端使用远端 Shell 的原生鼠标行为。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Shell 和起始目录仅用于本机终端，在新建或重启终端时生效；其他选项会立即应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("显示与滚动") {
                Picker("配色方案", selection: $preferences.terminalPaletteID) {
                    ForEach(TerminalPalette.presets) { palette in
                        Text(palette.name).tag(palette.id)
                    }
                }
                Picker("光标样式", selection: $preferences.terminalCursorID) {
                    ForEach(TerminalCursorPreference.allCases) { cursor in
                        Text(cursor.rawValue).tag(cursor.rawValue)
                    }
                }
                Picker("回滚行数", selection: $preferences.scrollbackLines) {
                    Text("1,000 行").tag(1_000)
                    Text("5,000 行").tag(5_000)
                    Text("10,000 行").tag(10_000)
                    Text("50,000 行").tag(50_000)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 模型

    private var modelTab: some View {
        Form {
            Section {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if profiles.isEmpty {
                    Text("还没有模型配置。").foregroundStyle(.secondary)
                } else {
                    ForEach(profiles) { profile in
                        HStack(spacing: 10) {
                            Image(systemName: "cpu")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(profile.name)
                                    if profile.id == activeProfileID {
                                        Text("当前")
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                                    }
                                }
                                Text(profile.model.isEmpty ? profile.baseURL : "\(profile.model) · \(profile.baseURL)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if !profile.isConfigured {
                                Text("未完成")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Button {
                                editingProfile = profile
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("编辑模型")
                            .accessibilityLabel("编辑 \(profile.name)")
                            Menu {
                                Button("设为当前模型") { activateProfile(profile) }
                                    .disabled(profile.id == activeProfileID)
                                Button("删除模型", role: .destructive) { pendingProfileDelete = profile }
                                    .disabled(profiles.count < 2)
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                        }
                        .contentShape(Rectangle())
                    }
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("已保存的模型配置")
                    Spacer()
                    Button {
                        editingProfile = ModelProfile(name: "新模型", baseURL: "https://api.openai.com/v1")
                    } label: {
                        Label("新增模型", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Section {
                Text("模型名称、API 地址、模型名和 API Key 保存在当前用户的本机 SQLite 数据库中。可先保存配置，稍后补齐模型名和 API Key；未完成的配置不能用于对话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("API Key 不会包含在应用安装包中。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("刷新列表") { reloadProfiles() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 数据

    private var dataTab: some View {
        Form {
            Section("存储位置") {
                LabeledContent("数据目录") {
                    HStack(spacing: 8) {
                        Text(Self.dataDirectory)
                            .textSelection(.enabled)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("在访达中显示") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Self.dataDirectory)
                        }
                    }
                }
                Picker("历史保留时长", selection: $preferences.historyRetentionDays) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("365 天").tag(365)
                    Text("永久保留").tag(0)
                }
                Text("对话与命令历史按所选时长清理，最多保留最近 300 条；SSH 密码和 API Key 不在此策略内。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("清除数据") {
                Button("清除所有命令执行历史", role: .destructive) { pendingClear = 0 }
                Button("清除所有 AI 对话", role: .destructive) { pendingClear = 1 }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    private func persist() {
        do {
            try preferences.save()
            ConversationArchive.pruneExpired()
            ExecutionHistoryStore.pruneExpired()
            error = nil
        } catch {
            self.error = "设置保存失败：\(error.localizedDescription)"
        }
    }

    private func commitWorkingDirectory() {
        let expanded = (workingDirectoryDraft as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = "默认工作区必须是已存在的文件夹。"
            workingDirectoryDraft = preferences.workingDirectory
            return
        }
        error = nil
        preferences.workingDirectory = expanded
        workingDirectoryDraft = expanded
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: (preferences.workingDirectory as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workingDirectoryDraft = url.path
        commitWorkingDirectory()
    }

    private func reloadProfiles() {
        do {
            let store = ModelProfileStore.live
            let all = try store.loadAll()
            profiles = all
            activeProfileID = store.active(from: all).id
            error = nil
        } catch {
            profiles = []
            activeProfileID = nil
            self.error = "读取模型配置失败：\(error.localizedDescription)"
        }
    }

    private func saveProfile(_ profile: ModelProfile, makeActive: Bool) -> String? {
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) {
            updated[index] = profile
        } else {
            updated.append(profile)
        }
        let selectedID = makeActive ? profile.id : (activeProfileID ?? updated[0].id)
        do {
            try ModelProfileStore.live.saveAll(updated, activeID: selectedID)
            profiles = updated
            activeProfileID = selectedID
            status = "模型配置已保存。"
            error = nil
            return nil
        } catch {
            let message = "模型配置保存失败：\(error.localizedDescription)"
            self.error = message
            return message
        }
    }

    private func activateProfile(_ profile: ModelProfile) {
        do {
            try ModelProfileStore.live.saveAll(profiles, activeID: profile.id)
            activeProfileID = profile.id
            status = "已切换当前模型。"
            error = nil
        } catch {
            self.error = "切换模型失败：\(error.localizedDescription)"
        }
    }

    private func deletePendingProfile() {
        guard let profile = pendingProfileDelete, profiles.count > 1 else { return }
        let updated = profiles.filter { $0.id != profile.id }
        let selectedID = activeProfileID == profile.id ? updated[0].id : (activeProfileID ?? updated[0].id)
        do {
            try ModelProfileStore.live.saveAll(updated, activeID: selectedID)
            profiles = updated
            activeProfileID = selectedID
            status = "模型配置已删除。"
            error = nil
        } catch {
            self.error = "删除模型配置失败：\(error.localizedDescription)"
        }
        pendingProfileDelete = nil
    }
}

private struct ModelProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ModelProfile
    @State private var contextCapacityText: String
    @State private var error: String?
    let onSave: (ModelProfile) -> String?

    init(profile: ModelProfile, onSave: @escaping (ModelProfile) -> String?) {
        _profile = State(initialValue: profile)
        _contextCapacityText = State(initialValue: ModelContextCapacity.display(profile.contextWindow))
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("模型配置")
                .font(.title3.weight(.semibold))
            Form {
                TextField("配置名称", text: $profile.name, prompt: Text("例如 DeepSeek"))
                TextField("API 地址", text: $profile.baseURL, prompt: Text("https://api.example.com/v1"))
                TextField("模型名", text: $profile.model, prompt: Text("例如 deepseek-chat"))
                TextField("上下文容量", text: $contextCapacityText, prompt: Text("例如 1m、256k；留空表示未知"))
                    .accessibilityLabel("模型上下文容量")
                SecureField("API Key", text: $profile.apiKey, prompt: Text("稍后也可以填写"))
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500, height: 370)
    }

    private func save() {
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.baseURL = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty else { error = "请填写配置名称。"; return }
        guard let components = URLComponents(string: profile.baseURL),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              !(components.host ?? "").isEmpty else {
            error = "请输入有效的 HTTP 或 HTTPS API 地址。"
            return
        }
        do {
            profile.contextWindow = try ModelContextCapacity.parse(contextCapacityText)
        } catch {
            self.error = error.localizedDescription
            return
        }
        if let saveError = onSave(profile) {
            error = saveError
        } else {
            dismiss()
        }
    }
}
