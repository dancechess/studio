# 架构

## 分层

```
SwiftUI / AppKit 界面 (app/)
        │  UniFFI 生成的绑定 (app/Generated/, 构建产物不进 git)
Rust 核心 (core/) ── 走法、变着树、PGN、SQLite、开局树
        │
UCI 引擎 (Stockfish) ── 独立子进程,Swift 侧 Process+pipe 管理(未实现)
```

原则:**所有性能敏感和正确性敏感的逻辑在 Rust**(走法合法性、PGN 解析/
序列化、排版令牌、数据库);Swift 只做渲染与交互。引擎不进 Rust——UCI
是文本协议,Swift 管子进程更顺。

## Rust 模块(core/src/)

| 模块 | 内容 |
|---|---|
| `position.rs` | 无状态函数:`legal_moves_san(fen)`、`apply_san(fen, san)`、`start_fen()`。perft 测试保正确性。 |
| `game.rs` | `Game` 对象:变着树(arena:`Vec<Node>`,`children[0]` 是主线)、PGN 解析(pgn-reader Visitor)与序列化、编辑操作(add_move / set_comment / add_nag / promote_variation / delete_node)。 |
| `notation.rs` | `notation_tokens()`:树 → 着法面板的排版令牌流。契约见 NOTATION-VIEW.md。 |
| `db.rs` | `Database` 对象:PGN 流式导入、分页排序列表、开局树聚合。 |

## 跨语言桥接约定(UniFFI)

- 全部用 proc-macro(`#[uniffi::export]`、`#[derive(uniffi::Object/Record/Enum/Error)]`),没有 UDL 文件。
- 改了导出 API 就跑 `scripts/build-core.sh`:编译 staticlib + 重新生成
  `app/Generated/macbase_core.swift` 与 modulemap。
- **不传递归结构**。树节点以 `u32` id 寻址(0 = 根),Swift 拿扁平的
  `NodeInfo` 记录。id 在删除节点后依然稳定(子树只摘链不回收)。
- 有状态对象(`Game`、`Database`)内部 `Mutex`,对 Swift 是 `Sendable`。
- 错误统一 `ChessError`(InvalidFen / InvalidMove / Database),Swift 侧是 throws。

## 对局树语义

- 节点 = 一步棋;根节点无着法,代表起始局面(FEN header 支持让子/残局起点)。
- `add_move` 会先按当前局面校验合法性,并把 SAN 归一化(自动补 +/# 后缀);
  同一节点下重复走同一步返回已有节点,否则追加为变着。
- `fen_at(id)` 从根重放路径现算,不缓存——万步以内无感,先不优化。

## 数据库 schema(SQLite,WAL)

```sql
games(id, white, black, white_elo, black_elo, result, event, site,
      date, round, eco, ply_count, pgn)
positions(zobrist, game_id, move, result)   -- INDEX(zobrist)
```

- `games.pgn` 存**规范化重序列化**的 PGN(解析 → 我们自己的序列化),
  不存原文。round-trip 保真有测试兜底;好处是读回时解析路径唯一。
- `positions` 只为开局树服务(**不做**通用局面检索——MVP 明确砍掉):
  每局主线前 60 个半回合,每行是(走子前局面的 zobrist、着法、胜负)。
  FEN 起点非标准的对局不进索引。result 编码:0 白胜 1 和 2 黑胜 3 未知,
  未知不计入 W/D/L 但仍占 games 行。
- 性能基准(release,M4 级别 arm64):10 万局导入 2.1s(计划目标 60s)。
  复测:`cargo run --release --example import_bench -- <大文件.pgn>`。

## Swift 侧(骨架已写,待 Xcode)

- 工程由 XcodeGen 从 `app/project.yml` 生成;pre-build phase 跑
  build-core.sh,链接 `core/target/release/libmacbase_core.a`。
- 沙盒开启,文件访问走 NSOpenPanel(user-selected read-write)。
- 大列表(棋局列表)用 NSTableView 包 `NSViewRepresentable`,SQLite 分页
  懒加载;SwiftUI `Table` 撑不住十万行。
- 客户端渲染忌讳:不在渲染期读时钟、不用 locale 相关格式化(上个项目
  的水合坑,SwiftUI 虽无水合,惯例保留:时间显示逻辑集中、可测)。
