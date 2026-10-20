import AppKit
import Foundation

@MainActor
enum FinderFolderOpenRouter {
    private(set) static var pendingPaths: [String] = []
    private static var handler: ((String) -> Void)?

    static func register(_ handler: @escaping (String) -> Void) {
        self.handler = handler
        let pending = pendingPaths
        pendingPaths.removeAll()
        pending.forEach(handler)
    }

    static func unregister() {
        handler = nil
    }

    static func open(_ path: String) {
        if let handler {
            handler(path)
        } else {
            pendingPaths.append(path)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class ZhanqiaoApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Settings, minimized windows and windows on disconnected screens are
        // not evidence that a usable workspace is in front of the user.
        !WorkspaceWindowCoordinator.shared.showWorkspace()
    }

    @objc func openFolderInZhanqiao(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL],
            let folder = urls.first(where: Self.isDirectory)
        else {
            error.pointee = "请选择一个有效的文件夹。" as NSString
            return
        }
        FinderFolderOpenRouter.open(folder.standardizedFileURL.path)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
