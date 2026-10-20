# 桟橋 (Zhanqiao / SwiftTerminal)

<p align="center">
  <strong>macOS ネイティブ・ターミナル ＆ AI オペレーション・ワークスペース</strong>
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

## 概要

**桟橋（Zhanqiao / SwiftTerminal）** は、Swift 6 および SwiftUI / AppKit で開発された macOS 向けネイティブ・ターミナルアプリケーションです。

日々の開発業務やサーバー運用・保守作業を行うエンジニア向けに設計されており、コマンドラインによる端末操作を主軸としつつ、macOS 標準の OpenSSH セッション管理、明確な実行境界を備えた AI オペレーション支援、ローカルと SFTP に対応したデュアルエンジン・ファイルブラウザ、そしてネイティブ SMB 共有マウントを一元化して操作できます。

macOS の Human Interface Guidelines（HIG）に準拠した自然な UI を備え、余計な装飾を排した軽量設計となっています。認証情報はすべてローカルに厳格に分離保存され、外部へのテレメトリ送信や独自のクラウド依存は一切ありません。

---

**ダウンロード：** [GitHub Releases の最新版](https://github.com/jiliang6666/AI-shell/releases/latest)

## 主な機能

### 1. ネイティブ・ターミナル体験と精確なコマンド編集
- **高速 PTY レンダリング**：SwiftTerm エミュレーションライブラリと macOS の POSIX 仮想端末（PTY）を採用（デフォルトは `/bin/zsh`）。高リフレッシュレート環境でも滑らかな描画と正確なタイポグラフィを提供します。
- **OSC 133 セマンティックプロンプト解析**：Application Support 内の独立したブートストラップスクリプトからプロンプトマーカーを読み込むため、**ユーザーの `~/.zshrc` や dotfiles を直接書き換えたり汚染したりしません**。
- **現在入力中コマンドのクリック位置へのカーソル直接移動**：zsh の ZLE `CURSOR` 機構と連携し、現在編集中のコマンド入力行をクリックするだけで、入力カーソルをクリックした文字位置へ直接移動させます。日本語・全角文字（CJK）、単語の折り返し、複数行編集にも対応。過去の実行ログ領域やフルスクリーンプログラム（`vim`、`less`、`top` など）では、従来の範囲選択やアプリ独自の標準マウス操作が保持されます。
- **ワークスペースとウィンドウ操作**：タブ管理（`⌘T`）、仕切り線をドラッグ可能な分割表示（Split View）、ターミナル出力の検索とジャンプ（`⌘F` / `⌘G` / `⇧⌘G`）、画面消去（`⌘K`）、サイドバー開閉（`⌃⌘S`）。最後のタブを閉じてもウィンドウを保持したまま新規シェルを再起動し、ウィンドウを閉じても Dock に常駐します。
- **外観と環境設定**：フォントサイズ、カーソル形状（ブロック、下線、縦棒、プログラム指定）、スクロールバック行数、厳選されたカラーテーマ（システム連動、Nord、Dracula、Solarized Dark など）を自由にカスタマイズ可能です。

### 2. 実行境界を備えた AI オペレーション支援
- **オープンなモデル互換性**：標準的な Chat Completions API（OpenAI、DeepSeek、ローカルの Ollama / vLLM など）に幅広く対応。Server-Sent Events（SSE）によるストリーミング出力、リアルタイム Markdown レンダリング、折りたたみ可能なコードブロック表示を備えています。
- **ターミナルおよびファイルのコンテキスト引用**：ツールバーの「引用」操作により、選択中のターミナル出力やファイルの内容を対象識別ラベル付きで AI プロンプトに即座に組み込めます。
- **ローカルと SSH で独立記憶される 3 段階の実行権限**：
  - **閲覧のみ（Read Only）**：メタデータの参照および安全なホワイトリスト探査コマンドのみを許可。
  - **ターミナル連動（Terminal Only）**：接続中のターミナルセッション上で承認済みコマンドを自動実行し、出力を追跡。
  - **完全アクセス（Full Access）**：安全なバックグラウンド実行を許可（ホストおよびシステムのセキュリティ境界内）。
- **安全境界と操作確認カード**：
  - 安全な読み取り専用システム探査（`system`、`disk`、`docker`、`services` など）は自動で実行して結果を解析；
  - ファイル変更やシステム設定の書き換えを伴うコマンドは、実行前に**対象ホスト、作業ディレクトリ、実行されるシェルコマンド全文、および操作目的**を明記した確認カードを表示し、ユーザーの明示的な承認を待って実行；
  - `sudo` による昇格が必要な場合、独立したパスワード入力欄で一時的にメモリ保持し、タスク完了時に即座に破棄（ディスクには一切保存されません）；
  - トークン上限によるコンテキスト溢れを検知した際は履歴を自動要約して再試行し、パラメータが不明瞭な場合は `ask_user` を通じて対話形式で確認します。
- **マルチチャネル実行証明機構（`TerminalProofBox`）**：
  - OSC マーカー、ウィンドウタイトルのノンス（Nonce）、ステータスファイルを用いて実行完了および終了コード（Exit Code）を確実に捕捉；
  - 1 コマンドあたり 512 KiB の出力上限と 180 秒のタイムアウト制御を設け、プロセスのハングや暴走によるセッション停止を防止します。

### 3. 署名検証付きアプリ更新
- Sparkle 2 と EdDSA で Release パッケージを検証します。「設定 → 更新」から手動確認または定期確認を有効にできます。
- 公開 GitHub Releases の更新フィードを使い、署名検証後にインストールを案内します。

### 4. OpenSSH ホスト管理とセキュア接続
- **macOS 標準 OpenSSH の採用**：システムの OpenSSH バイナリを活用し、既知のホスト鍵（`known_hosts`）を厳格に照合して中間者攻撃を防止。
- **セッション重複防止ガード**：登録済みホストを選択した際、既にアクティブなターミナルが存在すれば自動的にその画面へ切り替え、無駄な多重接続を防ぎます。
- **接続プロセスの可視化**：名前解決、TCP ハンドシェイク、ホスト鍵確認、認証の各ステージを段階的に表示。
- **ホストのグループ分けと検索**：タグ、環境グループ、ポート、接続ユーザー名による分類とインクリメンタル検索に対応。
- **認証情報の分離保存**：ホスト構成とパスワードを物理的に分離し、ディレクトリ権限 `0700`、ファイル権限 `0600` で保護。OpenSSH askpass メカニズムを通じて安全に渡されます。

### 5. デュアルエンジン・ファイルブラウザと Finder 連携
- **統一されたファイル操作**：ローカルファイルシステムとリモートサーバーの SFTP を同一の洗練されたツリービューで操作可能。階層展開、並び替え、絞り込み検索をサポート。
- **テキストプレビューと簡易エディタ**：コードや設定ファイルをその場でプレビューでき、軽量エディタで直接編集して即座に対象ホストへ反映可能。
- **安全な削除ポリシー**：ディレクトリの削除は空ディレクトリのみに制限。誤操作による致命的なデータ消失を防ぐため、再帰的強制削除は禁止されています。
- **Finder サービス連携**：macOS のシステムサービス「桟橋でフォルダを開く」を登録。Finder でフォルダを右クリックするだけで、対象ディレクトリを作業場所として桟橋を素早く開くことができます。

### 6. ネイティブ SMB 共有マウント管理
- **`mount_smbfs` コーディネーター**：NAS やファイルサーバーの SMB 共有設定（ホスト、共有名、ユーザー名、パスワード、マウント先）を一元管理。
- **ステータス検知と排他制御**：マウント状態を監視し、ビジーロックによりマウント・アンマウント・編集時の競合を未然に防止します。

### 7. パラメータ付き定型コマンドライブラリ
- **`{{パラメータ名}}` テンプレート構文**：よく使うデプロイやトラブルシューティング用コマンドをテンプレートとして登録。
- **安全な引数エスケープと事前確認**：実行時に入力フォームからパラメータ値を指定し、展開後のコマンドを事前プレビュー。各パラメータはシェル引数として安全にエスケープ処理されるため、意図しないコマンドインジェクションを防止します。

---

## ショートカット一覧

| ショートカット | 機能説明 |
|---|---|
| `⌘T` | 新しいターミナルタブを開く |
| `⌘W` | 現在のタブを閉じる（最後のタブではウィンドウを維持してシェルを再起動） |
| `⌘F` | ターミナル検索バーを表示 |
| `⌘G` / `⇧⌘G` | 次の検索結果 / 前の検索結果へジャンプ |
| `⌘K` | ターミナルの表示画面をクリア |
| `⌃⌘S` | 左サイドバーの表示 / 非表示を切り替え |
| `⌥⌘A` | 右 AI アシスタントパネルの表示 / 非表示を切り替え |
| `⌘,` | 環境設定ウィンドウを開く |

---

## アーキテクチャ構成

```text
┌────────────────────────────────────────────────────────────────────────┐
│                        SwiftTerminal (桟橋 App)                        │
├──────────────────┬─────────────────────────────────┬───────────────────┤
│   左サイドバー   │        中央ターミナル・領域     │    右 AI パネル   │
│                  │                                 │                   │
│  - ローカル端末  │  ┌───────────────────────────┐  │  - ストリーミング │
│  - SSH ホスト    │  │ SwiftTerm (PTY エンジン)  │  │  - コンテキスト引用│
│  - ファイル/SFTP │  │ OSC 133 プロンプト制御    │  │  - 3段階実行権限  │
│  - SMB マウント  │  │ ZLE CURSOR クリック移動   │  │  - 安全確認カード │
│  - コマンド登録  │  │ 512KB / 180s タイムアウト │  │  - sudo 一時昇格  │
│  - 実行履歴      │  └───────────────────────────┘  │                   │
└──────────────────┴─────────────────────────────────┴───────────────────┘
         │                          │                          │
         ▼                          ▼                          ▼
 ┌───────────────┐          ┌───────────────┐          ┌───────────────┐
 │ macOS OpenSSH │          │ macOS カーネル│          │ ローカル安全  │
 │ & SFTP クライ │          │  mount_smbfs  │          │ SQLite (0600) │
 └───────────────┘          └───────────────┘          └───────────────┘
```

### 主要ソースコード構成

```text
SwiftTerminal/Sources/SwiftTerminal/
├── SwiftTerminalApp.swift          # アプリケーション起点、ウィンドウ管理、メニュー定義
├── TerminalWorkspace.swift         # ルートワークスペース、レイアウト分割、タブ管理
├── LocalTerminalView.swift         # SwiftTerm ラッパー、PTY 通信、OSC 133 状態遷移とカーソル制御
├── TerminalCommandDriver.swift     # コマンド実行制御、ノンス管理、TerminalProofBox による結果検証
├── ModelAIService.swift            # Chat Completions クライアント、SSE 解析、トークン使用量追跡
├── AIPermissionPolicy.swift        # 3段階権限判定および安全探査コマンドのホワイトリスト制御
├── AssistantPanel.swift            # AI パネル UI、操作確認カード、対話型質問カード
├── SSHHost.swift                   # SSH ホストモデル、認証情報の分離保存、鍵指紋管理
├── SSHHostListView.swift           # ホスト一覧、ステータスバッジ、接続フロー制御
├── FileBrowserPanel.swift          # ローカルおよび SFTP 対応のデュアルファイルツリー＆エディタ
├── SMBMountCoordinator.swift       # mount_smbfs 制御、マウント状態監視、ビジー排他制御
├── FinderFolderService.swift       # macOS システムサービス登録（「桟橋でフォルダを開く」）
├── TerminalAppearance.swift        # テーマカラー（Nord, Dracula, Solarized 等）およびフォント設定
└── WorkspaceData.swift             # 定型コマンド、パラメータ展開エスケープ、履歴管理
```

---

## ローカルデータ保存とセキュリティ

桟橋は**「データはローカルに完結し、最小限の権限で保護する」**という原則を徹底しています：

| 保存データ | 保存先パス | 権限およびセキュリティ方針 |
|---|---|---|
| **AI モデル設定 ＆ API キー** | `~/Library/Application Support/SwiftTerminal/model-library.sqlite3` | ディレクトリ `0700`、ファイル `0600`。平文認証情報はローカルにのみ保存され、`.app` には含まれません。 |
| **SSH ホスト設定** | `~/Library/Application Support/SwiftTerminal/ssh_hosts.json` | 権限 `0600`。接続先定義とメタデータを保持（パスワードとは別管理）。 |
| **SSH 接続パスワード** | `~/Library/Application Support/SwiftTerminal/credentials/` | 権限 `0600`。接続時にのみ OpenSSH askpass 経由で安全に読み込まれます。 |
| **ワークスペース・定型文** | `~/Library/Application Support/SwiftTerminal/workspace_data.json` | 権限 `0600`。登録コマンドテンプレート、SMB 設定、各種設定を保持。 |
| **ブートストラップスクリプト** | `~/Library/Application Support/SwiftTerminal/bootstrap/` | アプリ専用スクリプト。OSC 133 を動的読み込みし、ユーザーの標準設定は改変しません。 |

> [!NOTE]
> ファイルシステム権限（`0700` / `0600`）により、同一端末内の他の低権限プロセスから認証情報を保護しています。暗号化されていない一般的なパブリッククラウド同期ディレクトリに当該パスをそのまま配置しないようご注意ください。

---

## ビルド・テスト・パッケージング

### 動作要件
- macOS 14.0 (Sonoma) 以降
- Xcode 16.0+ または対応する Command Line Tools
- Swift 6.0 ツールチェーン

### 1. 開発用起動

```sh
cd SwiftTerminal
swift run
```

### 2. 単体テストの実行

iCloud Drive 等で同期されているフォルダ（`Documents` や `Desktop`）内で作業する場合、macOS Finder が付与する拡張属性（`com.apple.FinderInfo`）によりリソースバンドルのコード署名でエラーが発生することがあります。テスト時は独立した一時ディレクトリを指定して実行してください：

```sh
BUILD_SCRATCH_PATH=/private/tmp/zhanqiao-build \
  swift test --package-path SwiftTerminal --scratch-path /private/tmp/zhanqiao-build
```

### 3. スタンドアロン `.app` のビルド

リポジトリ内に自動パッケージングおよびアイコン生成スクリプトが用意されています：

```sh
./SwiftTerminal/scripts/package-app.sh
```

- 生成された成果物は `SwiftTerminal/build/桟桥.app` に出力されます。
- スクリプトは Release ビルドを行い、シンボルテーブルを削除（`strip -S -x`）し、SwiftTerm のリソースバンドルを組み込み、`.icns` アイコンを動的に生成して `Info.plist` を構成します。
- **Apple Developer ID 署名と公証（任意）**：
  ```sh
  SIGN_IDENTITY="Developer ID Application: Your Name (TeamID)" \
  NOTARY_PROFILE="your-notarytool-profile" \
  NOTARIZE=1 \
  ./SwiftTerminal/scripts/package-app.sh
  ```

---

## ライセンス

本プロジェクトは MIT ライセンス のもとで公開されています。サードパーティ製ライブラリはそれぞれのライセンスに従います：
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT)
