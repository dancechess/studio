# 路线图(MVP)

范围共识:PGN 导入、棋局列表、棋盘回放与标注、UCI 引擎分析、开局树。
**不做**局面/素材检索(用户明确砍掉)。每个里程碑以可运行的 app 收尾。

| 里程碑 | 内容 | Rust 半边 | Swift 半边 |
|---|---|---|---|
| M0 骨架 | Swift↔Rust 桥打通,界面显示 `legal_moves` | ✅ 完成 | ✅ 桥经 SPM 冒烟端到端验证;Xcode 工程本身待装 Xcode |
| M1 棋盘与回放 | 棋盘渲染、拖子、着法面板(见 NOTATION-VIEW.md) | ✅ 树 + 令牌 + 坐标 API | 🔶 第一版可用:棋盘点击走子(自动开变着)、NSTextView 着法面板(点击跳转/高亮/自动滚动/变着缩进)、←→↑↓ 导航、打开/粘贴 PGN。缺:分叉浮窗、拖子、升变选子(现自动后)、Unicode 棋子待换素材 |
| M2 导入与列表 | PGN → SQLite,NSTableView 分页列表 | ✅ `Database`(10 万局 2.1s) | ⏸ 未开始 |
| M3 引擎分析 | 评估条、MultiPV、插入变着、打包 Stockfish | (无,UCI 在 Swift 侧) | 🔶 UCIKit 完成(握手/分析/info 解析,真 stockfish 测过);UI 未开始 |
| M4 开局树 | 树面板 W/D/L 统计,点着法即走 | ✅ `opening_tree()` | ⏸ 未开始 |
| M5 标注与导出 | 注释/NAG 编辑、变着升删、PGN 导出 | ✅ 编辑 API + 序列化 | ⏸ 未开始 |

冒烟:`cd app && swift run MacBaseSmoke`(15 项:UCI 解析、桥的走法/树/
令牌/数据库、真 Stockfish 深度 12 MultiPV 2)。

## 当前阻塞

**Xcode 未安装**(只有 Command Line Tools;SPM 开发套件已绕开大半——桥、
UCIKit、冒烟都能跑,`swift run MacBaseApp` 还能直接弹 M0 窗口)。剩下必须
Xcode 的:正式 .app bundle、资源目录、签名、SwiftUI 预览。用户动作:
App Store 装 Xcode → 启动接受许可 →
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` →
`brew install xcodegen` → `xcodegen -s app/project.yml`。

## MVP 之后(讨论过、未承诺)

- 棋子素材:lichess cburnett 集(注意随附许可)。
- 引擎一致率 / 对局质量分析(用户在另一个项目里有类似需求)。
- 发布:签名/公证、Sparkle 更新、名字避开 ChessBase 商标。
