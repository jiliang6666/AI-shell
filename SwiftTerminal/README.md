# 栈桥 (SwiftTerminal) - Swift Package

> 本目录为栈桥（SwiftTerminal）的核心 SwiftPM 项目源码。
> 完整项目介绍与多语言文档请参见仓库根目录：
> [简体中文](../README.md) | [English](../README_en.md) | [日本語](../README_ja.md)

---

## 快速开发与调试

### 编译与启动

```sh
# 在当前目录下直接编译并启动应用
swift run
```

### 运行单元测试

如果在同步目录中运行，建议指定独立的 scratch 路径，避免 Finder 扩展属性导致 codesign 失败：

```sh
BUILD_SCRATCH_PATH=/private/tmp/zhanqiao-build \
  swift test --scratch-path /private/tmp/zhanqiao-build
```

### 打包本地独立 `.app`

```sh
./scripts/package-app.sh
```

- 打包产物位于 `build/栈桥.app`；
- 脚本会自动剥离符号表（`strip -S -x`）、内置 SwiftTerm 资源包、调用 `scripts/generate-icon.swift` 生成极简扁平风格 AppIcon（包含各分辨率尺寸）、并组装 `Info.plist`（包含本地网络访问描述与访达服务）；
- 支持通过环境变量指定自定义输出路径（`APP_OUTPUT`）、代码签名身份（`SIGN_IDENTITY`）及公证配置（`NOTARY_PROFILE`）。

---

## AI 文件扫描限制

AI 排查磁盘占用、寻找软件或准备软件搬运时，应先读取磁盘、Docker、包管理器或系统索引的元数据，再根据证据选择具体目录。扫描前说明已有线索、目录范围、名称/类型/内容筛选条件、实际遍历边界和停止条件；命中目标或证据足够后停止，再根据已有结果决定下一步。

执行器会在派发前拒绝识别到的全盘、整个主目录以及无界的大目录递归扫描；通过 SSH、sudo、`xargs`、命令替换或 Shell 包装执行也需满足相同条件。无法确认动态执行的实际目标时会拒绝，而不是放行。`head`、`tail`、`du --max-depth` 等输出限制不能代替实际遍历边界，也不能用执行超时替代扫描计划。

终端内扫描的相对目标不会按默认或启动目录推断，必须指定绝对目标；后台进程只在明确设置工作目录时才解析相对目标。`find` 需要有效的非负 `-maxdepth` 和筛选条件；`-prune` 本身不算遍历边界。常见无扩展名文件（如 `Makefile`、`Dockerfile`、`Gemfile`、`LICENSE`）按文件处理。策略会将 macOS 的 `/System/Volumes/Data/...` 已知别名规范化到对应路径，不解析任意符号链接；这是范围防护启发式，不是安全沙箱。

扫描策略不增加自动超时，有条件的扫描仍等待命令完成、连接中断或用户主动停止。该策略覆盖 AI 生成和 AI 调用的保存命令，不改变用户手动输入终端命令的行为。正常构建、安装和实际文件搬运继续按任务进度运行。

---

## 常用快捷键

- `⌘T`：新建终端标签
- `⌘W`：关闭当前终端标签（保留主窗口并重建默认 Shell）
- `⌘F`：打开终端搜索栏
- `⌘G` / `⇧⌘G`：下一个 / 上一个搜索匹配项
- `⌘K`：清除当前屏幕回显
- `⌃⌘S`：折叠 / 展开侧边栏
- `⌥⌘A`：折叠 / 展开 AI 助手面板
- `⌘,`：打开系统偏好设置

---

## 关键文档索引

- [软件更新与发布流程](docs/软件更新.md)
