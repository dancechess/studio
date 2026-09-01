# 着法面板(ChessBase 式变着树控件)设计

全 app 最难的控件。上一次(lichess 棋盘 + web)失败的教训:排版逻辑混在
UI 组件里没法测。所以这里三层分离,**排版在 Rust、渲染在 NSTextView、
状态只有一个"当前节点 id"**。

```
Rust 变着树 ──> notation_tokens() 令牌流 ──> NSTextView 渲染 + 交互
```

## 1. 令牌流(已实现,core/src/notation.rs)

`Game::notation_tokens() -> [NotationToken]`,字段:
`kind`、`text`、`node_id`(点击命中用;结构令牌为 nil)、`depth`(0 = 主线)。

| kind | text 示例 | 说明 |
|---|---|---|
| MoveNumber | `2.` / `2...` | 黑方号只在变着开头、换段后、注释打断后出现 |
| Move | `Nf3!?` | **$1–$6 后缀 NAG 已并入文本**,点击目标含后缀 |
| Nag | `±` `⩲` `∞` | 评估类 NAG,独立令牌,node_id 同其着法 |
| Comment | 注释正文 | 不含花括号 |
| OpenParen / CloseParen | | 仅 depth ≥ 2 的嵌套变着 |
| ParagraphBreak | | `depth` = 下一段的缩进级 |

### 渲染契约(Swift 侧必须遵守)

- 令牌间加一个空格;`(` 之后、`)` 之前不加。
- ParagraphBreak → 换行,新段落 `headIndent = depth × 缩进步长`。
- 排版规则:主线流式;**一级变着各起一段缩进**,之后主线另起 ¶0 段恢复;
  二级以上留在父段落括号内。测试里的紧凑记法示例:

```
1. e4 e5 ¶1 1... c5 2. Nf3 ( 2. Nc3 Nc6 ) 2... d6 ¶0 2. Nf3
```

- 树一被编辑(加着/删着/注释/NAG)令牌流即失效,重新调用重建全文;
  **纯导航永远不需要重建**。

## 2. NSTextView 渲染(M1,未实现)

为什么不用纯 SwiftUI:上万令牌的流式布局、右键菜单、精确命中、
`scrollRangeToVisible`、只改两个 range 的高亮切换——都是 NSTextView 白给的。

- 不可编辑、可选择;每个 Move/MoveNumber/Nag/Comment 的 range 挂自定义
  attribute `.dcsNodeID`。
- `mouseDown` → `characterIndexForInsertion` → 读 attribute → 选中节点。
- 样式:主线粗体;变着按 depth 变灰;注释绿色;当前节点高亮底色。
  高亮切换只对旧/新两个 range 改 attribute,不重排。
- 选中变化后 `scrollRangeToVisible` 跟踪当前着。
- 重建全文时保存/恢复滚动位置。

## 3. 交互(状态源 = 当前节点 id,棋盘/引擎/开局树面板都订阅它)

| 键 | 行为 | Rust 支撑 |
|---|---|---|
| → | 进 `children[0]`;**多个继续着法时弹变着选择浮窗**(↑↓+回车选,Esc 取消)| `node().children` |
| ← | 回父节点 | `node().parent` |
| ↑ / ↓ | 兄弟变着首着间跳 | 同上 |
| Home / End | 局首 / 当前线末尾 | |
| ⌫ | 删当前着起的子树(确认后) | `delete_node` ✓ |
| ⌘↑ | 变着升级 | `promote_variation` ✓ |
| `!` `?` 等 | 给当前着打对应 NAG | `add_nag` ✓ |
| 回车 / ⌘A | 注释编辑 popover | `set_comment` ✓ |

- 快捷键经菜单栏 Commands 注册(标准 Mac 体验,自动出现在菜单里)。
  ——**M5 实现时暂缓**:键位仍走 KeyEventMonitor(和方向键一套,原因见
  AGENTS 坑 9),菜单栏注册留作 polish;右键菜单已实现(NotationView
  Coordinator 建 NSMenu,右键先选中被点的着)。
- **单窗口两态(2026-09-01 定,MainWindow)**:上表键位在**研读态**生效。
  浏览态(焦点在下方列表):↑↓ 选局、←→ 在预览局里前后步、Enter 进入研读态;
  Esc 从研读态返回列表;**⌥↑/⌥↓ 两态通用换局**(⌘↑ 留给上表的变着升级,
  别占用);双击列表行 = Game Info 编辑(2026-09-01 用户定的),⌘双击弹
  独立对局窗。分叉浮窗弹出时其键位在两态下都优先。
- **注释不做全文内联编辑**(可编辑富文本 = 光标/undo/输入法泥潭,
  ChessBase 也是弹窗):popover 里普通 TextEditor,提交时写回。
- 右键菜单:升/删变着、加注释、从此处复制 PGN。

## 4. 分阶段

1. M1 第一版:只读渲染 + 点击跳转 + ←→ + 高亮 + 自动滚动。
2. M1 收尾:分叉浮窗、↑↓ 换线、缩进段落样式打磨。
3. M5:NAG 快捷键、⌫/⌘↑ 编辑、注释 popover、右键菜单。

## NAG 字形表(notation.rs 为准)

`$1`!`$2`?`$3`!!`$4`??`$5`!?`$6`?! → 并入着法;
`$7`□ `$10`= `$13`∞ `$14`⩲ `$15`⩱ `$16`± `$17`∓ `$18`+− `$19`−+
`$22/23`⨀ `$32/33`⟳ `$36/37`→ `$40/41`↑ `$44/45`=∞ `$132/133`⇆
`$140`∆ `$146`N,其余显示 `$n`。
