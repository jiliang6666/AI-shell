# Zhanqiao (SwiftTerminal)

<p align="center">
  <strong>Native macOS Terminal & AI Operations Workspace</strong>
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

## Overview

**Zhanqiao (SwiftTerminal)** is a native macOS terminal application built with Swift 6 and SwiftUI / AppKit.

Designed for engineers, developers, and system administrators, Zhanqiao pairs a terminal command-line interface with native OpenSSH session management, boundary-enforced AI execution, dual-engine (Local & SFTP) file management, and native SMB share mounting.

It adheres to macOS Human Interface Guidelines, avoids unnecessary UI friction, keeps all credentials strictly in local storage, and introduces no telemetry or hidden cloud services.

---

**Download:** [Latest GitHub Release](https://github.com/jiliang6666/AI-shell/releases/latest)

## Key Features

### 1. Native Terminal Core & Precise Cursor Editing
- **High-Performance PTY Rendering**: Powered by the SwiftTerm emulation library and macOS POSIX pseudo-terminals (defaulting to `/bin/zsh`), offering smooth, high-refresh-rate text rendering.
- **OSC 133 Semantic Prompt Integration**: Injects semantic prompt markers via an isolated bootstrap script located in `~/Library/Application Support/SwiftTerminal/bootstrap/` — **without modifying, appending to, or polluting user `~/.zshrc` or dotfiles**.
- **Click-to-Position Cursor on Active Prompt**: Using Zsh Line Editor (ZLE) `CURSOR` mapping, clicking anywhere inside the active, unsubmitted command line moves the cursor directly to the clicked offset. Handles wide characters (CJK), word boundaries, wrapped lines, and multiline inputs. Historical terminal output and fullscreen programs (`vim`, `less`, `top`) retain standard text selection and native mouse handling.
- **Workspace Navigation**: Multitab support (`⌘T`), split-pane layout with draggable dividers, output search and navigation (`⌘F` / `⌘G` / `⇧⌘G`), screen clearing (`⌘K`), and collapsible sidebars (`⌃⌘S`). Closing the last tab retains the window and respawns a clean shell; closing the window keeps the app active in the Dock.
- **Appearance & Preferences**: Configurable font size, cursor styles (block, underline, bar, program-driven), scrollback buffer limit, and curated color palettes (Follow System, Nord, Dracula, Solarized Dark).

### 2. Guarded AI Operations & Command Driver
- **Open Model Compatibility**: Works with standard Chat Completions APIs (OpenAI, DeepSeek, local Ollama / vLLM, self-hosted endpoints). Supports Server-Sent Events (SSE) streaming, real-time Markdown formatting, and collapsible code blocks.
- **Terminal & File Context Quoting**: Use the "Quote Selection" toolbar action to attach active terminal outputs or file snippets directly into prompt turns with target identity badges.
- **Three-Tier Permission Policy (Local / SSH Scopes)**:
  - **Read Only**: Allows metadata queries and read-only inspection probes only.
  - **Terminal Only**: Automatically executes approved commands inside the bound interactive terminal session and captures output.
  - **Full Access**: Allows background and direct tool execution, constrained strictly by host and system security boundaries.
- **Explicit Confirmation & Safety Cards**:
  - Whitelisted safe diagnostic probes (`system`, `disk`, `docker`, `services`) run automatically to diagnose environments;
  - State-mutating, file-writing, or destructive commands trigger an interactive confirmation card detailing **target host, working directory, verbatim shell command, and intent** before execution;
  - Sudo passwords are entered via a dedicated, secure input field, retained only in-memory for the active task duration, and never written to disk;
  - Automatically compacts conversation context upon token overflow and retries; supports `ask_user` interaction when the assistant needs parameter clarification.
- **Multichannel Execution Proof (`TerminalProofBox`)**:
  - Tracks command lifecycle and exit status using OSC markers, nonce-tagged window titles, and status files to ensure reliable completion detection;
  - Enforces a 512 KiB output buffer cap and a 180-second timeout to prevent runaway or hung processes from locking the session.

### 3. Signed App Updates
- Uses Sparkle 2 with EdDSA verification for release packages. Check manually or enable periodic checks in **Settings → Updates**.
- Updates come from the public GitHub Releases feed and are verified before installation.

### 4. OpenSSH Host & Credential Management
- **System OpenSSH Integration**: Runs on Apple's built-in OpenSSH binary stack and strictly verifies host keys against `known_hosts` to prevent MITM attacks.
- **Session Deduplication**: Selecting an existing SSH host switches focus to its existing live terminal session instead of launching duplicate connections.
- **Connection Diagnostics**: Step-by-step progress display across name resolution, TCP handshake, host key verification, and authentication.
- **Host Grouping & Search**: Organize hosts by tags, groups, port, and user credentials; quickly filter hosts via live search.
- **Isolated Credential Security**: Host metadata and authentication secrets are stored separately in the Application Support directory (`0700` directory permissions, `0600` file permissions) and passed on-demand via an OpenSSH askpass helper.

### 5. Dual-Engine File Browser & Finder Integration
- **Unified Local & Remote Navigation**: Browse local filesystems and remote SFTP paths through the same hierarchy, with quick sorting and search.
- **Text Preview & In-App Editor**: Inspect code and configuration files with inline syntax preview, or edit and save changes directly back to the target host.
- **Safe Deletion Policy**: Restricts directory deletion to empty folders only. Rejects implicit recursive deletion to safeguard remote and local filesystems.
- **Finder Context Menu**: Implements the macOS system service `"Open Folder in Zhanqiao"`, allowing one-click navigation into any folder directly from Finder into a dedicated terminal workspace.

### 6. Native SMB Mount Coordinator
- **Integrated `mount_smbfs` Driver**: Configure and manage network shares (NAS, Samba servers, Windows file shares) with credentials and mount points.
- **Mount State & Conflict Guards**: Live status tracking and busy locks prevent race conditions during mount, unmount, and editor access.

### 7. Parameterized Command Templates
- **Template Syntax `{{param}}`**: Turn common deployment, health check, and debugging commands into reusable snippets.
- **Argument Escaping & Preview**: Prompts for parameter values at runtime, previews the interpolated command, and escapes each parameter safely as an isolated shell argument.

---

## Keyboard Shortcuts

| Shortcut | Description |
|---|---|
| `⌘T` | New terminal tab |
| `⌘W` | Close active tab (last tab resets shell and keeps window) |
| `⌘F` | Show terminal search bar |
| `⌘G` / `⇧⌘G` | Find next / previous match |
| `⌘K` | Clear visible terminal buffer |
| `⌃⌘S` | Toggle left sidebar visibility |
| `⌥⌘A` | Toggle right AI assistant panel |
| `⌘,` | Open Preferences window |

---

## Architecture Overview

```text
┌────────────────────────────────────────────────────────────────────────┐
│                        SwiftTerminal (Zhanqiao App)                    │
├──────────────────┬─────────────────────────────────┬───────────────────┤
│   Left Sidebar   │         Center Terminal         │    Right AI Bar   │
│                  │                                 │                   │
│  - Local Shells  │  ┌───────────────────────────┐  │  - SSE Streaming  │
│  - SSH Hosts     │  │ SwiftTerm (PTY Engine)    │  │  - Context Quotes │
│  - Files / SFTP  │  │ OSC 133 Semantic Markers  │  │  - Permission Tiers│
│  - SMB Mounts    │  │ ZLE CURSOR Click Mapping  │  │  - Safety Cards   │
│  - Snippets      │  │ 512KB / 180s Timeouts     │  │  - Sudo Elevation │
│  - History       │  └───────────────────────────┘  │                   │
└──────────────────┴─────────────────────────────────┴───────────────────┘
         │                          │                          │
         ▼                          ▼                          ▼
 ┌───────────────┐          ┌───────────────┐          ┌───────────────┐
 │ System OpenSSH│          │  macOS Kernel │          │ Local Secure  │
 │  & SFTP Engine│          │  mount_smbfs  │          │ SQLite (0600) │
 └───────────────┘          └───────────────┘          └───────────────┘
```

### Key Source Components

```text
SwiftTerminal/Sources/SwiftTerminal/
├── SwiftTerminalApp.swift          # App entry point, scene coordinator, window delegate, menu items
├── TerminalWorkspace.swift         # Root workspace view, layout splits, tab session policies
├── LocalTerminalView.swift         # SwiftTerm AppKit wrapper, PTY handling, OSC 133 state machine
├── TerminalCommandDriver.swift     # Command executor, nonce tracking, TerminalProofBox verification
├── ModelAIService.swift            # Chat Completions client, SSE parser, usage and cache stats
├── AIPermissionPolicy.swift        # Three-tier permission evaluator and inspection whitelisting
├── AssistantPanel.swift            # Chat interface, confirmation cards, interactive clarification
├── SSHHost.swift                   # Host data structures, credential management, askpass hooks
├── SSHHostListView.swift           # Sidebar SSH host listings, status badges, connection flows
├── FileBrowserPanel.swift          # Unified local and SFTP dual-engine file tree and editor
├── SMBMountCoordinator.swift       # mount_smbfs coordinator, busy states, mount / unmount actions
├── FinderFolderService.swift       # macOS Services provider ("Open Folder in Zhanqiao")
├── TerminalAppearance.swift        # Palette definitions (Nord, Dracula, Solarized) and font settings
└── WorkspaceData.swift             # Snippet storage, parameterized template interpolation, history
```

---

## Local Storage & Security Model

Zhanqiao keeps all state local and enforces POSIX-level permission boundaries:

| Data Asset | Path | Permissions & Security Policy |
|---|---|---|
| **AI Models & API Keys** | `~/Library/Application Support/SwiftTerminal/model-library.sqlite3` | Directory `0700`, database file `0600`. Not bundled into the compiled application. |
| **SSH Host Profiles** | `~/Library/Application Support/SwiftTerminal/ssh_hosts.json` | File `0600`. Contains network configurations and metadata; separated from passwords. |
| **SSH Passwords** | `~/Library/Application Support/SwiftTerminal/credentials/` | Files `0600`. Accessed strictly through the OpenSSH askpass helper at connection time. |
| **Workspace & Snippets** | `~/Library/Application Support/SwiftTerminal/workspace_data.json` | File `0600`. Contains saved templates, SMB configurations, and preferences. |
| **Bootstrap Scripts** | `~/Library/Application Support/SwiftTerminal/bootstrap/` | Private app directory containing the non-intrusive OSC 133 zsh hook loader. |

> [!NOTE]
> Filesystem permissions (`0700` / `0600`) protect credentials against other low-privileged user-space processes on the same machine. Do not place this directory onto an unencrypted cloud sync drive without proper volume-level encryption.

---

## Build, Test & Packaging

### Prerequisites
- macOS 14.0 (Sonoma) or newer
- Xcode 16.0+ or Command Line Tools
- Swift 6.0 toolchain

### 1. Run for Local Development

```sh
cd SwiftTerminal
swift run
```

### 2. Execute Unit Tests

When working inside a directory synced by iCloud or cloud storage (e.g., `Documents` or `Desktop`), Finder metadata and extended attributes (`com.apple.FinderInfo`) can interfere with SwiftPM bundle codesigning. Use an isolated scratch path when testing:

```sh
BUILD_SCRATCH_PATH=/private/tmp/zhanqiao-build \
  swift test --package-path SwiftTerminal --scratch-path /private/tmp/zhanqiao-build
```

### 3. Package as a Standalone `.app`

The repository includes an automated build and icon assembly script:

```sh
./SwiftTerminal/scripts/package-app.sh
```

- The compiled bundle is output to `SwiftTerminal/build/栈桥.app`.
- Strips debug symbols (`strip -S -x`), copies the SwiftTerm resources bundle, renders the `.icns` icon dynamically, and sets up `Info.plist`.
- **Developer ID Signing & Notarization (Optional)**:
  ```sh
  SIGN_IDENTITY="Developer ID Application: Your Name (TeamID)" \
  NOTARY_PROFILE="your-notarytool-profile" \
  NOTARIZE=1 \
  ./SwiftTerminal/scripts/package-app.sh
  ```

---

## License

Zhanqiao is open source under the MIT License. Third-party dependencies are licensed under their respective terms:
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT)
