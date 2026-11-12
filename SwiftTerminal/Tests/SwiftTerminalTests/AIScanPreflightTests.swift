import Foundation
import Testing
@testable import SwiftTerminal

struct AIScanPreflightTests {
    @Test("A scoped scan with traversal and type conditions retains its real output and exit code")
    func conditionalScanKeepsExitCode() async {
        let result = await LocalShellCommandRunner.run(
            "find . -maxdepth 0 -type d -print; exit 7",
            workingDirectory: FileManager.default.temporaryDirectory.path,
            enforceScanPolicy: true,
            workingDirectoryIsTrustedForScan: true,
            historyRecorder: { _ in }
        )

        #expect(!result.timedOut)
        #expect(!result.exitCodeUnknown)
        #expect(result.exitCode == 7)
        #expect(result.output.contains("."))
    }

    @Test("The background backend refuses a root scan before launching a process")
    func backgroundRootScanIsNotDispatched() async {
        let result = await LocalShellCommandRunner.run(
            "find / -maxdepth 0 -name Example.app",
            workingDirectory: FileManager.default.temporaryDirectory.path,
            enforceScanPolicy: true,
            historyRecorder: { _ in }
        )

        #expect(result.exitCode == 2)
        #expect(result.captureScope == .applicationResult)
        #expect(!result.timedOut)
    }

    @Test("Background execution trusts its explicitly set working directory")
    func backgroundRelativeScanUsesExplicitWorkingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIScanCwd-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await LocalShellCommandRunner.run(
            "du -sh .",
            workingDirectory: directory.path,
            enforceScanPolicy: true,
            workingDirectoryIsTrustedForScan: true,
            historyRecorder: { _ in }
        )

        #expect(!result.timedOut)
        #expect(result.exitCode == 0)
        #expect(!result.output.contains("已拦截递归扫描"))
    }
}
