import SwiftUI

struct SSHHostEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host: SSHHost
    @State private var error: String?
    let knownGroups: [String]
    let isNewHost: Bool
    let onSave: (SSHHost, Bool) throws -> Void

    init(
        host: SSHHost = SSHHost(name: "", address: "", username: ""),
        knownGroups: [String] = [],
        isNewHost: Bool = true,
        onSave: @escaping (SSHHost, Bool) throws -> Void
    ) {
        _host = State(initialValue: host)
        self.knownGroups = knownGroups
        self.isNewHost = isNewHost
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 540, height: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(isNewHost ? "新建 SSH 主机" : "编辑 SSH 主机")
                    .font(.headline)
                Text(host.address.isEmpty ? "填写主机地址、用户名和认证方式" : host.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var form: some View {
        Form {
            Section("连接") {
                TextField("名称", text: $host.name, prompt: Text("可选，默认显示地址"))
                TextField("主机地址", text: $host.address, prompt: Text("例如 192.168.1.10 或 server.example.com"))
                TextField("用户名", text: $host.username)
                TextField("端口", value: $host.port, format: .number)
                groupField
            }
            Section("AI 自动执行") {
                Picker("远端 Shell", selection: $host.remoteShell) {
                    Text("bash").tag("bash")
                    Text("zsh").tag("zsh")
                }
                Text("完成证明依赖 bash 或 zsh。其他 Shell 不用于 AI 自动执行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("认证") {
                Picker("认证方式", selection: $host.authentication) {
                    ForEach(SSHHost.Authentication.allCases) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                switch host.authentication {
                case .password:
                    SecureField("密码", text: $host.password)
                    Toggle("保存密码以便连接时自动使用", isOn: $host.savePassword)
                    Text("密码单独保存在本机凭据文件中（权限 600），不会写入主机资料、日志或模型请求。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .privateKey:
                    TextField("私钥路径", text: $host.privateKeyPath, prompt: Text("~/.ssh/id_ed25519"))
                    Text("使用系统 OpenSSH 连接；私钥口令由 ssh 自己提示，不会保存在应用内。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .agent:
                    Text("使用本机 ssh-agent 中已加载的密钥。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var groupField: some View {
        HStack {
            TextField("分组", text: $host.group, prompt: Text("可选，例如 生产环境"))
            if !knownGroups.isEmpty {
                Menu {
                    ForEach(knownGroups, id: \.self) { name in
                        Button(name) { host.group = name }
                    }
                    Divider()
                    Button("清除分组") { host.group = "" }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 18)
                .help("选择已有分组")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存并连接") { submit(connect: true) }
            Button("保存主机") { submit(connect: false) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func submit(connect: Bool) {
        host.name = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        host.address = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
        host.username = host.username.trimmingCharacters(in: .whitespacesAndNewlines)
        host.group = host.group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.address.isEmpty, !host.username.isEmpty, (1...65_535).contains(host.port) else {
            error = "请填写主机地址、用户名和 1–65535 之间的端口。"
            return
        }
        if host.authentication == .password && host.savePassword && host.password.isEmpty {
            error = "请填写密码，或关闭“保存密码”。"
            return
        }
        if host.authentication == .privateKey && host.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = "使用私钥认证时请填写私钥路径。"
            return
        }
        if !host.savePassword { host.password = "" }
        do {
            try onSave(host, connect)
            dismiss()
        } catch {
            self.error = "主机资料保存失败：\(error.localizedDescription)"
        }
    }
}
