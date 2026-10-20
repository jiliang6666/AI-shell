import Foundation
import XCTest
@testable import SwiftTerminal

final class FileOperationsTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftTerminalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
        sandbox = nil
    }

    func testNamePolicyAcceptsPlainNamesAndRejectsTraversal() throws {
        XCTAssertEqual(try FileNamePolicy.validate("  notes.txt "), "notes.txt")
        for invalid in ["", "   ", "..", ".", "dir/child", "a\u{0}b"] {
            XCTAssertThrowsError(try FileNamePolicy.validate(invalid), "应拒绝名称 \(invalid.debugDescription)")
        }
    }

    func testUniqueNameAppendsCounterBeforeExtension() {
        let taken: Set<String> = ["report.txt", "report 2.txt", "archive"]

        XCTAssertEqual(FileNamePolicy.uniqueName(for: "report.txt") { taken.contains($0) }, "report 3.txt")
        XCTAssertEqual(FileNamePolicy.uniqueName(for: "archive") { taken.contains($0) }, "archive 2")
        XCTAssertEqual(FileNamePolicy.uniqueName(for: "fresh.txt") { taken.contains($0) }, "fresh.txt")
    }

    /// Synology's `internal-sftp` is reached through the interactive client, so
    /// prompt and banner lines appear in the same stream as command results.
    func testSFTPOutputCleaningDropsPromptAndBannerNoise() {
        let raw = """
        Connected to 192.168.1.10.
        sftp> pwd
        Remote working directory: /
        sftp> ls -la "/"
        drwxrwxrwx    1 root     root          126 Jul 29 19:06 docker
        -rw-r--r--    1 admin    users       10240 Sep 28 10:00 notes.txt
        sftp> quit
        Connection to 192.168.1.10 closed.
        """

        let cleaned = SFTPService.cleanedOutput(raw)

        XCTAssertFalse(cleaned.contains("sftp>"))
        XCTAssertFalse(cleaned.contains("Connected to"))
        XCTAssertFalse(cleaned.contains("closed"))
        XCTAssertTrue(cleaned.contains("Remote working directory: /"))
        XCTAssertTrue(cleaned.contains("docker"))
        XCTAssertTrue(cleaned.contains("notes.txt"))
    }

    func testCreateWriteRenameAndRemoveRoundTrip() throws {
        let folder = sandbox.appendingPathComponent("工作区").path
        try LocalFileOperations.createDirectory(at: folder)

        let file = (folder as NSString).appendingPathComponent("说明.txt")
        try LocalFileOperations.writeText("第一行\n第二行", to: file)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "第一行\n第二行")

        let renamed = (folder as NSString).appendingPathComponent("改名.txt")
        try LocalFileOperations.move(file, to: renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed))

        try LocalFileOperations.remove(renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed))

        try LocalFileOperations.remove(folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
    }

    func testRemoveRefusesNonEmptyDirectory() throws {
        let folder = sandbox.appendingPathComponent("keep").path
        try LocalFileOperations.createDirectory(at: folder)
        try LocalFileOperations.writeText("x", to: (folder as NSString).appendingPathComponent("inner.txt"))

        XCTAssertThrowsError(try LocalFileOperations.remove(folder)) { error in
            XCTAssertEqual((error as? FileOperationError)?.errorDescription, "目录不是空的，请先删除其中的内容。")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder))
    }

    func testCopyIntoDirectoryKeepsExistingFile() throws {
        let folder = sandbox.appendingPathComponent("inbox").path
        try LocalFileOperations.createDirectory(at: folder)
        let source = sandbox.appendingPathComponent("notes.txt").path
        try LocalFileOperations.writeText("new", to: source)
        try LocalFileOperations.writeText("old", to: (folder as NSString).appendingPathComponent("notes.txt"))

        let copied = try LocalFileOperations.copy(source, into: folder)

        XCTAssertEqual((copied as NSString).lastPathComponent, "notes 2.txt")
        XCTAssertEqual(try String(contentsOfFile: copied, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOfFile: (folder as NSString).appendingPathComponent("notes.txt"), encoding: .utf8), "old")
    }

    func testTextHeuristicsSeparateBinaryFromUTF8() {
        XCTAssertTrue(FileTextHeuristics.isProbablyText(Data("hello 终端".utf8)))
        XCTAssertFalse(FileTextHeuristics.isProbablyText(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x0D])))
        XCTAssertFalse(FileTextHeuristics.isProbablyText(Data([0xFF, 0xFE, 0xFD])))
    }

    func testWorkspaceFileServiceUsesLocalTargetWhenHostIsNil() async throws {
        let file = sandbox.appendingPathComponent("远端.txt").path

        try await WorkspaceFileService.writeText("内容", host: nil, path: file)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "内容")

        let renamed = try await WorkspaceFileService.rename(host: nil, path: file, to: "本地.txt")
        XCTAssertEqual((renamed as NSString).lastPathComponent, "本地.txt")

        try await WorkspaceFileService.remove(host: nil, path: renamed, isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed))
    }

    func testRemotePathJoinKeepsSingleSlash() {
        XCTAssertEqual(SFTPService.joined("/home/user", "notes.txt"), "/home/user/notes.txt")
        XCTAssertEqual(SFTPService.joined("/", "notes.txt"), "/notes.txt")
        XCTAssertEqual(SFTPService.joined("~", "notes.txt"), "~/notes.txt")
    }
}
