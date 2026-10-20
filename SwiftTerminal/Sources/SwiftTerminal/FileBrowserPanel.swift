import AppKit
import SwiftUI

struct RemoteFileEntry: Identifiable, Sendable {
    let name: String
    let isDirectory: Bool
    let id: String
    let size: Int64?
}

enum FileVisibilityPolicy {
    static func isVisible(name: String, showHiddenFiles: Bool) -> Bool {
        guard name != ".", name != ".." else { return false }
        return showHiddenFiles || !name.hasPrefix(".")
    }
}

struct FileBrowserPanel: View {
    let host: SSHHost?
    let showHiddenFiles: Bool
    var onQuote: ((AIQuote) -> Void)?
    let smbProfile: SMBMountProfile?
    @State private var smbCoordinator = SMBMountCoordinator.shared

    private var smbContext: SMBFileContext? {
        guard let profile = smbProfile, let volume = smbCoordinator.volume(for: profile) else { return nil }
        return SMBMountService.fileContext(profile: profile, volume: volume)
    }

    private var fileTargetKey: String { smbProfile.map { "smb-" + $0.id.uuidString } ?? host?.id.uuidString ?? "local" }
    private var writeAllowed: Bool { smbProfile == nil || (smbContext != nil && smbContext?.volume.readOnly == false) }

    private func accessContext() throws -> SMBFileContext? {
        if smbProfile != nil, smbContext == nil { throw SMBMountFailure(message: "此共享尚未挂载，请先挂载再访问文件。") }
        return smbContext
    }


    @State private var path: String
    @State private var pathDraft: String
    @State private var entries: [RemoteFileEntry] = []
    @State private var listingID = UUID()
    @State private var previewID = UUID()
    @State private var listingTask: Task<Void, Never>?
    @State private var previewTask: Task<Void, Never>?
    @State private var selected: RemoteFileEntry?
    @State private var preview = ""
    @State private var busy = false
    @State private var status: String?
    @State private var error: String?
    @State private var editor: EditorTarget?
    @State private var nameEntry: NameEntry?
    @State private var pendingDelete: RemoteFileEntry?
    @State private var compactLayout = false
    @State private var sessionPassword: String?
    @State private var showPasswordPrompt = false
    @State private var passwordDraft = ""
    @State private var passwordMessage: String?

    init(host: SSHHost?, showHiddenFiles: Bool = false, smbProfile: SMBMountProfile? = nil, onQuote: ((AIQuote) -> Void)? = nil) {
        self.host = host
        self.smbProfile = smbProfile
        self.showHiddenFiles = showHiddenFiles
        self.onQuote = onQuote
        let context = smbProfile.flatMap { profile in SMBMountCoordinator.shared.volume(for: profile).map { SMBMountService.fileContext(profile: profile, volume: $0) } }
        let initial = context?.initialPath ?? (smbProfile == nil ? (host == nil ? FileManager.default.homeDirectoryForCurrentUser.path : "~") : "")
        let key = smbProfile.map { "smb-" + $0.id.uuidString } ?? host?.id.uuidString ?? "local"
        let remembered = UserDefaults.standard.string(forKey: "file-browser-path-" + key)
        let rememberedStart = remembered.flatMap { saved in context == nil && smbProfile != nil ? nil : (context.map { SMBPathPolicy.contains(saved, in: $0.root) } ?? true ? saved : nil) }
        let start = rememberedStart ?? initial
        _path = State(initialValue: start)
        _pathDraft = State(initialValue: start)
    }

    private var targetName: String { smbProfile?.name ?? host?.displayName ?? "本机" }
    private var visibleEntries: [RemoteFileEntry] {
        entries.filter { FileVisibilityPolicy.isVisible(name: $0.name, showHiddenFiles: showHiddenFiles) }
    }
    private var canEditSelected: Bool { onQuote != nil && selected != nil && !preview.isEmpty }
    private var needsSessionPassword: Bool {
        guard let host else { return false }
        return host.authentication == .password && host.password.isEmpty && sessionPassword == nil
    }

    /// SFTP runs outside the interactive terminal, so a saved password is
    /// injected here. A password entered for this window stays in memory only.
    private var effectiveHost: SSHHost? {
        guard let host else { return nil }
        guard let sessionPassword else { return host }
        var copy = host
        copy.password = sessionPassword
        copy.savePassword = false
        return copy
    }

    var body: some View {
        GeometryReader { geometry in
            // The preview column only fits next to the list when the panel is
            // wide enough; below that a compact single column is used so the
            // sidebar and AI panel never get squeezed out.
            let isCompact = geometry.size.width < 560
            VStack(alignment: .leading, spacing: 12) {
                header
                if let profile = smbProfile, smbContext == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("此共享尚未挂载").font(.headline)
                        Text("挂载后会加载这个共享的文件夹，不会访问其他连接。")
                        if let failure = smbCoordinator.failures[profile.id] { Text(failure.message).foregroundStyle(.orange) }
                        Button(smbCoordinator.busy.contains(profile.id) ? "等待系统操作…" : "挂载共享") {
                            Task { do { _ = try await smbCoordinator.mount(profile) } catch { self.error = error.localizedDescription } }
                        }.disabled(smbCoordinator.busy.contains(profile.id))
                    }.padding(12)
                }
                if needsSessionPassword {
                    passwordPrompt
                }
                TextField("路径", text: $pathDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit {
                        navigate(to: pathDraft)
                    }
                if pathDraft != path {
                    Text("按回车打开输入的路径；下方仍是 \(path) 的内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if busy { ProgressView("正在处理…").controlSize(.small) }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if let status {
                    Label(status, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if isCompact {
                    fileList
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        fileList
                        Divider()
                        previewPane
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(16)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .onAppear { compactLayout = isCompact }
            .onChange(of: isCompact) { _, newValue in compactLayout = newValue }
            .overlay {
                if visibleEntries.isEmpty && !busy && error == nil && (smbProfile == nil || smbContext != nil) {
                    ContentUnavailableView("目录为空", systemImage: "folder")
                }
            }
        }
        .onAppear {
            if needsSessionPassword {
                showPasswordPrompt = true
            } else {
                refresh()
            }
        }
        .onDisappear {
            if !path.isEmpty { UserDefaults.standard.set(path, forKey: "file-browser-path-" + fileTargetKey) }
            listingTask?.cancel()
            previewTask?.cancel()
        }
        .onChange(of: smbContext) { old, new in
            listingID = UUID(); previewID = UUID()
            listingTask?.cancel(); previewTask?.cancel(); entries = []; selected = nil; preview = ""; busy = false
            if let new {
                if !SMBPathPolicy.contains(path, in: new.root) { path = new.initialPath; pathDraft = path }
                refresh()
            }
        }
        .onChange(of: showHiddenFiles) { _, value in
            if let selected, !FileVisibilityPolicy.isVisible(name: selected.name, showHiddenFiles: value) {
                self.selected = nil
                preview = ""
                previewID = UUID()
                previewTask?.cancel()
            }
        }
        .sheet(isPresented: $showPasswordPrompt) {
            passwordSheet
        }
        .sheet(item: $editor) { target in
            FileEditorSheet(
                target: target,
                onSave: { text in try await save(target: target, text: text) },
                onQuote: onQuote == nil ? nil : { text in quote(text: text, path: target.path) }
            )
            .onAppear { if let context = smbContext { smbCoordinator.beginEditing(token: target.id, context: context) } }
            .onDisappear { smbCoordinator.endEditing(token: target.id) }
        }
        .sheet(item: $nameEntry) { entry in
            NameEntrySheet(
                title: entry.isNewFolder ? "新建文件夹" : "重命名",
                message: entry.message(target: targetName, directory: path),
                initialName: entry.initialName
            ) { name in
                submit(entry, name: name)
            }
        }
        .confirmationDialog("删除这个项目？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let entry = pendingDelete { remove(entry) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            if let entry = pendingDelete {
                Text("目标：\(targetName)\n\(entryPath(entry))\(entry.isDirectory ? "\n目录必须为空才能删除。" : "")")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            PanelTitle(
                title: "文件",
                subtitle: smbProfile.map { "SMB · \($0.name)" } ?? host.map { "SSH · \($0.displayName)" } ?? "本机",
                symbol: "folder"
            )
            Spacer()
                if smbContext != nil {
                    Button("根目录") { if let root = smbContext?.root { navigate(to: root) } }
                }
                Button { goUp() } label: { Image(systemName: "arrow.up") }
                    .help("返回上一级目录")
                Button {
                    showPasswordPrompt = true
                } label: {
                    Image(systemName: "key")
                }
                .help("输入此窗口使用的 SSH 密码")
                .disabled(host?.authentication != .password)
                Button { nameEntry = .newFolder } label: { Image(systemName: "folder.badge.plus") }
                .help("在当前目录新建文件夹")
                .disabled(pathDraft != path || busy || !writeAllowed)
            Button { upload() } label: { Image(systemName: "square.and.arrow.up") }
                .help("把本机文件复制到当前目录")
                .disabled(pathDraft != path || busy || !writeAllowed)
            if let context = smbContext {
                Button {
                    guard SMBVolume.all().contains(context.volume) else { smbCoordinator.refresh(); return }
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: { Image(systemName: "arrow.up.forward.app") }
                .help("在访达中打开当前文件夹")
            }
            Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("重新读取目录")
                .disabled(busy)
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    private var passwordPrompt: some View {
        HStack(spacing: 10) {
            Label("此主机未保存密码，浏览和传输文件前需要输入一次 SSH 密码。", systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("输入密码") { showPasswordPrompt = true }
                .controlSize(.small)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("需要 SSH 密码", systemImage: "lock")
                .font(.headline)
            Text("\(targetName) 没有保存密码。文件浏览使用独立的 SFTP 连接，请输入一次密码；密码只在当前窗口运行期间保留，不会写入磁盘。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("SSH 密码", text: $passwordDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitPassword() }
            if let passwordMessage {
                Text(passwordMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") {
                    showPasswordPrompt = false
                    passwordDraft = ""
                    passwordMessage = nil
                }
                Button("使用此密码") { submitPassword() }
                    .buttonStyle(.borderedProminent)
                    .disabled(passwordDraft.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    private var fileList: some View {
        List(visibleEntries) { entry in
            HStack(spacing: 8) {
                Button { activate(entry) } label: {
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc.text")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                if let size = entry.size, !entry.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Menu {
                    if !entry.isDirectory { Button("编辑文本") { beginEdit(entry) } }
                    Button("下载…") { download(entry) }
                    Button("重命名…") { nameEntry = .rename(entry) }.disabled(!writeAllowed)
                    Divider()
                    Button("删除", role: .destructive) { pendingDelete = entry }.disabled(!writeAllowed)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .disabled(busy)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
        .frame(minWidth: 190, idealWidth: 280, maxWidth: 420)
        .disabled(pathDraft != path)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selected {
                HStack(spacing: 6) {
                    Text(selected.name).font(.headline).lineLimit(1)
                    Spacer()
                    if !selected.isDirectory {
                        Button { beginEdit(selected) } label: { Label("编辑", systemImage: "square.and.pencil") }
                            .disabled(busy)
                        if canEditSelected {
                            Button { quotePreview() } label: { Label("引用到 AI", systemImage: "text.quote") }
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text(childPath(selected.name)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                ScrollView {
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "选择文件",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("文件内容会在这里预览；文本文件可以直接编辑并保存。")
                )
            }
        }
        .padding(12)
        .disabled(pathDraft != path)
        .frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private enum NameEntry: Identifiable {
        case newFolder
        case rename(RemoteFileEntry)

        var id: String {
            switch self {
            case .newFolder: return "new-folder"
            case .rename(let entry): return "rename-\(entry.id)"
            }
        }

        var isNewFolder: Bool {
            if case .newFolder = self { return true }
            return false
        }

        var initialName: String {
            switch self {
            case .newFolder: return ""
            case .rename(let entry): return entry.name
            }
        }

        func message(target: String, directory: String) -> String {
            switch self {
            case .newFolder:
                return "会在 \(target) 的 \(directory) 中创建文件夹。"
            case .rename(let entry):
                return "会重命名 \(target) 上的 \(entry.name)。"
            }
        }
    }

    private func activate(_ entry: RemoteFileEntry) {
        if entry.isDirectory {
            navigate(to: entryPath(entry))
        } else if compactLayout {
            // 窄窗口没有预览列，点击文件直接打开内容。
            beginEdit(entry)
        } else {
            loadPreview(entry)
        }
    }

    private func quote(text: String, path: String) {
        guard let onQuote else { return }
        onQuote(AIQuote(kind: "文件", source: "\(targetName) · \(path)", text: text))
        status = "已引用到 AI 对话，发送前可以查看引用内容。"
    }

    private func refresh() {
        guard !needsSessionPassword else {
            listingTask?.cancel()
            entries = []
            selected = nil
            preview = ""
            busy = false
            error = nil
            return
        }
        if smbProfile != nil, smbContext == nil { entries = []; busy = false; return }
        let requestedPath = path
        let requestID = UUID()
        listingID = requestID
        listingTask?.cancel()
        busy = true
        error = nil
        listingTask = Task {
            do {
                let result: [RemoteFileEntry]
                if let effectiveHost {
                    result = try await SFTPService.list(host: effectiveHost, path: requestedPath)
                } else {
                    let context = try accessContext()
                    result = try await Task.detached {
                        let lease = try context?.lease(requestedPath)
                        defer { lease?.close() }
                        let result = try Self.localEntries(at: requestedPath)
                        try context?.validate(requestedPath)
                        return result
                    }.value
                }
                guard !Task.isCancelled, listingID == requestID, path == requestedPath else { return }
                entries = result
                if let selected, !result.contains(where: { $0.name == selected.name }) {
                    self.selected = nil
                    preview = ""
                }
            } catch {
                guard !Task.isCancelled, listingID == requestID, path == requestedPath else { return }
                handle(error)
                entries = []
            }
            busy = false
            listingTask = nil
        }
    }

    private func navigate(to destination: String) {
        if let context = smbContext, !SMBPathPolicy.contains(destination, in: context.root) {
            error = "路径不属于当前共享，请返回共享根目录。"; return
        }
        path = destination
        pathDraft = destination
        entries = []
        selected = nil
        preview = ""
        previewID = UUID()
        previewTask?.cancel()
        refresh()
    }

    nonisolated private static func localEntries(at requestedPath: String) throws -> [RemoteFileEntry] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: requestedPath),
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        )
        return try urls.map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return RemoteFileEntry(
                name: url.lastPathComponent,
                isDirectory: values.isDirectory ?? false,
                id: url.path,
                size: values.fileSize.map(Int64.init)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func loadPreview(_ entry: RemoteFileEntry) {
        if let size = entry.size, size > 1_000_000 {
            error = "文件超过 1 MB，预览已停止以避免读取过大的文件。"
            return
        }
        let target = entryPath(entry)
        let requestID = UUID()
        previewID = requestID
        previewTask?.cancel()
        busy = true
        error = nil
        previewTask = Task {
            do {
                let text = try await readText(at: target)
                guard !Task.isCancelled, previewID == requestID else { return }
                preview = text
                selected = entry
            } catch {
                guard !Task.isCancelled, previewID == requestID else { return }
                self.error = error.localizedDescription
                preview = ""
                selected = nil
            }
            busy = false
            previewTask = nil
        }
    }

    private func readText(at target: String) async throws -> String {
        if let effectiveHost {
            return try await SFTPService.read(host: effectiveHost, path: target)
        }
        let context = try accessContext()
        return try await Task.detached {
            let lease = try context?.lease(target)
            defer { lease?.close() }
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: target))
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_000_001) ?? Data()
            guard data.count <= 1_000_000 else { throw FileOperationError.unsupported("文件超过 1 MB，请在访达中打开。") }
            guard FileTextHeuristics.isProbablyText(data) else { throw FileOperationError.unsupported("这不是可编辑的文本文件，请在访达中打开。") }
            try context?.validate(target)
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    private func beginEdit(_ entry: RemoteFileEntry) {
        if let size = entry.size, size > 1_000_000 {
            error = "文件超过 1 MB，编辑已停止以避免覆盖过大的文件。"
            return
        }
        let target = entryPath(entry)
        let requestID = UUID()
        previewID = requestID
        previewTask?.cancel()
        busy = true
        error = nil
        previewTask = Task {
            do {
                let text = try await readText(at: target)
                guard !Task.isCancelled, previewID == requestID else { return }
                editor = EditorTarget(name: entry.name, path: target, text: text)
            } catch {
                guard !Task.isCancelled, previewID == requestID else { return }
                handle(error)
            }
            busy = false
            previewTask = nil
        }
    }

    private func save(target: EditorTarget, text: String) async throws {
        busy = true
        defer { busy = false }
        try await WorkspaceFileService.writeText(text, host: effectiveHost, path: target.path, smb: try accessContext())
        status = "已保存 \(target.path)"
        refresh()
    }

    private func submit(_ entry: NameEntry, name: String) {
        busy = true
        error = nil
        Task {
            do {
                switch entry {
                case .newFolder:
                    let target = childPath(name)
                    try await WorkspaceFileService.createDirectory(host: effectiveHost, path: target, smb: try accessContext())
                    status = "已创建 \(target)"
                case .rename(let item):
                    let from = entryPath(item)
                    let to = try await WorkspaceFileService.rename(host: effectiveHost, path: from, to: name, smb: try accessContext())
                    status = "已重命名为 \((to as NSString).lastPathComponent)"
                    if selected?.name == item.name { selected = nil; preview = "" }
                }
                nameEntry = nil
                refresh()
            } catch {
                handle(error)
            }
            busy = false
        }
    }

    private func remove(_ entry: RemoteFileEntry) {
        busy = true
        error = nil
        let target = entryPath(entry)
        Task {
            do {
                try await WorkspaceFileService.remove(host: effectiveHost, path: target, isDirectory: entry.isDirectory, smb: try accessContext())
                status = "已删除 \(entry.name)"
                if selected?.name == entry.name { selected = nil; preview = "" }
                refresh()
            } catch {
                handle(error)
            }
            busy = false
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        panel.message = host == nil ? "选择要复制到 \(path) 的文件" : "选择要上传到 \(targetName) 的文件"
        guard panel.runModal() == .OK else { return }
        let sources = panel.urls.map(\.path)
        guard !sources.isEmpty else { return }
        let directory = path
        busy = true
        error = nil
        Task {
            do {
                let saved = try await WorkspaceFileService.upload(host: effectiveHost, localPaths: sources, directory: directory, smb: try accessContext())
                status = "已复制 \(saved.count) 个文件到 \(directory)：\n" + saved.joined(separator: "\n")
                refresh()
            } catch {
                handle(error)
            }
            busy = false
        }
    }

    private func download(_ entry: RemoteFileEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        panel.message = "选择保存 \(entry.name) 的位置"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let source = entryPath(entry)
        busy = true
        error = nil
        Task {
            do {
                let saved = try await WorkspaceFileService.download(host: effectiveHost, path: source, to: destination.path, smb: try accessContext())
                status = "已保存到 \(saved)"
            } catch {
                handle(error)
            }
            busy = false
        }
    }

    private func quotePreview() {
        guard let selected, !preview.isEmpty else { return }
        quote(text: preview, path: entryPath(selected))
    }

    private func submitPassword() {
        guard !passwordDraft.isEmpty else { return }
        sessionPassword = passwordDraft
        passwordDraft = ""
        passwordMessage = nil
        showPasswordPrompt = false
        error = nil
        refresh()
    }

    /// A transient SFTP connection can reject a password that the interactive
    /// terminal never needed to save. Ask in place instead of showing raw
    /// OpenSSH diagnostics.
    private func handle(_ error: Error) {
        let message = error.localizedDescription
        let needsPassword = message.localizedCaseInsensitiveContains("permission denied")
            || message.localizedCaseInsensitiveContains("password")
            || message.localizedCaseInsensitiveContains("authentication")
        if needsPassword, host?.authentication == .password {
            sessionPassword = nil
            passwordDraft = ""
            passwordMessage = "认证没有通过。请重新输入密码；NAS 还需要允许 SFTP 访问。"
            showPasswordPrompt = true
            self.error = nil
        } else {
            self.error = message
        }
    }

    private func entryPath(_ entry: RemoteFileEntry) -> String {
        entry.id
    }

    private func childPath(_ name: String) -> String {
        if host != nil { return SFTPService.joined(path, name) }
        return (path as NSString).appendingPathComponent(name)
    }

    private func goUp() {
        if let context = smbContext, path == context.root { return }
        if host != nil {
            if path == "~" || path == "/" || path.isEmpty { return }
            if path.hasPrefix("~/"), !path.dropFirst(2).contains("/") { navigate(to: "~"); return }
        }
        if path == "/" || path.isEmpty { return }
        navigate(to: (path as NSString).deletingLastPathComponent)
    }
}

private struct EditorTarget: Identifiable {
    let id = UUID()
    var name: String
    var path: String
    var text: String
}

private struct FileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let target: EditorTarget
    let onSave: (String) async throws -> Void
    let onQuote: ((String) -> Void)?
    @State private var text: String
    @State private var saveError: String?
    @State private var saving = false
    @State private var confirmDiscard = false

    init(target: EditorTarget, onSave: @escaping (String) async throws -> Void, onQuote: ((String) -> Void)? = nil) {
        self.target = target
        self.onSave = onSave
        self.onQuote = onQuote
        _text = State(initialValue: target.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.name).font(.title3.weight(.semibold))
            Text(target.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 340)
            if let saveError { Text(saveError).foregroundStyle(.orange).textSelection(.enabled) }
            Text("保存会直接写回该文件；没有版本历史，请确认内容后再保存。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if let onQuote {
                    Button {
                        onQuote(text)
                    } label: {
                        Label("引用到 AI", systemImage: "text.quote")
                    }
                    .help("把文件中当前的内容作为引用交给 AI")
                }
                Spacer()
                Button("另存到本机") {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = target.name
                    if panel.runModal() == .OK, let url = panel.url {
                        do { try text.write(to: url, atomically: true, encoding: .utf8); saveError = "已另存到本机。" }
                        catch { saveError = error.localizedDescription }
                    }
                }
                Button("取消") { if text != target.text { confirmDiscard = true } else { dismiss() } }.disabled(saving)
                Button(saving ? "保存中…" : "保存") {
                    saving = true
                    Task {
                        do { try await onSave(text); dismiss() }
                        catch { saveError = "保存失败，编辑内容已保留：\(error.localizedDescription)" }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 660, height: 600)
        .interactiveDismissDisabled(text != target.text || saving)
        .confirmationDialog("放弃未保存的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) { }
        }
    }
}

private struct NameEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let message: String
    let onSubmit: (String) -> Void
    @State private var name: String
    @State private var validation: String?

    init(title: String, message: String, initialName: String = "", onSubmit: @escaping (String) -> Void) {
        self.title = title
        self.message = message
        self.onSubmit = onSubmit
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            if let validation { Text(validation).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("确定") {
                    do {
                        let value = try FileNamePolicy.validate(name)
                        onSubmit(value)
                        dismiss()
                    } catch {
                        validation = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
