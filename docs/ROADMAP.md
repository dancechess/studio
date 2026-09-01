# 路线图(MVP)

范围共识:PGN 导入、棋局列表、棋盘回放与标注、UCI 引擎分析、开局树。
**不做**局面/素材检索(用户明确砍掉)。每个里程碑以可运行的 app 收尾。

| 里程碑 | 内容 | Rust 半边 | Swift 半边 |
|---|---|---|---|
| M0 骨架 | Swift↔Rust 桥打通,界面显示 `legal_moves` | ✅ 完成 | ✅ 桥经 SPM 冒烟端到端验证;Xcode 工程本身待装 Xcode |
| M1 棋盘与回放 | 棋盘渲染、拖子、着法面板(见 NOTATION-VIEW.md) | ✅ 树 + 令牌 + 坐标 API | ✅ 点击/拖子走棋、分叉变着浮窗(→ 遇分叉弹出,↑↓+回车选)、升变选子浮窗、↑↓ 兄弟变着切换 + Home/End 局首末、NSTextView 着法面板、打开/粘贴 PGN、Merida SVG 棋子素材(2026-09-01 换毕) |
| M2 导入与列表 | 打开 PGN(SQLite 为每文件缓存),单窗口列表 + 棋盘(用户定稿) | ✅ `Database` + `update_game` + `clear_all` + `Number` 排序 | ✅ 验收通过后又按用户要求改为:Open PGN 替换列表、每 PGN 一份缓存(mtime 新鲜判定,二次打开秒开)、# 编号列(= 文件内序号,默认排序)。单窗口两态焦点、保存询问等见 AGENTS。之后补:# 编号列 + Round 列、手工录入闭环(⌘S 存入当前列表 + 对局信息表单 + New PGN 建空文件)、**保存即写回源 .pgn**(全量重写,原子替换)。剩余:搜索筛选、删对局 |
| M3 引擎分析 | 评估条、MultiPV、插入变着、打包 Stockfish | ✅ `uci_line_to_san`(PV 转 SAN) | 🔶 完成待验收(2026-09-01):⌘E 开关面板(可见=在算)、横评估条(棋盘下,ChessBase 式)、MultiPV 默认 3 + 面板内 +/-、行带着法编号、点击插第一步 / ⌥点击插整线、`go infinite`+`stop` 循环、make-app.sh 内置 stockfish(沙盒可用);主窗和独立窗都有 |
| M4 开局树 | Reference 模式:树 + matched 对局列表联动(用户定稿,对标 ChessBase Reference) | ✅ `opening_tree()` + `games_at_position(_count)` | 🔶 完成待验收(2026-09-01):⌘T 开关,右栏下半区(与引擎面板互斥共用),行 = 着法/局数/W-D-L 分段条/白方得分%,点着法即走;开启时底部列表过滤为"到达当前局面的对局"(zobrist,换序转换也算),状态栏显示 "N of M";换列表自动退出 |
| M5 标注与导出 | 注释/NAG 编辑、变着升删、PGN 导出 | ✅ 编辑 API + 序列化 | 🔶 完成待验收(2026-09-01):`!`/`?` 打 NAG(同类替换、再按取消)、⌫ 确认后删子树、⌘↑ 变着升级、↩/⌘A 注释浮窗(TextEditor,⌘↩ 存/Esc 取消);记谱右键菜单(升/删/注释/Annotate 全套 NAG/Copy PGN/Copy FEN/Export Game as PGN…);⌘S 存库即写回,导出另存单局。菜单栏 Commands 注册暂缓(键位走监视器) |

冒烟:`cd app && swift run MacBaseSmoke`(15 项:UCI 解析、桥的走法/树/
令牌/数据库、真 Stockfish 深度 12 MultiPV 2)。

## Xcode:不再是阻塞项(2026-09-01 验证)

Command Line Tools 足以走完全程:SPM 编译/运行(含 SwiftUI)、
`scripts/make-app.sh` 产出 ad-hoc 签名的 `dist/MacBase.app`(已验证可
双击启动),`codesign`/`iconutil`/`hdiutil` 系统自带,连 `notarytool`
(上线公证用)都在 CLT 里。资源(棋子图、引擎)直接放
`Contents/Resources/`,不需要 asset catalog。

装 Xcode 只为舒适性,不装也不拦路:SwiftUI 预览、Instruments 剖析、
视图层级调试器。想装的话 `app/project.yml` 仍可用
(`xcodegen -s app/project.yml`)。

## MVP 后打磨第一批(2026-09-01 完成,待验收)

翻转棋盘("f"/⇧⌘F)、棋盘坐标、列表搜索(⌘F,White/Black/Event)、
删除对局(右键/⌫,写回)、菜单栏 Commands 注册、⌘Z/⇧⌘Z 撤销重做
(整局 PGN 快照栈)。

## MVP 收尾第二批(2026-09-01 完成,待验收)

写回前自动备份(每文件每次启动首写留 .pgn.bak)、File ▸ Open Recent
(最近 8 个)、拖 PGN 到窗口打开 + .pgn 文件关联(Finder 双击/拖 Dock)、
应用图标(Merida 马 + 棋色渐变,assets/MacBase.icns)、启动恢复上次
查看的对局。

## MVP 之后(讨论过、未承诺)

- ~~棋子素材~~:已完成(2026-09-01),选了 Merida 而非 cburnett(用户拍板,
  更接近 ChessBase 图解风格);GPLv2+,许可随附在素材目录。
- 引擎一致率 / 对局质量分析(用户在另一个项目里有类似需求)。
- 发布:签名/公证、Sparkle 更新、名字避开 ChessBase 商标。
