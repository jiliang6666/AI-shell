import AppKit
import SwiftUI

struct SavedCommandsPanel: View {
    @Binding var data: WorkspaceData
    let hosts: [SSHHost]
    let currentHost: SSHHost?
    @State private var draft: SavedCommand?
    @State private var runRequest: CommandRunRequest?
    @State private var pendingDelete: SavedCommand?
    @State private var output: String?
    @State private var busy = false
    @State private var error: String?
    @State private var search = ""

    private var filteredCommands: [SavedCommand] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return data.savedCommands }
        return data.savedCommands.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
                || $0.command.localizedCaseInsensitiveContains(query)
                || targetName(for: $0).localizedCaseInsensitiveContains(query)
        }
    }

    private func commandRow(_ item: SavedCommand) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body.weight(.medium))
                    StateBadge(text: targetName(for: item), color: item.hostID == nil ? .green : .blue)
                }
                if !item.description.isEmpty {
                    Text(item.description).font(.caption).foregroundStyle(.secondary)
                }
                Text(item.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                runRequest = CommandRunRequest(command: item)
            } label: {
                Label("运行", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Menu {
                Button("编辑…") { draft = item }
                Divider()
                Button("删除", role: .destructive) { pendingDelete = item }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                PanelTitle(title: "常用命令", subtitle: "保存可复用的命令，在确认后运行", symbol: "text.badge.plus")
                Spacer()
                Button {
                    draft = SavedCommand(name: "", description: "", command: "", hostID: currentHost?.id, workingDirectory: "~")
                } label: {
                    Label("新建", systemImage: "plus")
                }
                .controlSize(.small)
            }
            PanelSearchField(prompt: "搜索命令、说明或目标主机", text: $search)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            List(filteredCommands) { item in
                commandRow(item)
            }
            .listStyle(.inset)
            .overlay {
                if filteredCommands.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "还没有常用命令" : "没有匹配的命令",
                        systemImage: "text.badge.plus",
                        description: Text(search.isEmpty ? "保存常用命令后可以在这里一键运行。" : "换个关键词试试。")
                    )
                }
            }
            if let output {
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(16)
        .sheet(item: $draft) { item in
            SavedCommandEditor(command: item, hosts: hosts) { save($0) }
        }
        .sheet(item: $runRequest) { request in
            SavedCommandRunSheet(command: request.command, targetName: targetName(for: request.command)) { expandedCommand in
                runRequest = nil
                run(request.command, expandedCommand: expandedCommand)
            }
        }
        .confirmationDialog("删除此常用命令？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let pendingDelete { remove(pendingDelete) }; pendingDelete = nil }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
    }

    private func targetName(for command: SavedCommand) -> String {
        guard let id = command.hostID else { return "本机" }
        return hosts.first(where: { $0.id == id })?.displayName ?? "已删除的主机"
    }

    private func save(_ command: SavedCommand) {
        var updated = data
        if let index = updated.savedCommands.firstIndex(where: { $0.id == command.id }) { updated.savedCommands[index] = command }
        else { updated.savedCommands.append(command) }
        do { try WorkspaceDataStore.save(updated); data = updated; draft = nil }
        catch { self.error = "保存失败：\(error.localizedDescription)" }
    }

    private func remove(_ command: SavedCommand) {
        var updated = data
        updated.savedCommands.removeAll { $0.id == command.id }
        do { try WorkspaceDataStore.save(updated); data = updated }
        catch { self.error = "删除失败：\(error.localizedDescription)" }
    }

    private func run(_ command: SavedCommand, expandedCommand: String) {
        guard !busy else { return }
        let target = command.hostID.flatMap { id in hosts.first(where: { $0.id == id }) }
        guard command.hostID == nil || target != nil else { error = "保存的目标主机已删除，请编辑此命令。"; return }
        busy = true
        error = nil
        Task {
            let result = await LocalShellCommandRunner.run(expandedCommand, host: target, workingDirectory: command.workingDirectory)
            output = "\(target?.displayName ?? "本机") · 退出码 \(result.exitCode)\n\n\(result.output)"
            busy = false
        }
    }
}

private struct CommandRunRequest: Identifiable {
    var id = UUID()
    let command: SavedCommand
}

private struct SavedCommandEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var command: SavedCommand
    let hosts: [SSHHost]
    let onSave: (SavedCommand) -> Void
    @State private var validation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("常用命令").font(.title2)
            Form {
                TextField("名称", text: $command.name)
                TextField("说明", text: $command.description)
                TextEditor(text: $command.command).frame(minHeight: 100)
                Picker("执行目标", selection: $command.hostID) {
                    Text("本机").tag(UUID?.none)
                    ForEach(hosts) { host in Text(host.displayName).tag(Optional(host.id)) }
                }
                TextField("工作目录", text: $command.workingDirectory)
                Text("使用 {{参数名}} 插入参数，运行时输入的值会按 Shell 字符串引用。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach($command.parameters) { $parameter in
                    HStack {
                        TextField("参数名", text: $parameter.name)
                        TextField("提示", text: $parameter.prompt)
                        TextField("默认值", text: $parameter.defaultValue)
                        Button(role: .destructive) { command.parameters.removeAll { $0.id == parameter.id } } label: { Image(systemName: "minus.circle") }
                    }
                }
                Button("添加参数") { command.parameters.append(CommandParameter(name: "", prompt: "", defaultValue: "")) }
            }
            if let validation { Text(validation).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    switch CommandTemplateResolver.resolve(template: command.command, parameters: command.parameters, values: [:]) {
                    case .success: command.updatedAt = Date(); onSave(command)
                    case .failure(let error): validation = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(command.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 600, height: 520)
    }
}

private struct SavedCommandRunSheet: View {
    @Environment(\.dismiss) private var dismiss
    let command: SavedCommand
    let targetName: String
    let onRun: (String) -> Void
    @State private var values: [UUID: String] = [:]

    private var resolved: Result<String, Error> {
        CommandTemplateResolver.resolve(template: command.command, parameters: command.parameters, values: values)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("运行 \(command.name)").font(.title2)
            Text("目标：\(targetName) · 目录：\(command.workingDirectory)")
            ForEach(command.parameters) { parameter in
                TextField(parameter.prompt.isEmpty ? parameter.name : parameter.prompt, text: Binding(get: { values[parameter.id] ?? parameter.defaultValue }, set: { values[parameter.id] = $0 }))
            }
            switch resolved {
            case .success(let text):
                ScrollView { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("取消") { dismiss() }; Button("运行") { onRun(text); dismiss() }.buttonStyle(.borderedProminent) }
            case .failure(let error):
                Text(error.localizedDescription).foregroundStyle(.red)
                Button("取消") { dismiss() }
            }
        }.padding(20).frame(width: 540, height: 400)
    }
}

struct ExecutionHistoryPanel: View {
    @State private var records = ExecutionHistoryStore.load()
    @State private var filter = ""
    @State private var pendingRun: ExecutionRecord?
    @State private var rerunStatus: String?
    @State private var rerunBusy = false

    private var filteredRecords: [ExecutionRecord] {
        guard !filter.isEmpty else { return records }
        return records.filter { $0.targetName.localizedCaseInsensitiveContains(filter) || $0.command.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PanelTitle(title: "历史", subtitle: "命令执行记录", symbol: "clock.arrow.circlepath")
                Spacer()
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.help("刷新")
            }
            PanelSearchField(prompt: "搜索命令或目标主机", text: $filter)
            if let rerunStatus { Text(rerunStatus).font(.caption).textSelection(.enabled) }
            List(filteredRecords) { record in recordRow(record) }
                .listStyle(.inset)
                .overlay { if records.isEmpty { ContentUnavailableView("还没有执行记录", systemImage: "clock.arrow.circlepath") } }
        }
        .padding(16)
        .onAppear { refresh() }
        .confirmationDialog("再次运行这条命令？", isPresented: Binding(get: { pendingRun != nil }, set: { if !$0 { pendingRun = nil } }), titleVisibility: .visible) {
            Button("运行命令") { runPending() }
            Button("取消", role: .cancel) { pendingRun = nil }
        } message: {
            if let pendingRun { Text("目标：\(pendingRun.targetName)\n\(pendingRun.command)") }
        }
    }

    private func recordRow(_ record: ExecutionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(record.targetName).font(.body.weight(.medium))
                StateBadge(
                    text: record.exitCode == 0 ? "成功" : "退出码 \(record.exitCode)",
                    color: record.exitCode == 0 ? .green : .orange
                )
                Spacer()
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(record.command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button {
                    pendingRun = record
                } label: {
                    Label("再次运行", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(rerunBusy)
            }
            DisclosureGroup("查看输出") {
                ScrollView {
                    Text(record.output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(.vertical, 5)
    }

    private func refresh() {
        records = ExecutionHistoryStore.load()
    }

    private func runPending() {
        guard let record = pendingRun else { return }
        pendingRun = nil
        let hosts = SSHHostStore.load()
        guard record.hostID == nil || hosts.contains(where: { $0.id == record.hostID }) else {
            rerunStatus = "原 SSH 主机已删除；请重新保存主机后再运行。"
            return
        }
        let host = record.hostID.flatMap { id in hosts.first(where: { $0.id == id }) }
        rerunBusy = true
        rerunStatus = "正在运行…"
        Task {
            let result = await LocalShellCommandRunner.run(
                record.command,
                host: host,
                workingDirectory: record.workingDirectory
            )
            rerunStatus = "\(host?.displayName ?? "本机") · 退出码 \(result.exitCode)\n\(result.output)"
            rerunBusy = false
            refresh()
        }
    }
}

struct SMBMountsPanel: View {
    @Binding var data: WorkspaceData
    var selectedID: UUID? = nil
    @State private var coordinator = SMBMountCoordinator.shared
    @State private var draft: SMBMountProfile?
    @State private var pendingUnmount: SMBMountProfile?
    @State private var pendingDelete: SMBMountProfile?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PanelTitle(title: "SMB 连接", subtitle: "共享挂载与连接资料", symbol: "externaldrive")
                Spacer()
                Button("添加共享") { draft = .init(name: "", server: "", share: "", username: "", password: "", mountPath: "") }
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(data.smbMounts.filter { selectedID == nil || $0.id == selectedID }) { profile in
                        detail(profile)
                    }
                    if data.smbMounts.isEmpty {
                        ContentUnavailableView("还没有 SMB 共享", systemImage: "externaldrive", description: Text("添加共享后可以挂载并浏览文件。"))
                    }
                }
            }
        }
        .padding(16)
        .onAppear { coordinator.refresh() }
        .sheet(item: $draft) { profile in SMBProfileEditor(profile: profile) { save($0) } }
        .confirmationDialog("卸载此 SMB 共享？", isPresented: Binding(get: { pendingUnmount != nil }, set: { if !$0 { pendingUnmount = nil } }), titleVisibility: .visible) {
            Button("卸载", role: .destructive) {
                if let profile = pendingUnmount { Task { do { try await coordinator.unmount(profile) } catch { self.error = error.localizedDescription } } }
                pendingUnmount = nil
            }
            Button("取消", role: .cancel) { pendingUnmount = nil }
        } message: { Text("所有使用此卷的窗口和访达都会受影响。请先关闭共享中的文件；不会强制卸载。") }
        .confirmationDialog("删除连接资料？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除资料并保留挂载", role: .destructive) {
                if let profile = pendingDelete {
                    guard !coordinator.busy.contains(profile.id), !coordinator.hasOpenEditor(profile) else { error = "请先等待操作完成并关闭此共享的文件编辑器，再删除连接资料。"; return }
                    var updated = data
                    updated.smbMounts.removeAll { $0.id == profile.id }
                    do { try WorkspaceDataStore.save(updated); data = updated; NotificationCenter.default.post(name: .workspaceDataChanged, object: nil) }
                    catch { self.error = error.localizedDescription }
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { Text("只删除应用中的资料。不会删除共享文件，也不会自动卸载系统卷。") }
    }

    @ViewBuilder private func detail(_ profile: SMBMountProfile) -> some View {
        let volume = coordinator.volume(for: profile)
        let busy = coordinator.busy.contains(profile.id)
        let hasFailure = coordinator.failures[profile.id] != nil
        let connectionActionLabel = hasFailure ? "重试连接" : "挂载共享"
        let connectionActionSymbol = hasFailure ? "arrow.clockwise.circle" : "arrow.down.to.line"
        let statusColor: Color = busy ? .blue : (volume != nil ? .green : (coordinator.failures[profile.id] != nil ? .orange : .secondary))
        let localAddress = volume?.path ?? (profile.mountMode == .custom ? profile.mountPath : "挂载后由 macOS 分配")
        let remoteAddress = (try? SMBMountService.url(for: profile))?.absoluteString ?? "服务器地址无效"

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                        .font(.headline)
                    Text(profile.mountMode == .system ? "系统管理挂载位置" : "自定义挂载位置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                StateBadge(text: coordinator.label(for: profile), color: statusColor)
            }

            HStack(alignment: .center, spacing: 12) {
                addressNode(title: "本机地址", value: localAddress, symbol: "externaldrive")

                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                addressNode(title: "远程地址", value: remoteAddress, symbol: "network")
            }
            .padding(14)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.045), lineWidth: 1)
            }

            if let failure = coordinator.failures[profile.id] {
                VStack(alignment: .leading, spacing: 9) {
                    Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)

                    if failure.recovery == .systemMount {
                        Button("使用系统挂载") { var edited = profile; edited.mountMode = .system; save(edited) }
                            .controlSize(.small)
                    }
                    if failure.recovery == .networkSettings {
                        Button("打开系统设置") { LocalNetworkAccess.openSettings() }
                            .controlSize(.small)
                    }
                    if failure.recovery == .directory || failure.recovery == .systemMount {
                        HStack(spacing: 8) {
                            Button("选择文件夹") { chooseDirectory(for: profile) }
                                .controlSize(.small)
                            if let path = failure.path {
                                Button("在访达中查看") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }

            HStack(spacing: 9) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(coordinator.isUnmounting(profile) ? "正在卸载共享…" : "正在连接共享…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !coordinator.isUnmounting(profile) {
                        Button("取消") { coordinator.cancel(profile) }
                            .controlSize(.small)
                    }
                } else if let volume {
                    Button {
                        guard SMBVolume.all().contains(volume) else { coordinator.refresh(); return }
                        NSWorkspace.shared.open(URL(fileURLWithPath: volume.path))
                    } label: {
                        Label("在访达中打开", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("卸载") { pendingUnmount = profile }
                        .buttonStyle(.bordered)
                }

                Spacer(minLength: 8)

                if volume == nil && !busy {
                    Button {
                        Task { do { _ = try await coordinator.mount(profile) } catch { self.error = nil } }
                    } label: {
                        Image(systemName: connectionActionSymbol)
                    }
                    .buttonStyle(.borderless)
                    .help(connectionActionLabel)
                    .accessibilityLabel(connectionActionLabel)
                }

                Button {
                    coordinator.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新挂载状态")
                .accessibilityLabel("刷新挂载状态")
                .disabled(busy)

                Menu {
                    Button { draft = profile } label: {
                        Label("编辑连接资料", systemImage: "pencil")
                    }
                    .disabled(busy || volume != nil)
                    .help(volume == nil ? "编辑连接资料" : "请先卸载，再修改连接身份")

                    Button(role: .destructive) { pendingDelete = profile } label: {
                        Label("删除连接资料", systemImage: "trash")
                    }
                    .disabled(busy)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("更多连接选项")
                .accessibilityLabel("更多连接选项")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.055), lineWidth: 1)
        }
    }

    private func addressNode(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(value.isEmpty ? "未设置" : value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save(_ profile: SMBMountProfile) {
        let original = data.smbMounts.first { $0.id == profile.id } ?? profile
        guard !coordinator.busy.contains(profile.id), !coordinator.hasOpenEditor(original), coordinator.volume(for: original) == nil else { error = "请先等待操作完成、关闭文件编辑器并卸载共享，再修改连接资料。"; return }
        var updated = data
        if let index = updated.smbMounts.firstIndex(where: { $0.id == profile.id }) { updated.smbMounts[index] = profile }
        else { updated.smbMounts.append(profile) }
        do { try WorkspaceDataStore.save(updated); data = updated; draft = nil; coordinator.refresh(); NotificationCenter.default.post(name: .workspaceDataChanged, object: nil) }
        catch { self.error = "保存失败：\(error.localizedDescription)" }
    }

    private func chooseDirectory(for profile: SMBMountProfile) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.message = "选择可读写的空文件夹；也可以先在访达中创建后再选择。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var edited = profile; edited.mountMode = .custom; edited.mountPath = url.path
        save(edited)
    }
}

struct SMBProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: SMBMountProfile
    @State private var validation: String?
    @State private var showsPassword = false
    let onSave: (SMBMountProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SMB 共享").font(.title2)
            Form {
                TextField("名称", text: $profile.name)
                TextField("服务器地址", text: $profile.server)
                TextField("共享名称", text: $profile.share)
                TextField("初始子目录（可选）", text: $profile.initialSubdirectory)
                TextField("用户名（可含域）", text: $profile.username)
                LabeledContent("密码") {
                    Group {
                        if showsPassword {
                            TextField("", text: $profile.password)
                        } else {
                            SecureField("", text: $profile.password)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        Button {
                            showsPassword.toggle()
                        } label: {
                            Image(systemName: showsPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 7)
                        .help(showsPassword ? "隐藏密码" : "显示密码")
                        .accessibilityLabel(showsPassword ? "隐藏密码" : "显示密码")
                    }
                }
                Picker("挂载位置", selection: $profile.mountMode) {
                    Text("系统管理").tag(SMBMountMode.system)
                    Text("自定义空文件夹").tag(SMBMountMode.custom)
                }
                if profile.mountMode == .custom {
                    HStack {
                        TextField("最终挂载文件夹", text: $profile.mountPath)
                        Button("选择…") {
                            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { profile.mountPath = url.path }
                        }
                    }
                    Text("请选择可读写的空文件夹。若应用不能创建，可先在访达中创建，再重试。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("macOS 自动管理挂载目录，无需提前在 /Volumes 创建文件夹。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("密码仅保存在本机受限权限文件，不拼入命令或发送给 AI。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let validation { Text(validation).foregroundStyle(.orange).textSelection(.enabled) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存") { save() }.buttonStyle(.borderedProminent) }
        }.padding(20).frame(width: 560, height: 560)
    }

    private func save() {
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.server = profile.server.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.share = profile.share.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        profile.username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard !profile.name.isEmpty else { throw SMBMountFailure(message: "请填写连接名称。") }
            _ = try SMBMountService.url(for: profile)
            if profile.mountMode == .custom { profile.mountPath = try SMBPathPolicy.customMountPath(profile.mountPath) }
            profile.updatedAt = Date()
            onSave(profile)
        } catch { validation = error.localizedDescription }
    }
}
