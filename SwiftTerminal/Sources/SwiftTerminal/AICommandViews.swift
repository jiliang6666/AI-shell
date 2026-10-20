import SwiftUI

/// Display the original bytes without rewriting shell quoting or line breaks.
struct AICommandPreview: View {
    let command: String
    var fontSize: Double = 14

    private var needsExpansion: Bool { command.count > 240 || command.split(separator: "\n", omittingEmptySubsequences: false).count > 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(command)
                .font(.system(size: max(12, fontSize - 1), design: .monospaced))
                .lineLimit(needsExpansion ? 4 : nil)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if needsExpansion {
                DisclosureGroup("查看完整命令") {
                    ScrollView([.horizontal, .vertical]) {
                        Text(command)
                            .font(.system(size: max(12, fontSize - 1), design: .monospaced))
                            .fixedSize(horizontal: true, vertical: true)
                            .textSelection(.enabled)
                            .padding(.vertical, 5)
                    }
                    .frame(maxHeight: 160)
                }
                .font(.system(size: max(12, fontSize - 1)))
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AICommandConfirmationCard: View {
    let proposal: ProposedShellCommand
    var fontSize: Double = 14
    /// Receives the optional sudo password the user typed in this card.
    var onApprove: (String?) -> Void
    var onReject: () -> Void

    @State private var sudoPassword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("等待你确认执行", systemImage: "questionmark.shield.fill")
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.orange)
            Text(proposal.purpose)
                .font(.system(size: fontSize))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Label(proposal.targetName, systemImage: "terminal")
                Spacer(minLength: 6)
                Text(proposal.delivery.title)
            }
            .font(.system(size: max(12, fontSize - 1)))
            .foregroundStyle(.secondary)
            AICommandPreview(command: proposal.command, fontSize: fontSize)
            if proposal.requiresSudoPassword {
                VStack(alignment: .leading, spacing: 4) {
                    SecureField("sudo 密码（可留空）", text: $sudoPassword)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("ai.command.sudoPassword")
                    Text(proposal.delivery == .background
                        ? "后台执行需要密码才能完成；密码只在本次任务内保留，不写入记录。"
                        : "留空则在终端里自行输入，应用不会读取它；填入后会在密码提示出现时自动送入，只保留在本次任务内。")
                        .font(.system(size: max(11, fontSize - 2)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button("允许执行") { onApprove(sudoPassword.isEmpty ? nil : sudoPassword) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ai.command.approve")
                Button("拒绝", action: onReject)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ai.command.reject")
            }
            .controlSize(.regular)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.4)) }
        .accessibilityIdentifier("ai.command.confirmation")
    }
}

struct AICommandOutputCard: View {
    let presentation: AICommandResultPresentation
    var fontSize: Double = 14
    @State private var expanded = false

    private var statusColor: Color {
        switch presentation.status {
        case .completed: .green
        case .failed, .timedOut, .unknown: .orange
        case .information: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(presentation.purpose ?? "工具结果")
                    .font(.system(size: fontSize, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(presentation.status.title)
                    .font(.system(size: max(12, fontSize - 1), weight: .medium))
                    .foregroundStyle(statusColor)
                    .fixedSize()
            }
            if presentation.isPartial {
                Text("日志有省略")
                    .font(.system(size: max(12, fontSize - 1))).foregroundStyle(.secondary)
            }
            DisclosureGroup("命令与运行日志", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if let command = presentation.command { AICommandPreview(command: command, fontSize: fontSize) }
                    ScrollView([.horizontal, .vertical]) {
                        Text(presentation.output.isEmpty ? "没有输出。" : presentation.output)
                            .font(.system(size: max(12, fontSize - 1), design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.vertical, 5)
                    }
                    .frame(maxHeight: 240)
                }
                .padding(.top, 5)
            }
            .font(.system(size: max(12, fontSize - 1)))
        }
        .padding(11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("ai.command.result")
    }
}
