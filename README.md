# 栈桥 (SwiftTerminal)

<p align="center">
  <strong>面向 macOS 的原生终端与 AI 运维工作台</strong>
</p>

<p align="center">
  <a href="README.md">简体中文</a> |
  <a href="README_en.md">English</a> |
  <a href="README_ja.md">日本語</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014.0%2B-blue.svg" alt="Platform: macOS 14.0+" />
  <img src="https://img.shields.io/badge/Language-Swift%206-orange.svg" alt="Language: Swift 6" />
  <img src="https://img.shields.io/badge/UI-SwiftUI%20%2F%20AppKit-red.svg" alt="UI: SwiftUI / AppKit" />
  <img src="https://img.shields.io/badge/Engine-SwiftTerm-lightgrey.svg" alt="Engine: SwiftTerm" />
  <img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License" />
</p>

---

## 项目简介

**栈桥（SwiftTerminal）** 是一款基于 Swift 6 与 SwiftUI / AppKit 开发的 macOS 原生终端应用。

它针对工程师的日常开发与服务器运维场景设计，以终端命令行交互为主体，深度结合原生 OpenSSH 会话管理、带执行边界与权限控制的 AI 运维调度、本地与远程 SFTP 双引擎文件浏览器、以及原生 SMB 网络挂载。

应用严格遵循 macOS 人机界面规范，界面轻量无冗余，核心凭证采用本地隔离存储，不设外部遥测或第三方云端依赖。

---

**下载：** [GitHub Releases 最新版本](https://github.com/jiliang6666/AI-shell/releases/latest)

## 核心特性

### 1. 原生终端体验与智能命令编辑
- **原生渲染与进程管理**：基于 SwiftTerm 终端仿真库构建，通过系统 POSIX PTY 驱动本地 Shell（默认 `/bin/zsh`），提供流畅的高刷新率渲染与文本排版。
- **OSC 133 语义化提示符解析**：在 Application Support 目录中放置独立引导脚本注入提示符标记，**不修改、不污染用户的 `~/.zshrc` 或 dotfiles**。
- **当前命令鼠标单击精准定位光标**：借助 zsh ZLE 的 `CURSOR` 机制，在当前正在编辑的命令区域单击鼠标，即可精准将输入光标移至点击处。支持中英文宽字符对齐、自动换行与多行编辑；历史输出区域和全屏程序（`vim`、`less`、`top` 等）严格保留原有的文本选择或内置鼠标协议。
- **工作区与窗口管理**：支持多标签页（`⌘T`）、分屏对照浏览、查找与跳转（`⌘F` / `⌘G`）、清屏（`⌘K`）、侧边栏收折（`⌃⌘S`）。关闭最后一个标签保留窗口并自动重开默认 Shell，关闭窗口后驻留 Dock。
- **外观与终端偏好**：支持自定义字体大小、光标形状（块状、下划线、竖条、程序指定）、回滚行数以及预设主题（跟随系统、Nord、Dracula、Solarized Dark 等）。

### 2. 安全受控的 AI 运维与命令执行
- **兼容开放的模型生态**：适配标准 Chat Completions API 协议（支持 DeepSeek、OpenAI、自建 Ollama / vLLM 等），支持 SSE 流式返回、实时 Markdown 解析排版与代码块高亮。
- **终端与文件上下文感知**：工具栏提供“引用到 AI”，选中的终端命令输出或文件片段可带目标来源标签快速注入对话提示词。
- **三档全局权限记忆（本机 / SSH 独立）**：
  - **仅查看（Read Only）**：仅允许读取元数据及白名单安全探针。
  - **终端档（Terminal Only）**：在绑定的终端中自动执行已授权命令并捕获回显。
  - **完全权限（Full Access）**：支持受限的后台执行通道，仍遵循主机与系统权限约束。
- **安全边界与操作确认卡**：
  - 白名单只读探针（`system`、`disk`、`docker`、`services`）自动快速执行并分析结果；
  - 任意修改系统状态或破坏性命令，均必须在面板弹出确认卡，明确呈现**目标主机、执行工作目录、完整命令及操作意图**，待人工确认后才可执行；
  - 遇到需要 `sudo` 提权的场景，通过独立安全输入框临时暂存密码，任务结束后立即销毁，不写入任何磁盘配置；
  - 每次上下文溢出时自动精简会话历史并重试，支持通过 `ask_user` 主动向用户提问澄清参数。
- **多通道终端执行证明机制（`TerminalProofBox`）**：
  - 通过 OSC 状态标记、窗口标题随机数 Nonce 和状态文件闭环校验命令完成状态与退出码（Exit Code）；
  - 单次命令输出上限 512 KiB，默认设置 180 秒超时熔断，防止命令无回显挂起阻塞任务。

### 3. 签名验证的软件更新
- 基于 Sparkle 2 与 EdDSA 验证 Release 更新包，可在“设置 → 更新”手动检查或开启定期检查。
- 更新源使用公开 GitHub Release，应用会验证签名后再提示安装。

### 4. SSH 主机管理与安全连接
- **原生 OpenSSH 接入**：基于系统内置 OpenSSH 命令栈，连接前严格核验已知主机指纹（`known_hosts`），防范中间人劫持。
- **防重复会话守卫**：同一台 SSH 主机在工作区内始终复用活动终端。点击已有主机直接切换聚焦，无需重复登录建立冗余连接。
- **连接过程可视化**：分阶段展示 DNS 解析、TCP 握手、指纹校验及身份认证进度。
- **主机分组与搜索**：支持主机标签、环境分组、端口/用户名设置，支持快速过滤查找。
- **凭证安全隔离**：主机元数据与连接密码物理分离存储，目录权限设为 `0700`，凭证与配置文件设为 `0600`，通过 OpenSSH askpass 安全机制按需传递。

### 5. 双引擎文件管理与访达集成
- **统一操作体验**：本地文件系统与远程服务器 SFTP 共享一套清晰的浏览器界面，支持按层级展开、文件排序与快速检索。
- **内置查看与编辑**：双击即可快速预览文本文件，内置轻量级代码与文本编辑器，支持在线修改并直接保存同步。
- **安全防误删约束**：删除操作仅允许针对空目录，严格禁止非空目录的隐式递归删除，防止误操作导致数据丢失。
- **访达右键服务集成**：注册系统级服务菜单项“在栈桥中打开文件夹”，在访达（Finder）中选中任意文件夹即可一键直达栈桥工作台。

### 6. SMB 共享挂载管理
- **原生 `mount_smbfs` 协调器**：统一管理局域网 NAS 或服务器共享目录配置（主机、共享名、用户名、密码与挂载路径）。
- **状态感知与挂载锁**：实时侦测挂载点活跃状态，提供繁忙状态锁避免并发冲突，支持在界面中一键挂载与卸载。

### 7. 参数化快捷命令库
- **`{{参数名}}` 模板支持**：将常用排障与部署命令沉淀为模板库。
- **安全引数转义与预览**：运行时填入动态参数，执行前弹出完整命令渲染预览，各参数严格按单个 Shell 引数安全转义，防止意外注入。

---

## 快捷键速查

| 快捷键 | 功能说明 |
|---|---|
| `⌘T` | 新建终端标签页 |
| `⌘W` | 关闭当前标签页（最后一个标签保留窗口） |
| `⌘F` | 打开终端搜索面板 |
| `⌘G` / `⇧⌘G` | 查找下一个 / 上一个匹配项 |
| `⌘K` | 清除当前终端屏幕内容 |
| `⌃⌘S` | 展开 / 收起左侧边栏 |
| `⌥⌘A` | 展开 / 收起右侧 AI 助手面板 |
| `⌘,` | 打开系统偏好设置窗口 |

---

## 技术架构

```text
┌────────────────────────────────────────────────────────────────────────┐
│                        SwiftTerminal (栈桥 App)                        │
├──────────────────┬─────────────────────────────────┬───────────────────┤
│    左侧导航栏    │         中央终端与工作区        │    右侧 AI 面板   │
│                  │                                 │                   │
│  - 本机终端会话  │  ┌───────────────────────────┐  │  - 模型流式对话   │
│  - SSH 主机资产  │  │ SwiftTerm (PTY 引擎)      │  │  - 上下文引用卡片 │
│  - 文件/SFTP 浏览│  │ OSC 133 语义化命令标记    │  │  - 权限档位切换   │
│  - SMB 挂载管理  │  │ ZLE CURSOR 鼠标单击光标定位│  │  - 待执行命令确认 │
│  - 常用命令模板  │  │ 512KB / 180s 超时熔断保护 │  │  - sudo 临时提权  │
│  - 执行历史记录  │  └───────────────────────────┘  │                   │
└──────────────────┴─────────────────────────────────┴───────────────────┘
         │                          │                          │
         ▼                          ▼                          ▼
 ┌───────────────┐          ┌───────────────┐          ┌───────────────┐
 │ 系统 OpenSSH  │          │   系统内核    │          │ 本地安全存储  │
 │ & SFTP 客户端 │          │  mount_smbfs  │          │ (SQLite/0600) │
 └───────────────┘          └───────────────┘          └───────────────┘
```

### 关键工程模块划分

```text
SwiftTerminal/Sources/SwiftTerminal/
├── SwiftTerminalApp.swift          # 应用主入口、窗口管理、全局菜单与快捷键
├── TerminalWorkspace.swift         # 工作区主视图、多标签协调与分屏控制
├── LocalTerminalView.swift         # SwiftTerm 包装器、PTY 通信、OSC 133 状态机与光标映射
├── TerminalCommandDriver.swift     # 命令调度器、随机数 Nonce 与执行证明校验 (TerminalProofBox)
├── ModelAIService.swift            # Chat Completions 协议交互、SSE 流解析与 Token 统计
├── AIPermissionPolicy.swift        # 三档全局权限判定与白名单自动放行逻辑
├── AssistantPanel.swift            # AI 助手界面、交互式操作确认卡、任务状态机
├── SSHHost.swift                   # SSH 实体模型、凭据隔离存储与主机指纹管理
├── SSHHostListView.swift           # 主机资产列表、分类展示与连接监控
├── FileBrowserPanel.swift          # 本地文件系统与 SFTP 双引擎文件浏览器
├── SMBMountCoordinator.swift       # 基于 mount_smbfs 的网络共享挂载协调器
├── FinderFolderService.swift       # macOS Services 系统服务注册与目录调起
├── TerminalAppearance.swift        # 终端外观配色（Nord, Dracula, Solarized 等）与字体设置
└── WorkspaceData.swift             # 快捷命令模板、参数渲染转义与历史记录存储
```

---

## 本地数据存储与安全设计

栈桥坚持**数据留存本地、权限严格最小化**的安全原则：

| 数据内容 | 存储位置与文件名 | 权限与安全性 |
|---|---|---|
| **AI 模型与 API Key** | `~/Library/Application Support/SwiftTerminal/model-library.sqlite3` | 目录 `0700`，数据库文件 `0600`。明文凭证仅留存本地，不打入 `.app` 分发包。 |
| **SSH 资产配置** | `~/Library/Application Support/SwiftTerminal/ssh_hosts.json` | 权限 `0600`，与密码凭据物理拆分存储。 |
| **SSH 独立密码** | `~/Library/Application Support/SwiftTerminal/credentials/` | 权限 `0600`，仅在连接发起时通过 OpenSSH askpass 安全通道加载。 |
| **工作区与模板** | `~/Library/Application Support/SwiftTerminal/workspace_data.json` | 权限 `0600`，保存常用命令模板、SMB 配置与偏好。 |
| **Shell 引导脚本** | `~/Library/Application Support/SwiftTerminal/bootstrap/` | 应用专有目录，动态加载 OSC 133 支持，不改动用户原生配置。 |

> [!NOTE]
> 为避免依赖外部黑盒，凭据与配置采用文件系统级严格权限（`0700` / `0600`）保障同用户下其它低权限进程的隔离。如需在多设备间同步，切勿直接将该目录纳入未加密的公共同步网盘。

---

## 编译、运行与打包

### 系统要求
- macOS 14.0 (Sonoma) 或更高版本
- Xcode 16.0+ 或配套 Command Line Tools
- Swift 6.0 工具链

### 1. 开发调试运行

在项目根目录下直接运行：

```sh
cd SwiftTerminal
swift run
```

### 2. 执行单元测试

如果工作区位于启用了 iCloud 同步的目录（如 `Documents` 或 `Desktop`），macOS Finder 自动写入的扩展属性（Extended Attributes）可能导致包签名报错。推荐指定临时编译目录运行测试：

```sh
BUILD_SCRATCH_PATH=/private/tmp/zhanqiao-build \
  swift test --package-path SwiftTerminal --scratch-path /private/tmp/zhanqiao-build
```

### 3. 打包生成独立的 `.app` 应用

项目内置了自动化打包与图标生成脚本：

```sh
./SwiftTerminal/scripts/package-app.sh
```

- 生成产物位于 `SwiftTerminal/build/栈桥.app`；
- 脚本会自动编译 Release 二进制文件、剥离符号表（`strip -S -x`）、编译内嵌资源包、动态生成 `.icns` 图标并装配 `Info.plist`；
- **分发签名与公证（可选）**：如果配置了 Apple 开发者证书，可通过环境变量传入签名身份与公证配置：
  ```sh
  SIGN_IDENTITY="Developer ID Application: Your Name (TeamID)" \
  NOTARY_PROFILE="your-notarytool-profile" \
  NOTARIZE=1 \
  ./SwiftTerminal/scripts/package-app.sh
  ```

---

## 许可证

本项目基于 MIT 协议开源。第三方依赖项遵循各自开源协议：
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT)
