import Testing
@testable import SwiftTerminal

struct LocalInspectionPromptTests {
    @Test func sdkmanListsAllInstalledVersionsWithoutArbitraryShell() {
        let command = LocalShellCommandRunner.inspectionCommand("sdkman")
        #expect(command?.contains("已安装版本：") == true)
        #expect(command?.contains("当前使用：") == true)
        #expect(command?.contains(".sdkman/candidates") == true)
    }
}
