import AppKit
import SwiftUI

struct TerminalSession: Identifiable {
    let id: UUID
    let host: SSHHost?
    let startingDirectory: String?
    init(id: UUID = UUID(), host: SSHHost?, startingDirectory: String? = nil) {
        self.id = id
        self.host = host
        self.startingDirectory = startingDirectory
    }
    var title: String { host?.displayName ?? "本机" }
}

enum WorkspacePage: String, CaseIterable, Identifiable {
    case terminal, files, commands, smb, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return "终端"
        case .files: return "文件"
        case .commands: return "命令"
        case .smb: return "连接"
        case .history: return "历史"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .files: return "folder"
        case .commands: return "text.badge.plus"
        case .smb: return "externaldrive.connected.to.line.below"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

private enum SidebarItem: Hashable {
    case page(WorkspacePage)
    case session(UUID)
    case host(UUID)
    case smb(UUID)
}

private struct SSHHostSidebarEntry: Identifiable {
    let host: SSHHost
    let session: TerminalSession?

    var id: UUID { host.id }
}

/// Sidebar and tab rules kept separate from SwiftUI so they can be verified
/// without opening a window: local terminals and SSH hosts are distinct
/// groups, and one SSH host never creates duplicate live sessions.
enum TerminalSessionPolicy {
    static func localSessions(_ sessions: [TerminalSession]) -> [TerminalSession] {
        Array(sessions.filter { $0.host == nil }.reversed())
    }

    static func existingSession(for host: SSHHost, in sessions: [TerminalSession]) -> TerminalSession? {
        sessions.first { $0.host?.id == host.id }
    }
}

/// Selection rules for the workspace's terminal-first startup behavior.
enum WorkspaceSelectionPolicy {
    static var startupPage: WorkspacePage { .terminal }

    static func restoredSelectedSessionID(
        _ sessions: [TerminalSession],
        selectedID: UUID?
    ) -> UUID? {
        if let selectedID, sessions.contains(where: { $0.id == selectedID }) {
            return selectedID
        }
        return sessions.first?.id
    }
}

enum WorkspaceWindowGeometry {
    static let sidebarWidth: CGFloat = 225
    static let assistantWidth: CGFloat = 345
    static let minimumTerminalWidth: CGFloat = 660

    static func panelWidth(sidebar: Bool, assistant: Bool) -> CGFloat {
        (sidebar ? sidebarWidth : 0) + (assistant ? assistantWidth : 0)
    }

    static func minimumWidth(sidebar: Bool, assistant: Bool) -> CGFloat {
        minimumTerminalWidth + panelWidth(sidebar: sidebar, assistant: assistant)
    }

    static func resizedFrame(
        from oldFrame: CGRect,
        currentSidebar: Bool,
        currentAssistant: Bool,
        sidebar: Bool,
        assistant: Bool,
        anchorToRight: Bool
    ) -> CGRect {
        let currentPanels = panelWidth(sidebar: currentSidebar, assistant: currentAssistant)
        let nextPanels = panelWidth(sidebar: sidebar, assistant: assistant)
        var frame = oldFrame
        frame.size.width = max(minimumTerminalWidth, oldFrame.width - currentPanels) + nextPanels
        if anchorToRight { frame.origin.x = oldFrame.maxX - frame.width }
        return frame
    }
}

@MainActor
private final class AssistantModelRegistry {
    static let shared = AssistantModelRegistry()
    private var models: [UUID: TerminalAIModel] = [:]

    func model(for session: TerminalSession, workingDirectory: String) -> TerminalAIModel {
        if let model = models[session.id] {
            model.updateWorkingDirectory(workingDirectory)
            return model
        }
        let model = TerminalAIModel(target: session.host, workingDirectory: workingDirectory, terminalSessionID: session.id)
        models[session.id] = model
        return model
    }

    func reloadProfiles() {
        for model in models.values { model.reloadProfilesFromStore() }
    }

    func deleteHistory(for terminalID: UUID) async throws {
        await models[terminalID]?.prepareForTerminalDeletion()
        try await AISessionCoordinator.shared.deleteTerminalHistory(terminalID: terminalID)
        try ExecutionHistoryStore.deleteHistory(terminalSessionID: terminalID)
        models.removeValue(forKey: terminalID)
    }
}

private struct WorkspacePageNavigation: View {
    @Binding var selection: WorkspacePage
    let width: CGFloat
    let pages: [WorkspacePage]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.84)
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(pages) { item in
                let isSelected = selection == item
                Button {
                    withAnimation(selectionAnimation) {
                        selection = item
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    }
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color(red: 0.10, green: 0.42, blue: 0.95).opacity(0.88))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .padding(4)
        .frame(width: width)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .animation(selectionAnimation, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("工作区导航")
    }
}

struct TerminalWorkspace: View {
    @Environment(\.openWindow) private var openWindow
    @State private var sessions: [TerminalSession]
    @State private var selectedSessionID: UUID?
    @State private var hosts = SSHHostStore.load()
    @State private var preferences = AppPreferences.load()
    @State private var workspaceData = WorkspaceDataStore.load()
    @State private var page = WorkspaceSelectionPolicy.startupPage
    @State private var sidebarSelection: SidebarItem? = .page(.terminal)
    @State private var smbCoordinator = SMBMountCoordinator.shared
    @State private var smbDraft: SMBMountProfile?
    @State private var pendingSMBDelete: SMBMountProfile?
    @State private var workspaceWindowNumber: Int?
    @State private var hoveredSessionID: UUID?
    @State private var splitSessionID: UUID?
    @State private var splitFraction: CGFloat = 0.5
    @State private var splitDragStart: CGFloat?
    @State private var showSidebar = true
    @State private var showAssistant = true
    @State private var showHostEditor = false
    @State private var hostDraft = SSHHost(name: "", address: "", username: "")
    @State private var isNewHost = true
    @State private var pendingDelete: SSHHost?
    @State private var errorMessage: String?
    @State private var pendingQuote: AIQuote?
    @State private var terminalViews = TerminalViewRegistry()
    @State private var exitedSessionIDs: Set<UUID> = []
    @State private var sshConnectionStates: [UUID: SSHConnectionState] = [:]
    @State private var sessionRestartTokens: [UUID: Int] = [:]
    @State private var assistantModels = AssistantModelRegistry.shared
    @State private var closingSessionIDs = Set<UUID>()

    init() {
        let restored = TerminalSessionStore.load(hosts: SSHHostStore.load())
        _sessions = State(initialValue: restored.sessions)
        _selectedSessionID = State(initialValue: WorkspaceSelectionPolicy.restoredSelectedSessionID(
            restored.sessions,
            selectedID: restored.selectedID
        ))
    }

    private var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID } ?? sessions.first
    }

    private var panelBackground: Color { Color(nsColor: .controlBackgroundColor) }

    private let workspaceNavigationWidth: CGFloat = 300

    private var colorScheme: ColorScheme? {
        switch preferences.appearance {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    private var selectedSMB: SMBMountProfile? {
        guard case .smb(let id) = sidebarSelection else { return nil }
        return workspaceData.smbMounts.first { $0.id == id }
    }

    private var isSMBTarget: Bool {
        if case .smb = sidebarSelection { return true }
        return sidebarSelection == .page(.smb)
    }

    private var navigationTitleText: String {
        if isSMBTarget { return selectedSMB.map { "栈桥 — SMB · \($0.name)" } ?? "栈桥 — SMB" }
        return selectedSession.map { "Swift Terminal — \($0.title)" } ?? "Swift Terminal"
    }

    private var profileAwareLayout: some View {
        splitLayout
            .onReceive(NotificationCenter.default.publisher(for: .modelProfilesChanged)) { _ in
                AssistantModelRegistry.shared.reloadProfiles()
            }
    }

    var body: some View {
        folderOpenRouting
            .focusedSceneValue(\.terminalActionsAvailable, !isSMBTarget && page == .terminal)
            .background(WorkspaceWindowReader { workspaceWindowNumber = $0.windowNumber })
    }

    private var folderOpenRouting: some View {
        workspaceSheets
            .onReceive(NotificationCenter.default.publisher(for: .openTerminalAtDirectory), perform: openFolderInNewTerminal)
    }

    private var ownsKeyWindow: Bool { workspaceWindowNumber != nil && workspaceWindowNumber == NSApp.keyWindow?.windowNumber }

    private var workspaceEvents: some View {
        profileAwareLayout
            .frame(minWidth: 1, minHeight: 560)
            .background(Color(nsColor: .windowBackgroundColor))
            .tint(.blue)
            .preferredColorScheme(colorScheme)
            .navigationTitle(navigationTitleText)
            .toolbar { toolbarContent }
            .onAppear(perform: workspaceAppeared)
            .onDisappear(perform: FinderFolderOpenRouter.unregister)
            .onChange(of: sessions.map(\.id)) { _, ids in
                let activeIDs = Set(ids)
                exitedSessionIDs.formIntersection(activeIDs)
                sshConnectionStates = sshConnectionStates.filter { activeIDs.contains($0.key) }
                sessionRestartTokens = sessionRestartTokens.filter { activeIDs.contains($0.key) }
                persistSessions()
            }
            .onChange(of: selectedSessionID) { _, newValue in selectedSessionChanged(to: newValue) }
            .onChange(of: page) { _, newValue in pageChanged(to: newValue) }
            .onChange(of: sidebarSelection) { _, newValue in sidebarSelectionChanged(to: newValue) }
            .onReceive(NotificationCenter.default.publisher(for: .newTerminalTab)) { _ in if ownsKeyWindow { addSession(host: nil) } }
            .onReceive(NotificationCenter.default.publisher(for: .closeTerminalTab)) { _ in
                guard ownsKeyWindow else { return }
                if isSMBTarget { NSApp.keyWindow?.performClose(nil) }
                else if let selectedSession { closeSession(selectedSession) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clearTerminal)) { _ in
                guard ownsKeyWindow else { return }
                if !isSMBTarget, page == .terminal, let id = selectedSession?.id { terminalViews.clear(id: id) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .workspaceDataChanged)) { _ in
                workspaceData = WorkspaceDataStore.load()
                if case .smb(let id) = sidebarSelection, !workspaceData.smbMounts.contains(where: { $0.id == id }) {
                    sidebarSelection = .page(.smb); page = .smb
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .preferencesChanged)) { _ in
                preferences = AppPreferences.load()
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalHistoryDeleted)) { notification in
                guard let id = notification.object as? UUID,
                      let session = sessions.first(where: { $0.id == id }) else { return }
                removeClosedSession(session)
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
                guard ownsKeyWindow else { return }
                setSidebarVisible(!showSidebar)
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleAssistant)) { _ in
                guard ownsKeyWindow else { return }
                setAssistantVisible(!showAssistant)
            }
    }

    private var workspaceSheets: some View {
        workspaceEvents
            .sheet(item: $smbDraft) { profile in
                SMBProfileEditor(profile: profile, onSave: saveSMBProfile)
            }
            .confirmationDialog("删除 SMB 连接资料？", isPresented: Binding(get: { pendingSMBDelete != nil }, set: { if !$0 { pendingSMBDelete = nil } }), titleVisibility: .visible) {
                Button("删除资料并保留挂载", role: .destructive) {
                    if let profile = pendingSMBDelete {
                        guard !smbCoordinator.busy.contains(profile.id), !smbCoordinator.hasOpenEditor(profile) else { errorMessage = "请先等待操作完成并关闭此共享的文件编辑器，再删除连接资料。"; return }
                        var updated = WorkspaceDataStore.load()
                        updated.smbMounts.removeAll { $0.id == profile.id }
                        do { try WorkspaceDataStore.save(updated); workspaceData = updated; NotificationCenter.default.post(name: .workspaceDataChanged, object: nil) }
                        catch { errorMessage = error.localizedDescription }
                    }
                    pendingSMBDelete = nil
                }
                Button("取消", role: .cancel) { pendingSMBDelete = nil }
            } message: { Text("只删除应用中的连接资料，不删除共享文件，也不卸载系统卷。") }
            .sheet(isPresented: $showHostEditor) {
                SSHHostEditor(
                    host: hostDraft,
                    knownGroups: SSHHostGrouping.knownGroups(hosts),
                    isNewHost: isNewHost,
                    onSave: saveHost
                )
            }
            .alert("删除 SSH 主机？", isPresented: deleteAlertBinding) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("删除", role: .destructive) {
                    if let host = pendingDelete { deleteHost(host) }
                    pendingDelete = nil
                }
            } message: {
                Text("\(pendingDelete?.displayName ?? "此主机")的连接资料将从本机移除。已打开的终端标签和执行历史不会自动删除。")
            }
            .alert("提示", isPresented: messageAlertBinding) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func saveSMBProfile(_ saved: SMBMountProfile) {
        let original = workspaceData.smbMounts.first { $0.id == saved.id } ?? saved
        guard !smbCoordinator.busy.contains(saved.id), !smbCoordinator.hasOpenEditor(original), smbCoordinator.volume(for: original) == nil else { errorMessage = "请等待操作完成并卸载共享后，再修改连接资料。"; return }
        var updated = WorkspaceDataStore.load()
        if let index = updated.smbMounts.firstIndex(where: { $0.id == saved.id }) { updated.smbMounts[index] = saved }
        else { updated.smbMounts.append(saved) }
        do {
            try WorkspaceDataStore.save(updated); workspaceData = updated; smbDraft = nil
            selectSMB(saved)
            NotificationCenter.default.post(name: .workspaceDataChanged, object: nil)
        } catch { errorMessage = error.localizedDescription }
    }

    private var splitLayout: some View {
        HStack(spacing: 0) {
            if showSidebar {
                sidebar
                    .frame(width: 224)
                Divider().frame(width: 1)
            }
            mainContent
            if showAssistant { Divider().frame(width: 1) }
            assistantPanel
                .frame(width: showAssistant ? 344 : 0, alignment: .leading)
                .clipped()
                .allowsHitTesting(showAssistant)
                .accessibilityHidden(!showAssistant)
        }
    }

    private func setSidebarVisible(_ isVisible: Bool) {
        guard showSidebar != isVisible else { return }
        resizeWindow(
            sidebarVisible: isVisible,
            assistantVisible: showAssistant,
            anchorToRight: true
        )
        showSidebar = isVisible
    }

    private func setAssistantVisible(_ isVisible: Bool) {
        guard showAssistant != isVisible else { return }
        resizeWindow(
            sidebarVisible: showSidebar,
            assistantVisible: isVisible,
            anchorToRight: false
        )
        showAssistant = isVisible
    }

    private func resizeWindow(sidebarVisible: Bool, assistantVisible: Bool, anchorToRight: Bool) {
        let windows = NSApp.windows
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? windows.first(where: \.isVisible) else { return }
        let newFrame = WorkspaceWindowGeometry.resizedFrame(
            from: window.frame,
            currentSidebar: showSidebar,
            currentAssistant: showAssistant,
            sidebar: sidebarVisible,
            assistant: assistantVisible,
            anchorToRight: anchorToRight
        )
        window.minSize.width = WorkspaceWindowGeometry.minimumWidth(
            sidebar: sidebarVisible, assistant: assistantVisible
        )
        window.setFrame(newFrame, display: true, animate: false)
    }

    private func ensureInitialWindowWidth() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        let minimumWindowWidth = WorkspaceWindowGeometry.minimumWidth(
            sidebar: showSidebar, assistant: showAssistant
        )
        window.minSize.width = minimumWindowWidth
        guard window.frame.width < minimumWindowWidth else { return }

        var frame = window.frame
        let widthIncrease = minimumWindowWidth - frame.width
        frame.origin.x -= widthIncrease / 2
        frame.size.width = minimumWindowWidth
        window.setFrame(frame, display: true, animate: false)
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var messageAlertBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func openFolderInNewTerminal(_ notification: Notification) {
        guard let path = notification.object as? String else { return }
        // A Finder folder request is still a terminal task: open the shell in
        // that directory and leave the user in the terminal by default.
        addSession(host: nil, workingDirectory: path)
    }

    private var fileBrowserIdentity: String {
        selectedSession?.id.uuidString ?? "local"
    }

    private func workspaceAppeared() {
        // Retain the application action, not this view and its terminal state.
        let action = openWindow
        WorkspaceWindowCoordinator.shared.configureOpenWindow {
            action(id: WorkspaceWindowCoordinator.sceneID)
        }
        FinderFolderOpenRouter.register { path in
            NotificationCenter.default.post(name: .openTerminalAtDirectory, object: path)
        }
        restoreSelection()
        if let issue = WorkspaceDataStore.loadFailureMessage { errorMessage = issue }
        DispatchQueue.main.async(execute: ensureInitialWindowWidth)
    }

    private func restoreSelection() {
        // The page is terminal-first; selection policy only fills a valid tab.
        selectedSessionID = WorkspaceSelectionPolicy.restoredSelectedSessionID(
            sessions,
            selectedID: selectedSessionID
        )
        if case .session(let id) = sidebarSelection, !sessions.contains(where: { $0.id == id }) {
            sidebarSelection = .page(.terminal)
        }
        if case .host(let id) = sidebarSelection, !hosts.contains(where: { $0.id == id }) {
            sidebarSelection = .page(.terminal)
        }
        if let id = selectedSessionID { sidebarSelection = .session(id) }
    }

    private func selectedSessionChanged(to newValue: UUID?) {
        persistSessions()
        guard !isSMBTarget, let newValue else { return }
        if sidebarSelection != .session(newValue) { sidebarSelection = .session(newValue) }

    }

    private func pageChanged(to newValue: WorkspacePage) {
        if newValue != .terminal, ownsKeyWindow { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    private func selectSMB(_ profile: SMBMountProfile) {
        smbCoordinator.refresh()
        if ownsKeyWindow { NSApp.keyWindow?.makeFirstResponder(nil) }
        sidebarSelection = .smb(profile.id)
        page = .smb
    }

    private func sidebarSelectionChanged(to newValue: SidebarItem?) {
        switch newValue {
        case .page(let destination):
            page = destination
        case .session(let id):
            sidebarSelection = .session(id)
            guard sessions.contains(where: { $0.id == id }) else { return }
            selectedSessionID = id
            page = .terminal
        case .host(let id):
            guard let host = hosts.first(where: { $0.id == id }) else { return }
            openHost(host)
        case .smb(let id):
            guard workspaceData.smbMounts.contains(where: { $0.id == id }) else { return }
            page = .smb
        case nil:
            break
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                setSidebarVisible(!showSidebar)
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .help(showSidebar ? "隐藏侧边栏" : "显示侧边栏")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            HStack(spacing: 14) {
                Menu {
                    Button("新建本机终端") { addSession(host: nil) }
                    Button("添加 SSH 主机…") { beginAddHost() }
                    Button("添加 SMB 共享…") { smbDraft = .init(name: "", server: "", share: "", username: "", password: "", mountPath: "") }
                    if !hosts.isEmpty {
                        Divider()
                        ForEach(hosts) { host in
                            Button("连接到 \(host.displayName)") { openHost(host) }
                        }
                    }
                    if !isSMBTarget, page == .terminal, sessions.count > 1 || splitSessionID != nil {
                        Divider()
                        ForEach(sessions.filter { $0.id != selectedSessionID }) { session in
                            Button("与“\(session.title)”分屏") { splitSessionID = session.id }
                        }
                        if splitSessionID != nil {
                            Button("关闭分屏") { splitSessionID = nil }
                        }
                    }
                    Divider()
                    Button("引用所选文字") { quoteSelection() }
                        .disabled(isSMBTarget || page != .terminal)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("新建终端、连接主机、分屏或引用选中文字")

                Button {
                    setAssistantVisible(!showAssistant)
                } label: {
                    Label("AI", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .frame(height: 22)
                        .contentShape(Rectangle())
                }
                .help(showAssistant ? "隐藏 AI 助手" : "显示 AI 助手")

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .help("设置")
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                localTerminalSection
                sshHostSection
                smbSection
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var localTerminalSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sidebarHeader("本机", systemImage: "laptopcomputer")
            let localSessions = TerminalSessionPolicy.localSessions(sessions)
            if localSessions.isEmpty {
                Button {
                    addSession(host: nil)
                } label: {
                    Label("新建本机终端", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            } else {
                ForEach(localSessions) { session in
                    sessionRow(session)
                }
            }
        }
    }

    @ViewBuilder
    private var smbSection: some View {
        let mounts = workspaceData.smbMounts
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                sidebarHeader("SMB", systemImage: "externaldrive")
                Spacer()
                Button { smbDraft = .init(name: "", server: "", share: "", username: "", password: "", mountPath: "") }
                label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("添加 SMB 共享").padding(.trailing, 12)
            }
            if mounts.isEmpty {
                Button("添加 SMB 共享") { smbDraft = .init(name: "", server: "", share: "", username: "", password: "", mountPath: "") }
                    .buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 6)
            } else {
                SSHHostListView(
                    rows: mounts.map { mount in
                        SSHHostRowModel(id: mount.id, name: mount.name,
                                        endpoint: "\(smbCoordinator.label(for: mount)) · \(mount.server) / \(mount.share)",
                                        isConnected: false, isSelected: sidebarSelection == .smb(mount.id), isSMB: true)
                    },
                    onActivate: { id in if let profile = mounts.first(where: { $0.id == id }) { selectSMB(profile) } },
                    onEdit: { id in
                        if let profile = mounts.first(where: { $0.id == id }), !smbCoordinator.busy.contains(id), smbCoordinator.volume(for: profile) == nil { smbDraft = profile }
                        else { errorMessage = "请等待操作完成并卸载共享后，再编辑连接资料。" }
                    },
                    onDelete: { id in
                        if let profile = mounts.first(where: { $0.id == id }), !smbCoordinator.busy.contains(id) { pendingSMBDelete = profile }
                    }
                )
                .frame(height: CGFloat(mounts.count) * SSHHostListView.rowHeight)
            }
        }.padding(.top, 6)
    }

    @ViewBuilder
    private var sshHostSection: some View {
        let entries = sshSidebarEntries
        VStack(alignment: .leading, spacing: 2) {
            sidebarHeader("SSH", systemImage: "server.rack")

            if entries.isEmpty {
                Button {
                    beginAddHost()
                } label: {
                    Label("添加 SSH 主机", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            } else {
                SSHHostListView(
                    rows: entries.map { entry in
                        SSHHostRowModel(
                            id: entry.host.id,
                            name: entry.host.displayName,
                            endpoint: entry.host.endpoint,
                            isConnected: entry.session.map { sshConnectionStates[$0.id] == .connected } ?? false,
                            isSelected: entry.session.map { sidebarSelection == .session($0.id) } ?? false,
                            connectionLabel: entry.session.map { sshConnectionStates[$0.id, default: .connecting].label }
                        )
                    },
                    onActivate: { id in
                        guard let host = hosts.first(where: { $0.id == id }) else { return }
                        openHost(host)
                    },
                    onEdit: { id in
                        guard let host = hosts.first(where: { $0.id == id }) else { return }
                        beginEditHost(host)
                    },
                    onDelete: { id in
                        guard let host = hosts.first(where: { $0.id == id }) else { return }
                        pendingDelete = host
                    }
                )
                .frame(height: CGFloat(entries.count) * SSHHostListView.rowHeight)
            }
        }
        .padding(.top, 6)
    }

    private func sidebarHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private var sshSidebarEntries: [SSHHostSidebarEntry] {
        var entries = hosts.map { host in
            SSHHostSidebarEntry(host: host, session: TerminalSessionPolicy.existingSession(for: host, in: sessions))
        }
        for session in sessions {
            guard let host = session.host, !hosts.contains(where: { $0.id == host.id }) else { continue }
            entries.append(SSHHostSidebarEntry(host: host, session: session))
        }
        return entries.sorted {
            $0.host.displayName.localizedStandardCompare($1.host.displayName) == .orderedAscending
        }
    }

    private func sessionRow(_ session: TerminalSession) -> some View {
        let tag = SidebarItem.session(session.id)
        let isSelected = sidebarSelection == .session(session.id)
        return HStack(spacing: 8) {
            Circle()
                .fill(session.host == nil ? Color.green : Color.blue)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(session.host == nil ? "本机 Shell" : "SSH 会话")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer(minLength: 0)
            if sessions.count > 1, hoveredSessionID == session.id || selectedSessionID == session.id {
                Button {
                    closeSession(session)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭标签")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { sidebarSelectionChanged(to: tag) }
        .onHover { hovering in hoveredSessionID = hovering ? session.id : (hoveredSessionID == session.id ? nil : hoveredSessionID) }
        .contextMenu {
            Button("删除终端及聊天记录", role: .destructive) { closeSession(session) }
        }
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                WorkspacePageNavigation(selection: $page, width: isSMBTarget ? 240 : workspaceNavigationWidth, pages: isSMBTarget ? [.smb, .files] : [.terminal, .files, .history])
                    .help(isSMBTarget ? "在共享文件与连接资料之间切换" : "在终端、文件与历史之间切换")
                Spacer(minLength: 0)
            }
            .frame(height: 48)
            .background(.bar)
            Divider()

            ZStack {
                VStack(spacing: 0) {
                    terminalTabs
                }
                .opacity(page == .terminal ? 1 : 0)
                .allowsHitTesting(page == .terminal)
                .accessibilityHidden(page != .terminal)

                switch page {
                case .terminal:
                    EmptyView()
                case .files:
                    if let profile = selectedSMB {
                        FileBrowserPanel(host: nil, showHiddenFiles: preferences.showHiddenFiles, smbProfile: profile)
                            .id("smb-" + profile.id.uuidString).background(panelBackground)
                    } else if isSMBTarget {
                        ContentUnavailableView("请选择或添加 SMB 共享", systemImage: "externaldrive")
                    } else {
                        FileBrowserPanel(
                            host: selectedSession?.host,
                            showHiddenFiles: preferences.showHiddenFiles
                        ) { pendingQuote = $0 }
                            .id(fileBrowserIdentity).background(panelBackground)
                    }
                case .commands:
                    SavedCommandsPanel(data: $workspaceData, hosts: hosts, currentHost: selectedSession?.host)
                        .background(panelBackground)
                case .smb:
                    SMBMountsPanel(data: $workspaceData, selectedID: selectedSMB?.id)
                        .background(panelBackground)
                case .history:
                    ExecutionHistoryPanel()
                        .background(panelBackground)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var assistantPanel: some View {
        if isSMBTarget {
            ContentUnavailableView("此连接暂不提供终端助手", systemImage: "externaldrive", description: Text("SMB 文件操作使用当前共享，不会发送到之前的终端。"))
        } else if let session = selectedSession {
            AssistantPanel(
                targetHost: session.host,
                model: assistantModel(for: session),
                assistantFontSize: preferences.assistantFontSize,
                quote: $pendingQuote
            )
            .id(session.id)
            .disabled(closingSessionIDs.contains(session.id))
        }
    }

    /// The assistant model for a session, wired to run confirmed commands
    /// inside that session's live terminal.
    private func assistantModel(for session: TerminalSession) -> TerminalAIModel {
        let model = assistantModels.model(
            for: session,
            workingDirectory: ((session.startingDirectory ?? preferences.workingDirectory) as NSString).expandingTildeInPath
        )
        if preferences.keepRecentTurns != model.contextConfiguration.keepRecentTurns
            || preferences.triggerRatio != model.contextConfiguration.triggerRatio
            || !model.contextConfiguration.autoCompact {
            let keep = preferences.keepRecentTurns
            let ratio = preferences.triggerRatio
            Task { await model.applyContextDefaults(keepRecentTurns: keep, triggerRatio: ratio) }
        }
        let sessionID: UUID? = session.id
        let supportedShell: Bool
        if let host = session.host {
            supportedShell = ["bash", "zsh"].contains(host.remoteShell)
        } else {
            let shell = (preferences.terminalAppearance.shellPath as NSString).lastPathComponent
            supportedShell = shell == "zsh"
        }
        if let sessionID {
            let live = terminalViews.liveTerminal(for: sessionID)
            model.terminalAvailable = supportedShell && (live?.proofSource.supportsCompletionProof ?? false)
            model.terminalGeneration = live?.view.connectionGeneration
        } else {
            model.terminalAvailable = false
            model.terminalGeneration = nil
        }
        model.terminalBindingProvider = { [terminalViews] in
            guard let sessionID else {
                return TerminalBindingStatus(available: false, generation: nil, reason: "会话标识缺失")
            }
            guard supportedShell else {
                let shell = session.host?.remoteShell ?? "本机 shell"
                return TerminalBindingStatus(available: false, generation: nil,
                    reason: "仅支持 bash/zsh 的 AI 自动执行，当前为 \(shell)")
            }
            guard let live = terminalViews.liveTerminal(for: sessionID) else {
                return TerminalBindingStatus(available: false, generation: nil,
                    reason: "终端进程未运行（连接已断开或 shell 已退出，可点终端里的重新连接）")
            }
            guard live.proofSource.supportsCompletionProof else {
                return TerminalBindingStatus(available: false, generation: live.view.connectionGeneration,
                    reason: "终端没有完成证明钩子")
            }
            return TerminalBindingStatus(available: true, generation: live.view.connectionGeneration, reason: nil)
        }
        model.terminalCommandRunner = { [terminalViews, session] proposal in
            guard let sessionID else { return nil }
            guard let expectedGeneration = proposal.terminalGeneration else {
                model.lastTerminalRunDiagnostic = "本轮缺少终端代次快照（派发时绑定终端不可用）"
                return nil
            }
            guard let live = terminalViews.liveTerminal(for: sessionID) else {
                model.lastTerminalRunDiagnostic = "绑定终端视图不存在或 shell 进程已退出"
                return nil
            }
            guard live.view.connectionGeneration == expectedGeneration,
                  live.proofSource.generation == expectedGeneration else {
                model.lastTerminalRunDiagnostic = "终端代次不匹配（终端已重建或重连）"
                return nil
            }
            let outcome = await TerminalCommandDriver.shared.run(
                proposal.command,
                in: live.view,
                proofSource: live.proofSource,
                timeout: .infinity,
                requiresSudoPassword: proposal.requiresSudoPassword,
                sudoPasswordProvider: { [weak model] in
                    // Prefer the task's sudo password; fall back to the SSH
                    // connection password — on typical NAS setups sudo and
                    // login share the same credential.
                    if let task = model?.currentTaskSudoPassword, !task.isEmpty {
                        return task
                    }
                    guard let host = session.host else { return nil }
                    return SSHHostStore.load().first(where: { $0.id == host.id })?.password
                }
            )
            guard !outcome.unavailable else {
                model.lastTerminalRunDiagnostic = outcome.unavailableReason
                return nil
            }
            return ShellCommandResult(
                output: outcome.output.isEmpty ? "（这条命令没有产生输出）" : outcome.output,
                exitCode: outcome.exitStatus ?? -1,
                timedOut: outcome.timedOut,
                delivery: proposal.delivery.note,
                exitCodeUnknown: outcome.exitStatus == nil,
                capturedBytes: outcome.capturedBytes,
                omittedBytes: outcome.omittedBytes,
                interruptedNotice: outcome.interruptedReason,
                captureScope: outcome.captureScope,
                terminalReturnedToPrompt: outcome.returnedToPrompt
            )
        }
        return model
    }

    private var terminalTabs: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(sessions) { session in
                        tabItem(session)
                    }
                    Button {
                        addSession(host: nil)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("新建本机终端标签")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(.bar)

            Divider()
            terminalPanes
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func tabItem(_ session: TerminalSession) -> some View {
        let isSelected = session.id == selectedSessionID
        return HStack(spacing: 6) {
            Circle()
                .fill(session.host == nil ? Color.green : Color.blue)
                .frame(width: 6, height: 6)
            Text(session.title)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
            if sessions.count > 1, isSelected || hoveredSessionID == session.id {
                Button {
                    closeSession(session)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭标签")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .textBackgroundColor) : (hoveredSessionID == session.id ? Color.primary.opacity(0.06) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color(nsColor: .separatorColor) : Color.clear, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedSessionID = session.id }
        .onHover { hovering in
            hoveredSessionID = hovering ? session.id : (hoveredSessionID == session.id ? nil : hoveredSessionID)
        }
        .help(session.host == nil ? "本机终端" : session.host!.endpoint)
    }

    private var terminalPanes: some View {
        GeometryReader { geometry in
            let secondaryID = sessions.first(where: { $0.id == splitSessionID && $0.id != selectedSessionID })?.id
            let isSplit = secondaryID != nil
            let paneWidth = isSplit ? max(0, (geometry.size.width - 1) * splitFraction) : geometry.size.width

            ZStack(alignment: .topLeading) {
                ForEach(sessions) { session in
                    let isPrimary = session.id == selectedSessionID
                    let isSecondary = session.id == secondaryID
                    let restartToken = sessionRestartTokens[session.id, default: 0]
                    VStack(spacing: 0) {
                        if let host = session.host {
                            sshConnectionBanner(session: session, host: host)
                        }
                        LocalTerminalView(
                            id: session.id,
                            sshHost: session.host,
                            appearance: preferences.terminalAppearance,
                            workingDirectory: preferences.workingDirectory,
                            preferredWorkingDirectory: session.startingDirectory,
                            registerView: { terminalViews.register($0, proofSource: $1, for: session.id) },
                            onExit: { _ in
                                guard sessionRestartTokens[session.id, default: 0] == restartToken else { return }
                                exitedSessionIDs.insert(session.id)
                            },
                            onSSHState: { state in
                                // Creation happens during a SwiftUI update; publish on
                                // the next turn and reject callbacks from old panes.
                                DispatchQueue.main.async {
                                    guard sessions.contains(where: { $0.id == session.id }),
                                          sessionRestartTokens[session.id, default: 0] == restartToken else { return }
                                    sshConnectionStates[session.id] = state
                                }
                            }
                        )
                        .id("\(session.id.uuidString)-\(sessionRestartTokens[session.id, default: 0])")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            if session.host == nil, exitedSessionIDs.contains(session.id), isPrimary || isSecondary {
                                Button {
                                    exitedSessionIDs.remove(session.id)
                                    sessionRestartTokens[session.id, default: 0] += 1
                                } label: {
                                    Label(session.host == nil ? "重新启动终端" : "重新连接", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            }
                        }
                    }
                    .frame(width: isSplit ? paneWidth : geometry.size.width, height: geometry.size.height)
                    .offset(x: isSecondary ? paneWidth + 1 : 0)
                    .opacity(isPrimary || isSecondary ? 1 : 0)
                    .allowsHitTesting(isPrimary || isSecondary)
                    .accessibilityHidden(!(isPrimary || isSecondary))
                }

                if isSplit {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1, height: geometry.size.height)
                        .overlay(
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: 9, height: geometry.size.height)
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            let startingFraction = splitDragStart ?? splitFraction
                                            splitDragStart = startingFraction
                                            let availableWidth = max(geometry.size.width - 1, 1)
                                            splitFraction = min(0.8, max(0.2, startingFraction + value.translation.width / availableWidth))
                                        }
                                        .onEnded { _ in splitDragStart = nil }
                                )
                        )
                        .offset(x: paneWidth)
                }
            }
            .clipped()
        }
    }

    @ViewBuilder
    private func sshConnectionBanner(session: TerminalSession, host: SSHHost) -> some View {
        let state = sshConnectionStates[session.id, default: .connecting]
        if state != .connected && state != .terminalOpen {
            HStack(spacing: 10) {
                if state == .connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: state.canCancel ? "terminal" : "info.circle")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(state == .connecting ? "正在连接 \(host.displayName)…" : state.label)
                        .font(.system(size: 12, weight: .medium))
                    if case .failed(let failure) = state {
                        Text(failure.message(address: host.address))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if state == .needsInput {
                        Text("请在下方终端完成主机确认或认证。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if state.canCancel {
                    Button {
                        terminalViews.cancelSSHConnection(id: session.id)
                    } label: { Image(systemName: "xmark") }
                        .help("取消连接").accessibilityLabel("取消连接")
                } else if state.canRetry {
                    Button {
                        exitedSessionIDs.remove(session.id)
                        sshConnectionStates[session.id] = .connecting
                        sessionRestartTokens[session.id, default: 0] += 1
                    } label: { Image(systemName: "arrow.clockwise") }
                        .help("重新连接").accessibilityLabel("重新连接")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial)
        }
    }

    // MARK: - Actions

    private func quoteSelection() {
        guard page == .terminal, let id = selectedSession?.id else {
            errorMessage = "请先在终端中选择要引用的文字。"
            return
        }
        guard let text = terminalViews.selection(for: id) else {
            errorMessage = "没有检测到选中的终端内容。先在终端里拖动选择文字，再点“引用选中内容”。"
            return
        }
        pendingQuote = AIQuote(
            kind: "终端",
            source: "\(selectedSession?.title ?? "本机") · 选中内容",
            text: String(text.prefix(20_000))
        )
    }

    private func deleteHost(_ host: SSHHost) {
        var updatedHosts = hosts
        updatedHosts.removeAll { $0.id == host.id }
        do {
            try SSHHostStore.save(updatedHosts)
            SSHHostStore.deletePasswordFile(for: host.id)
            hosts = updatedHosts
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func beginAddHost() {
        hostDraft = SSHHost(name: "", address: "", username: "")
        isNewHost = true
        showHostEditor = true
    }

    private func beginEditHost(_ host: SSHHost) {
        hostDraft = host
        isNewHost = false
        showHostEditor = true
    }

    private func saveHost(_ host: SSHHost, connect: Bool) throws {
        var updatedHosts = hosts
        if let index = updatedHosts.firstIndex(where: { $0.id == host.id }) { updatedHosts[index] = host }
        else { updatedHosts.append(host) }
        try SSHHostStore.save(updatedHosts)
        hosts = updatedHosts
        if !host.savePassword { SSHHostStore.deletePasswordFile(for: host.id) }
        if connect { addSession(host: host) }
    }

    private func addSession(host: SSHHost?, workingDirectory: String? = nil) {
        if let host, let existing = TerminalSessionPolicy.existingSession(for: host, in: sessions) {
            selectedSessionID = existing.id
            page = .terminal
            sidebarSelection = .session(existing.id)
            return
        }
        let session = TerminalSession(host: host, startingDirectory: workingDirectory)
        sessions.append(session)
        selectedSessionID = session.id
        page = .terminal
        sidebarSelection = .session(session.id)
    }

    /// Clicking a saved host connects once and afterwards only switches to the
    /// existing terminal tab; a host never gets duplicate live sessions.
    private func openHost(_ host: SSHHost) {
        if let session = TerminalSessionPolicy.existingSession(for: host, in: sessions) {
            selectedSessionID = session.id
            page = .terminal
            sidebarSelection = .session(session.id)
        } else {
            addSession(host: host)
        }
    }

    private func openLocalTerminal() {
        if let session = sessions.first(where: { $0.host == nil }) {
            selectedSessionID = session.id
            page = .terminal
            sidebarSelection = .session(session.id)
        } else {
            addSession(host: nil)
        }
    }

    private func persistSessions() {
        TerminalSessionStore.save(sessions: sessions, selectedID: selectedSessionID)
    }

    private func closeSession(_ session: TerminalSession) {
        guard !closingSessionIDs.contains(session.id) else { return }
        closingSessionIDs.insert(session.id)
        Task { @MainActor in
            defer { closingSessionIDs.remove(session.id) }
            do {
                try await assistantModels.deleteHistory(for: session.id)
                removeClosedSession(session)
                NotificationCenter.default.post(name: .terminalHistoryDeleted, object: session.id)
            } catch {
                errorMessage = "终端聊天数据删除尚未完成，请重试关闭：\(error.localizedDescription)"
            }
        }
    }

    private func removeClosedSession(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        if splitSessionID == session.id { splitSessionID = nil }
        if sessions.count == 1 {
            let replacement = TerminalSession(host: nil)
            sessions = [replacement]
            selectedSessionID = replacement.id
            if !isSMBTarget { page = .terminal; sidebarSelection = .session(replacement.id) }
            return
        }
        sessions.remove(at: index)
        let nextIndex = min(index, sessions.count - 1)
        if selectedSessionID == session.id { selectedSessionID = sessions[nextIndex].id }
        if case .session(let id) = sidebarSelection, id == session.id, let nextID = selectedSessionID {
            sidebarSelection = .session(nextID)
        }
    }
}

private struct WorkspaceWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> Reader { let reader = Reader(); reader.onWindow = onWindow; return reader }
    func updateNSView(_ view: Reader, context: Context) { view.onWindow = onWindow }
    final class Reader: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { WorkspaceWindowCoordinator.shared.register(window) }
            if let window { DispatchQueue.main.async { [weak self, weak window] in if let window { self?.onWindow?(window) } } }
        }
    }
}
