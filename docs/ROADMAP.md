# 路线图(MVP)

范围共识:PGN 导入、棋局列表、棋盘回放与标注、UCI 引擎分析、开局树。
**不做**局面/素材检索(用户明确砍掉)。每个里程碑以可运行的 app 收尾。

| 里程碑 | 内容 | Rust 半边 | Swift 半边 |
|---|---|---|---|
| M0 骨架 | Swift↔Rust 桥打通,界面显示 `legal_moves` | ✅ 完成 | ⏸ 代码已写,等 Xcode 首次构建 |
| M1 棋盘与回放 | 棋盘渲染、拖子、着法面板(见 NOTATION-VIEW.md) | ✅ `Game` 树 + `notation_tokens()` | ⏸ 未开始 |
| M2 导入与列表 | PGN → SQLite,NSTableView 分页列表 | ✅ `Database`(10 万局 2.1s) | ⏸ 未开始 |
| M3 引擎分析 | 打包 Stockfish、评估条、MultiPV、插入变着 | (无,UCI 在 Swift 侧) | ⏸ 未开始 |
| M4 开局树 | 树面板 W/D/L 统计,点着法即走 | ✅ `opening_tree()` | ⏸ 未开始 |
| M5 标注与导出 | 注释/NAG 编辑、变着升删、PGN 导出 | ✅ 编辑 API + 序列化 | ⏸ 未开始 |

## 当前阻塞

**Xcode 未安装**(只有 Command Line Tools)。用户动作:App Store 装 Xcode
→ 启动接受许可 → `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
→ `brew install xcodegen`。之后 `xcodegen -s app/project.yml` 生成工程,
首次构建验证 M0。

## MVP 之后(讨论过、未承诺)

- 棋子素材:lichess cburnett 集(注意随附许可)。
- 引擎一致率 / 对局质量分析(用户在另一个项目里有类似需求)。
- 发布:签名/公证、Sparkle 更新、名字避开 ChessBase 商标。
