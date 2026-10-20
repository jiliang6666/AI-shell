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
