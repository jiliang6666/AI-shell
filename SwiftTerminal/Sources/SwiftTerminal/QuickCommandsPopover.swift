import SwiftUI

struct QuickCommandsMenu: View {
    let targetName: String?
    let isRunning: Bool
    let onRun: (String) -> String?
    @State private var commands: [QuickCommand] = []
    @State private var draft: QuickCommand?
    @State private var showManager = false
    @State private var error: String?
    @State private var loadFailed = false

    var body: some View {
        Menu {
            if loadFailed {
                Text("快捷命令读取失败")
                Button("重新加载", action: reload)
            } else if commands.isEmpty {
                Text("还没有保存的快捷命令")
            } else {
                ForEach(commands) { command in
                    Button(command.name) { error = onRun(command.command) }
                        .help(command.command)
                        .disabled(targetName == nil || isRunning)
                }
            }
            Divider()
            Button("新增快捷命令…") { draft = QuickCommand(name: "", command: "") }
                .disabled(loadFailed)
            Button("管理快捷命令…") { showManager = true }
        } label: {
            Label("快捷命令", systemImage: "bolt.horizontal.circle")
                .font(.system(size: 12, weight: .medium))
                .frame(height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .help("保存快捷命令并在当前终端执行")
        .accessibilityLabel("快捷命令")
        .accessibilityIdentifier("quickCommands.toggle")
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .quickCommandsChanged)) { _ in reload() }
        .sheet(item: $draft) { command in
            QuickCommandEditor(command: command) { saved in
                do {
                    var latest = try QuickCommandStore.live.load()
                    latest.append(saved)
                    try QuickCommandStore.live.save(latest)
                    NotificationCenter.default.post(name: .quickCommandsChanged, object: nil)
                    draft = nil
                    return nil
                } catch {
                    return "保存快捷命令失败：\(error.localizedDescription)"
                }
            }
        }
        .popover(isPresented: $showManager, arrowEdge: .bottom) {
            QuickCommandsPopover(targetName: targetName, isRunning: isRunning) { command in
                let issue = onRun(command)
                if issue == nil { showManager = false }
                return issue
            }
        }
        .alert("快捷命令未执行", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("好", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func reload() {
        do {
            commands = try QuickCommandStore.live.load()
            loadFailed = false
        } catch {
            commands = []
            loadFailed = true
        }
    }
}

struct QuickCommandsPopover: View {
    let targetName: String?
    let isRunning: Bool
    let onRun: (String) -> String?
    @State private var commands: [QuickCommand] = []
    @State private var search = ""
    @State private var draft: QuickCommand?
    @State private var pendingDelete: QuickCommand?
    @State private var error: String?
    @State private var loaded = false

    private var filteredCommands: [QuickCommand] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? commands : commands.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.command.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("快捷命令", systemImage: "bolt.horizontal.circle")
                    .font(.headline)
                Spacer()
                Button {
                    draft = QuickCommand(name: "", command: "")
                } label: {
                    Label("新增", systemImage: "plus")
                }
                .disabled(!loaded)
                .accessibilityIdentifier("quickCommands.add")
            }
            Text(targetName.map { "在当前终端“\($0)”中执行，使用终端当前目录。" } ?? "选择终端后即可执行快捷命令。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isRunning {
                Label("当前终端的快捷命令正在运行", systemImage: "terminal")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextField("搜索名称或命令", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索快捷命令")
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if !loaded { Button("重新加载", action: reload) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredCommands) { command in
                        commandRow(command)
                        Divider()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 280)
            .overlay {
                if loaded, filteredCommands.isEmpty {
                    ContentUnavailableView(
                        commands.isEmpty ? "还没有快捷命令" : "没有匹配的命令",
                        systemImage: "terminal",
                        description: Text(commands.isEmpty ? "点击“新增”保存常用命令。" : "试试其他关键词。")
                    )
                }
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .quickCommandsChanged)) { _ in reload() }
        .sheet(item: $draft) { command in
            QuickCommandEditor(command: command) { saved in
                let issue = update { commands in
                    if let index = commands.firstIndex(where: { $0.id == saved.id }) {
                        commands[index] = saved
                    } else {
                        commands.append(saved)
                    }
                }
                if issue == nil { draft = nil }
                return issue
            }
        }
        .confirmationDialog("删除此快捷命令？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let command = pendingDelete {
                    error = update { $0.removeAll { $0.id == command.id } }
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.name ?? "")
        }
    }

    private func commandRow(_ command: QuickCommand) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(command.name).font(.body.weight(.medium)).lineLimit(2)
                Text(command.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                error = onRun(command.command)
            } label: {
                Label("执行", systemImage: "play.fill")
            }
            .disabled(targetName == nil || isRunning || !loaded)
            .help("在当前终端执行“\(command.name)”")
            .accessibilityLabel("执行快捷命令：\(command.name)")
            Menu {
                Button("编辑…") { draft = command }
                Button("删除…", role: .destructive) { pendingDelete = command }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .disabled(!loaded)
            .accessibilityLabel("管理快捷命令：\(command.name)")
        }
        .padding(.vertical, 12)
    }

    private func reload() {
        do {
            commands = try QuickCommandStore.live.load()
            loaded = true
            error = nil
        } catch {
            loaded = false
            self.error = "读取快捷命令失败：\(error.localizedDescription)"
        }
    }

    /// Read the latest file before each edit so other windows' saved commands survive.
    private func update(_ mutation: (inout [QuickCommand]) -> Void) -> String? {
        do {
            var latest = try QuickCommandStore.live.load()
            mutation(&latest)
            try QuickCommandStore.live.save(latest)
            commands = latest
            error = nil
            NotificationCenter.default.post(name: .quickCommandsChanged, object: nil)
            return nil
        } catch {
            return "保存快捷命令失败：\(error.localizedDescription)"
        }
    }
}

private struct QuickCommandEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var command: QuickCommand
    let onSave: (QuickCommand) -> String?
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var isValid: Bool {
        !command.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("保存快捷命令").font(.title2.weight(.semibold))
            Form {
                TextField("名称", text: $command.name)
                    .focused($nameFocused)
                    .accessibilityIdentifier("quickCommands.name")
                LabeledContent("命令") {
                    TextEditor(text: $command.command)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 180)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                        .accessibilityLabel("命令内容")
                        .accessibilityIdentifier("quickCommands.command")
                }
            }
            Text("支持多行命令。点击执行后，命令会直接在当前选中的终端运行。")
                .font(.callout).foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    var saved = command
                    saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    error = onSave(saved)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isValid)
                .accessibilityIdentifier("quickCommands.save")
            }
        }
        .padding(24)
        .frame(width: 560, height: 460)
        .onAppear { nameFocused = true }
    }
}
