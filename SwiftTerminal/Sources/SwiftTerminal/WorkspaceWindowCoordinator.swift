import AppKit

/// Owns Dock reopening without retaining closed SwiftUI scenes or their terminals.
@MainActor
final class WorkspaceWindowCoordinator: NSObject {
    static let shared = WorkspaceWindowCoordinator()
    static let sceneID = "terminal-workspace"

    private let windows = NSHashTable<NSWindow>.weakObjects()
    private let orderedWindows: @MainActor () -> [NSWindow]
    private let activateApplication: @MainActor () -> Void
    private let presentWindow: @MainActor (NSWindow) -> Void
    private let uptime: () -> TimeInterval
    private var openWindow: (@MainActor () -> Void)?
    private var openRequestedAt: TimeInterval?

    init(
        orderedWindows: @escaping @MainActor () -> [NSWindow] = { NSApp.orderedWindows },
        activateApplication: @escaping @MainActor () -> Void = {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
        },
        presentWindow: @escaping @MainActor (NSWindow) -> Void = WorkspaceWindowCoordinator.present,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.orderedWindows = orderedWindows
        self.activateApplication = activateApplication
        self.presentWindow = presentWindow
        self.uptime = uptime
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func configureOpenWindow(_ action: @escaping @MainActor () -> Void) {
        openWindow = action
    }

    func register(_ window: NSWindow) {
        windows.add(window)
        openRequestedAt = nil
    }

    /// Returns false only before SwiftUI has supplied its scene-opening action,
    /// so AppKit can still perform its default reopen behavior during launch.
    @discardableResult
    func showWorkspace() -> Bool {
        let registered = windows.allObjects
        if let window = orderedWindows().first(where: { windows.contains($0) })
            ?? registered.first(where: { $0.isVisible && !$0.isMiniaturized })
            ?? registered.first {
            openRequestedAt = nil
            activateApplication()
            presentWindow(window)
            return true
        }

        guard let openWindow else { return false }
        activateApplication()
        let now = uptime()
        // SwiftUI creates scenes asynchronously. Coalesce rapid Dock clicks,
        // but allow a later click to retry if a scene never attached a window.
        if let requested = openRequestedAt, now - requested < 1 { return true }
        openRequestedAt = now
        openWindow()
        return true
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.remove(window)
    }

    static func present(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.styleMask.contains(.fullScreen) {
            let screens = NSScreen.screens.map(\.visibleFrame)
            let frame = WorkspaceWindowRecovery.recoveredFrame(
                window.frame, visibleFrames: screens,
                preferredFrame: NSScreen.main?.visibleFrame
            )
            if frame != window.frame { window.setFrame(frame, display: true) }
        }
        window.makeKeyAndOrderFront(nil)
    }
}

enum WorkspaceWindowRecovery {
    /// Keep a reachable title bar on any connected screen. A disconnected
    /// display's saved coordinates must not leave the activated app offscreen.
    static func recoveredFrame(
        _ frame: CGRect, visibleFrames: [CGRect], preferredFrame: CGRect? = nil
    ) -> CGRect {
        let titleBar = CGRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28)
        if visibleFrames.contains(where: {
            let intersection = titleBar.intersection($0)
            return intersection.width >= min(80, frame.width) && intersection.height >= 20
        }) {
            return frame
        }
        guard let screen = preferredFrame ?? visibleFrames.first else { return frame }
        var recovered = frame
        recovered.origin.x = max(screen.minX, screen.midX - frame.width / 2)
        recovered.origin.y = screen.maxY - frame.height
        return recovered
    }
}
