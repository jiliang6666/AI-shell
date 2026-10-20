import Foundation
import Testing
@testable import SwiftTerminal

@Test("Permission policy covers fixed inspections, shells, saved actions and SMB")
func permissionPolicyRoutesToolsByMode() {
    let sessionID = UUID()
    let turnID = UUID()
    let target = AITargetSnapshot.local(workingDirectory: nil)

    func context(_ mode: AIPermissionMode, terminalReady: Bool = false) -> AIExecutionContext {
        AIExecutionContext(
            sessionID: sessionID,
            turnID: turnID,
            requestID: UUID(),
            permission: mode,
            permissionVersion: 1,
            target: target,
            terminalReady: terminalReady
        )
    }
    func invocation(name: String = "run_command", smb: Bool = false) -> AIToolInvocation {
        AIToolInvocation(callID: "call", name: name, argumentsJSON: Data(), command: name == "run_command" ? "pwd" : nil, isSavedAction: name == "run_saved_action", isSMBMutation: smb)
    }

    #expect(AIPermissionPolicy.evaluate(AIToolInvocation(callID: "call", name: "inspect_target", argumentsJSON: Data()), context: context(.readOnly)) == .allow(.restrictedInspection))
    #expect(AIPermissionPolicy.evaluate(AIToolInvocation(callID: "call", name: "list_saved_actions", argumentsJSON: Data()), context: context(.readOnly)) == .allow(.restrictedInspection))
    #expect(AIPermissionPolicy.evaluate(invocation(), context: context(.readOnly)) == .allow(.background))
    #expect(AIPermissionPolicy.evaluate(invocation(), context: context(.readOnly, terminalReady: true)) == .allow(.terminal))
    #expect(AIPermissionPolicy.evaluate(invocation(), context: context(.terminalOnly, terminalReady: false)) == .deny(.terminalUnavailable))
    #expect(AIPermissionPolicy.evaluate(invocation(), context: policyContext(.terminalOnly, terminalReady: true)) == .allow(.terminal))
    #expect(AIPermissionPolicy.evaluate(invocation(), context: policyContext(.fullAccess, terminalReady: false)) == .allow(.background))
    #expect(AIPermissionPolicy.evaluate(invocation(name: "run_saved_action", smb: true), context: policyContext(.terminalOnly, terminalReady: true)) == .deny(.permissionDenied))
    #expect(AIPermissionPolicy.evaluate(invocation(name: "run_saved_action", smb: true), context: context(.fullAccess)) == .allow(.native))
}

private func policyContext(_ permission: AIPermissionMode, terminalReady: Bool) -> AIExecutionContext {
    AIExecutionContext(
        sessionID: UUID(), turnID: UUID(), requestID: UUID(),
        permission: permission, permissionVersion: 1,
        target: .local(workingDirectory: nil), terminalReady: terminalReady
    )
}

@Test
func readOnlyAutoRunsQueriesAndConfirmsEdits() {
    let query = AIToolInvocation(callID: "call", name: "run_command", argumentsJSON: Data(), command: "brew list")
    let edit = AIToolInvocation(callID: "call", name: "run_command", argumentsJSON: Data(), command: "brew install wget")
    guard case .allow(.terminal) = AIPermissionPolicy.evaluate(query, context: policyContext(.readOnly, terminalReady: true)) else {
        Issue.record("只读查询应在仅可查看权限下直接执行")
        return
    }
    guard case .confirm = AIPermissionPolicy.evaluate(edit, context: policyContext(.readOnly, terminalReady: true)) else {
        Issue.record("编辑类命令在仅可查看权限下需要用户确认")
        return
    }
    guard case .allow(.background) = AIPermissionPolicy.evaluate(query, context: policyContext(.readOnly, terminalReady: false)) else {
        Issue.record("终端未就绪时只读查询可以后台执行")
        return
    }
}

@Test
func terminalAndFullPermissionsAutoRunCommands() {
    let edit = AIToolInvocation(callID: "call", name: "run_command", argumentsJSON: Data(), command: "brew install wget")
    guard case .allow(.terminal) = AIPermissionPolicy.evaluate(edit, context: policyContext(.terminalOnly, terminalReady: true)) else {
        Issue.record("终端权限的命令应直接在终端执行")
        return
    }
    guard case .allow(.terminal) = AIPermissionPolicy.evaluate(edit, context: policyContext(.fullAccess, terminalReady: true)) else {
        Issue.record("完全权限的命令应直接执行")
        return
    }
    guard case .allow(.background) = AIPermissionPolicy.evaluate(edit, context: policyContext(.fullAccess, terminalReady: false)) else {
        Issue.record("完全权限在终端未就绪时可以后台执行")
        return
    }
}
