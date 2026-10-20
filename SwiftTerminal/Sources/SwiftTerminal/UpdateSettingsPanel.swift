import SwiftUI

struct UpdateSettingsPanel: View {
    @ObservedObject var updater: UpdateController

    var body: some View {
        Form {
            Section("软件更新") {
                Toggle(
                    "自动检查更新",
                    isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    )
                )
                .disabled(!updater.isConfigured)

                Text(updater.isConfigured
                     ? "定期检查公开 Releases。更新包会先验证签名；发现新版本后，由 Sparkle 提示下载和安装。"
                     : "配置公开 GitHub 仓库与更新签名公钥后即可启用。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("立即检查") { updater.checkForUpdates() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!updater.isConfigured)
                    Text(updater.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("版本") {
                LabeledContent("当前版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知")
                Text("更新源为同一公开仓库中的 Releases，自动更新需要网络连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(18)
    }
}
