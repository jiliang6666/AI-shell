import Foundation

struct QuickCommand: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var command: String
}

struct QuickCommandStore: Sendable {
    private let fileURL: URL

    static let live = QuickCommandStore(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftTerminal", isDirectory: true)
            .appendingPathComponent("quick-commands.json")
    )

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> [QuickCommand] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([QuickCommand].self, from: Data(contentsOf: fileURL))
    }

    func save(_ commands: [QuickCommand]) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Preserve unreadable data instead of replacing it with an empty
            // list when a caller has recovered from a failed load.
            _ = try JSONDecoder().decode([QuickCommand].self, from: Data(contentsOf: fileURL))
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(commands).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

extension Notification.Name {
    static let quickCommandsChanged = Notification.Name("SwiftTerminal.quickCommandsChanged")
}
