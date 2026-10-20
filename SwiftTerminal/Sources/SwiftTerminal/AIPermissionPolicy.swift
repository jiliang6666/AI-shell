import Foundation

struct AIToolInvocation: Sendable {
    var callID: String
    var name: String
    var argumentsJSON: Data
    var command: String?
    var isSavedAction: Bool = false
    var isSMBMutation: Bool = false

    var action: AIToolAction {
        switch name {
        case "inspect_target", "run_inspection":
            .fixedInspection
        case "list_saved_actions":
            .metadataRead
        case "run_saved_action":
            isSMBMutation ? .nativeMutation : .savedShell
        case "run_command":
            .arbitraryShell
        default:
            .arbitraryShell
        }
    }
}

struct AIExecutionContext: Sendable {
    var sessionID: UUID
    var turnID: UUID
    var requestID: UUID
    var permission: AIPermissionMode
    var permissionVersion: Int64
    var target: AITargetSnapshot
    var terminalReady: Bool
    var terminalGeneration: UUID? = nil
}

enum AIPermissionOutcome: Equatable, Sendable {
    case allow(AIExecutionBackend)
    case deny(AIErrorCode)
    /// The command mutates state; run it only after the user confirms.
    case confirm
}

enum AIPermissionPolicy {
    static let allowedInspections = ["system", "disk", "docker", "services"]

    static func evaluate(_ invocation: AIToolInvocation, context: AIExecutionContext) -> AIPermissionOutcome {
        switch invocation.action {
        case .metadataRead:
            .allow(.restrictedInspection)
        case .fixedInspection:
            switch context.permission {
            case .readOnly:
                .allow(.restrictedInspection)
            case .terminalOnly, .fullAccess:
                if context.terminalReady { .allow(.terminal) }
                else if context.permission == .fullAccess { .allow(.restrictedInspection) }
                else { .deny(.terminalUnavailable) }
            }
        case .savedShell:
            switch context.permission {
            case .readOnly:
                ShellCommandSafety.isReadOnly(invocation.command ?? "")
                    ? (context.terminalReady ? .allow(.terminal) : .allow(.background))
                    : (context.terminalReady ? .confirm : .deny(.terminalUnavailable))
            case .terminalOnly:
                context.terminalReady ? .allow(.terminal) : .deny(.terminalUnavailable)
            case .fullAccess:
                context.terminalReady ? .allow(.terminal) : .allow(.background)
            }
        case .arbitraryShell:
            switch context.permission {
            case .readOnly:
                ShellCommandSafety.isReadOnly(invocation.command ?? "")
                    ? (context.terminalReady ? .allow(.terminal) : .allow(.background))
                    : (context.terminalReady ? .confirm : .deny(.terminalUnavailable))
            case .terminalOnly:
                context.terminalReady ? .allow(.terminal) : .deny(.terminalUnavailable)
            case .fullAccess:
                context.terminalReady ? .allow(.terminal) : .allow(.background)
            }
        case .nativeMutation:
            switch context.permission {
            case .readOnly, .terminalOnly:
                .deny(.permissionDenied)
            case .fullAccess:
                .allow(.native)
            }
        }
    }
}
