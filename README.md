# MacBase

Mac 原生的棋库应用(ChessBase 的 Mac 替代)。SwiftUI 界面 + Rust 核心
(走法生成、PGN 变着树、SQLite 棋库、开局树),UCI 引擎(内置 Stockfish)
子进程分析。

文档:[架构](docs/ARCHITECTURE.md) ·
[着法面板设计](docs/NOTATION-VIEW.md) ·
[路线图](docs/ROADMAP.md) · 交接说明 [AGENTS.md](AGENTS.md)

## 结构

- `core/` — Rust crate(shakmaty + pgn-reader + rusqlite),通过 UniFFI
  导出给 Swift。`cargo test` 跑全部核心测试(perft、PGN round-trip)。
- `app/` — SwiftUI macOS 应用。Xcode 工程由 XcodeGen 从 `app/project.yml`
  生成(`.xcodeproj` 不进 git)。
- `scripts/build-core.sh` — 编译 Rust 静态库并重新生成 Swift 绑定到
  `app/Generated/`(Xcode 构建的 pre-build phase 也会跑它)。
- `fixtures/` — 测试用真实 PGN(含深层嵌套变着)。

## 首次构建

1. App Store 安装 Xcode,启动一次接受许可,然后:
   `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
2. `brew install xcodegen`
3. `xcodegen -s app/project.yml`
4. `open app/MacBase.xcodeproj`,⌘R 运行。

只动 Rust 的话不需要 Xcode:`cd core && cargo test`。

## 绑定约定

Rust 侧用 UniFFI proc-macro(`#[uniffi::export]` / `#[derive(uniffi::Object)]`);
新增 API 后跑 `scripts/build-core.sh` 重新生成 `app/Generated/macbase_core.swift`。
跨语言不传递递归结构:对局树以节点 id(`u32`)寻址,Swift 拿 `NodeInfo` 记录。
