import AppKit
import SwiftUI

@main
struct SwiftTerminalApp: App {
    @NSApplicationDelegateAdaptor(ZhanqiaoApplicationDelegate.self) private var applicationDelegate
    @FocusedValue(\.terminalActionsAvailable) private var terminalActionsAvailable
    var body: some Scene {
        WindowGroup(id: WorkspaceWindowCoordinator.sceneID) {
            TerminalWorkspace()
                .task { _ = UpdateController.shared }
                .task { await LocalNetworkAccess.requestAtLaunch() }
                .task { await AISessionCoordinator.shared.bootstrap() }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("新建终端标签") {
                    NotificationCenter.default.post(name: .newTerminalTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("关闭终端标签") {
                    closeKeyWindowOrTerminalTab()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("查找…") {
                    sendFindAction(.showFindPanel)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(terminalActionsAvailable != true)
                Button("查找下一个") {
                    sendFindAction(.next)
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(terminalActionsAvailable != true)
                Button("查找上一个") {
                    sendFindAction(.previous)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(terminalActionsAvailable != true)
                Divider()
                Button("清除终端") {
                    NotificationCenter.default.post(name: .clearTerminal, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(terminalActionsAvailable != true)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Button("显示或隐藏侧边栏") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                Button("显示或隐藏 AI 助手") {
                    NotificationCenter.default.post(name: .toggleAssistant, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
        }
    }

    /// `⌘W` closes the settings window when it is focused and otherwise closes
    /// the current terminal tab, which is what the workspace expects.
    private func closeKeyWindowOrTerminalTab() {
        if let key = NSApp.keyWindow, key.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" {
            key.performClose(nil)
            return
        }
        NotificationCenter.default.post(name: .closeTerminalTab, object: nil)
    }

    private func sendFindAction(_ action: NSFindPanelAction) {
        let menuItem = NSMenuItem()
        menuItem.tag = Int(action.rawValue)
        NSApp.sendAction(NSSelectorFromString("performFindPanelAction:"), to: nil, from: menuItem)
    }
}

extension Notification.Name {
    static let openTerminalAtDirectory = Notification.Name("SwiftTerminal.openTerminalAtDirectory")
    static let terminalHistoryDeleted = Notification.Name("SwiftTerminal.terminalHistoryDeleted")
    static let newTerminalTab = Notification.Name("SwiftTerminal.newTerminalTab")
    static let closeTerminalTab = Notification.Name("SwiftTerminal.closeTerminalTab")
    static let clearTerminal = Notification.Name("SwiftTerminal.clearTerminal")
    static let toggleSidebar = Notification.Name("SwiftTerminal.toggleSidebar")
    static let toggleAssistant = Notification.Name("SwiftTerminal.toggleAssistant")
    static let modelProfilesChanged = Notification.Name("SwiftTerminal.modelProfilesChanged")
    static let workspaceDataChanged = Notification.Name("SwiftTerminal.workspaceDataChanged")
    static let preferencesChanged = Notification.Name("SwiftTerminal.preferencesChanged")
    static let conversationArchiveChanged = Notification.Name("SwiftTerminal.conversationArchiveChanged")
}

private struct TerminalActionsAvailableKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var terminalActionsAvailable: Bool? {
        get { self[TerminalActionsAvailableKey.self] }
        set { self[TerminalActionsAvailableKey.self] = newValue }
    }
}
