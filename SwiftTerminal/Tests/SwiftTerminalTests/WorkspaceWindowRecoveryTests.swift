import AppKit
import Testing
@testable import SwiftTerminal

@Suite("Workspace window reopening")
@MainActor
struct WorkspaceWindowRecoveryTests {
    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test("A hidden workspace is reused even when settings is the front window")
    func hiddenWorkspaceIsReused() {
        let workspace = makeWindow()
        let settings = makeWindow()
        defer { workspace.close(); settings.close() }
        var opened = 0
        var activated = 0
        var presented: NSWindow?
        let coordinator = WorkspaceWindowCoordinator(
            orderedWindows: { [settings, workspace] },
            activateApplication: { activated += 1 },
            presentWindow: { presented = $0 }
        )
        coordinator.configureOpenWindow { opened += 1 }
        coordinator.register(workspace)

        #expect(!workspace.isVisible)
        #expect(coordinator.showWorkspace())
        #expect(presented === workspace)
        #expect(activated == 1)
        #expect(opened == 0)
    }

    @Test("The foremost workspace is selected without opening another scene")
    func foremostWorkspaceIsSelected() {
        let first = makeWindow()
        let second = makeWindow()
        defer { first.close(); second.close() }
        var presented: NSWindow?
        let coordinator = WorkspaceWindowCoordinator(
            orderedWindows: { [second, first] }, activateApplication: {},
            presentWindow: { presented = $0 }
        )
        coordinator.register(first)
        coordinator.register(second)
        #expect(coordinator.showWorkspace())
        #expect(presented === second)
    }

    @Test("Closing the last workspace opens a fresh scene instead of reviving a retained window")
    func lastWindowClosed() {
        let window = makeWindow()
        var opened = 0
        var presented = 0
        let coordinator = WorkspaceWindowCoordinator(
            orderedWindows: { [window] }, activateApplication: {},
            presentWindow: { _ in presented += 1 }
        )
        coordinator.configureOpenWindow { opened += 1 }
        coordinator.register(window)
        window.close()

        #expect(coordinator.showWorkspace())
        #expect(opened == 1)
        #expect(presented == 0)
    }

    @Test("Rapid reopen events coalesce, while a failed opening can be retried")
    func repeatedReopenEvents() {
        var opened = 0
        var now: TimeInterval = 10
        let coordinator = WorkspaceWindowCoordinator(
            orderedWindows: { [] }, activateApplication: {}, presentWindow: { _ in },
            uptime: { now }
        )
        coordinator.configureOpenWindow { opened += 1 }
        #expect(coordinator.showWorkspace())
        #expect(coordinator.showWorkspace())
        #expect(opened == 1)

        now += 2
        #expect(coordinator.showWorkspace())
        #expect(opened == 2)
    }

    @Test("Attaching a scene completes the pending opening, allowing an immediate close and reopen")
    func attachedWindowCompletesReopen() {
        var opened = 0
        let coordinator = WorkspaceWindowCoordinator(
            orderedWindows: { [] }, activateApplication: {}, presentWindow: { _ in }, uptime: { 10 }
        )
        coordinator.configureOpenWindow { opened += 1 }
        #expect(coordinator.showWorkspace())
        let window = makeWindow()
        coordinator.register(window)
        window.close()
        #expect(coordinator.showWorkspace())
        #expect(opened == 2)
    }

    @Test("AppKit's default behavior remains available before SwiftUI supplies its opening action")
    func startupFallback() {
        let coordinator = WorkspaceWindowCoordinator(
            orderedWindows: { [] }, activateApplication: {}, presentWindow: { _ in }
        )
        #expect(!coordinator.showWorkspace())
    }

    @Test("Windows on connected screens keep their coordinates, including a display left of the main screen")
    func connectedScreen() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1920, y: 0, width: 1920, height: 1080)]
        let frame = CGRect(x: -1700, y: 100, width: 1280, height: 820)
        #expect(WorkspaceWindowRecovery.recoveredFrame(frame, visibleFrames: screens) == frame)
    }

    @Test("A lost title bar is recovered without resizing the terminal", arguments: [
        CGRect(x: 3000, y: 100, width: 1280, height: 820),
        CGRect(x: 100, y: -800, width: 1280, height: 820),
        CGRect(x: 100, y: 850, width: 1600, height: 1000)
    ])
    func lostWindow(frame: CGRect) {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let recovered = WorkspaceWindowRecovery.recoveredFrame(frame, visibleFrames: [screen])
        #expect(recovered.size == frame.size)
        #expect(recovered.minX >= screen.minX)
        #expect(recovered.maxY == screen.maxY)
    }
}
