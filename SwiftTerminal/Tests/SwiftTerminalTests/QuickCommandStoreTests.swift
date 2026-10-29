import Foundation
import Testing
@testable import SwiftTerminal

struct QuickCommandStoreTests {
    @Test("快捷命令往返保留多行、引号和 Unicode")
    func roundTripPreservesCommandText() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let commands = [
            QuickCommand(name: "检查 NAS 🧪", command: "ssh nas 'echo \"你好\"'\nprintf '完成\n'")
        ]
        try store.save(commands)

        #expect(try store.load() == commands)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("quick-commands.json").path
        )
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("缺少快捷命令文件时返回空列表")
    func missingFileLoadsEmptyList() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try store.load().isEmpty)
    }

    @Test("保存更新和删除后的列表能重新读取")
    func saveUpdatesAndDeleteRoundTrip() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = QuickCommand(name: "检查", command: "pwd")
        let second = QuickCommand(name: "列表", command: "ls")
        try store.save([first, second])

        let updated = QuickCommand(id: first.id, name: "检查目录", command: "pwd -P")
        try store.save([updated, second])
        #expect(try store.load() == [updated, second])

        try store.save([])
        #expect(try store.load().isEmpty)
    }

    @Test("损坏的快捷命令文件会报错且保存不会覆盖原内容")
    func corruptFileIsPreserved() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("quick-commands.json")
        let original = Data("{broken-json".utf8)
        try original.write(to: file)

        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) {
            try store.save([QuickCommand(name: "replace", command: "echo unsafe")])
        }
        #expect(try Data(contentsOf: file) == original)
    }

    private func makeStore() -> (URL, QuickCommandStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickCommandStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (directory, QuickCommandStore(fileURL: directory.appendingPathComponent("quick-commands.json")))
    }
}
