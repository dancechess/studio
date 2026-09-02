# The notation panel

The notation panel — the ChessBase-style variation tree on the right of the
board — is the hardest control in the app, and the one whose design is worth
writing down. An earlier attempt (a web board) failed for a specific reason:
the layout logic lived inside the UI component, where it could not be tested.

So the work is split three ways, and the split is the design:

```
Rust variation tree ──▶ notation_tokens() ──▶ NSTextView rendering + hit-testing
     the data              the layout                  the pixels
```

Layout happens in Rust and is unit-tested. Rendering is a dumb walk over the
token stream. The only piece of UI state is **the current node id**; the board,
the engine panel, and the reference tree all subscribe to it.

## 1. The token stream

`Game::notation_tokens() -> [NotationToken]`. Each token carries `kind`, `text`,
`node_id` (for hit-testing; `nil` on structural tokens) and `depth`, where 0 is
the main line.

| kind | example `text` | notes |
|---|---|---|
| `MoveNumber` | `2.` / `2...` | The black form appears only at the start of a variation, after a paragraph break, or after a comment interrupts the flow. |
| `Move` | `Nf3!?` | Suffix NAGs `$1`–`$6` are **folded into the text**, so a click target includes them. |
| `Nag` | `±` `⩲` `∞` | Evaluation NAGs stay separate tokens, sharing the `node_id` of their move. |
| `Comment` | the comment body | Braces stripped. |
| `OpenParen` / `CloseParen` | | Only for nested variations at depth ≥ 2. |
| `ParagraphBreak` | | `depth` is the indent level of the *following* paragraph. |

### The rendering contract

A renderer that breaks these rules produces subtly wrong output, so they are
stated as rules rather than left to taste:

- Put one space between tokens; none after `(` or before `)`.
- `ParagraphBreak` starts a new paragraph whose `headIndent` is
  `depth × indentStep`.
- Main line flows as running text. **First-level variations each get their own
  indented paragraph**, after which the main line resumes in a fresh paragraph
  at depth 0. Second-level and deeper variations stay inline, in parentheses,
  inside their parent's paragraph.

In the compact notation used by the tests, where `¶n` is a paragraph break to
depth *n*:

```
1. e4 e5 ¶1 1... c5 2. Nf3 ( 2. Nc3 Nc6 ) 2... d6 ¶0 2. Nf3
```

- Any edit to the tree (adding or deleting a move, a comment, a NAG)
  invalidates the stream: call it again and rebuild the text.
  **Navigation never requires a rebuild.**

## 2. The NSTextView layer

Not SwiftUI `Text`: this view needs flowing layout over tens of thousands of
tokens, a context menu, precise character hit-testing, `scrollRangeToVisible`,
and highlight changes that touch two ranges instead of relaying out the
document. `NSTextView` gives all of that away for free.

- Non-editable, selectable. Every `Move`/`MoveNumber`/`Nag`/`Comment` range
  carries a custom `.dcsNodeID` attribute.
- `mouseDown` → `characterIndexForInsertion` → read the attribute → select that
  node. Probe both `index` and `index - 1`: the insertion point can land just
  past the glyph the user aimed at.
- Styling: main line bold; variations grey out with depth; comments green;
  the current node gets a highlight background. Moving the highlight rewrites
  the attribute on the old and new ranges only — no re-layout.
- After a selection change, `scrollRangeToVisible` keeps the current move on
  screen. A full rebuild saves and restores the scroll position.

## 3. Interaction

### Study mode

The board and notation panel have focus. This is the full editing key map:

| Key | Action |
|---|---|
| `→` | Follow `children[0]`. **If the node has several continuations, a variation chooser pops up** (`↑↓` to pick, `Return` to take it, `Esc` to cancel). |
| `←` | Back to the parent node. |
| `↑` / `↓` | Move between sibling variations. |
| `Home` / `End` | Start of game / end of the current line. |
| `⌫` | Delete the subtree starting at the current move (after confirmation). |
| `⌘↑` | Promote the current variation. |
| `!` `?` | Apply the corresponding NAG. Pressing the same key again clears it; a NAG of the same class replaces the previous one. |
| `Return` / `⌘A` | Open the comment editor. |
| `f` / `⇧⌘F` | Flip the board. |
| `⌘Z` / `⇧⌘Z` | Undo / redo (a stack of whole-game PGN snapshots). |
| `Esc` | Back to the game list. |

### Browse mode

Focus is in the game list below. The board follows the selection as a preview.

| Key | Action |
|---|---|
| `↑` / `↓` | Select a game. |
| `←` / `→` | Step through the selected game's moves. |
| `Return` | Enter study mode. |
| `⌫` | Delete the selected game (after confirmation). |
| `⌘F` | Focus the search field; `Esc` clears it. |

`⌥↑` / `⌥↓` switch games in **either** mode — which is why `⌘↑` is reserved for
promoting a variation and should not be bound to anything else. Double-clicking
a row opens the game-info sheet; `⌘`-double-click opens the game in its own
window. While the variation chooser is up, its keys win in both modes.

## Two design decisions worth keeping

**Comments are edited in a popover, not inline.** Editable rich text inside the
notation flow means owning cursor movement, undo coalescing, and input-method
composition — a swamp. ChessBase uses a dialog for the same reason. The popover
holds a plain text editor and writes back on commit.

**Board annotation tags are not rendered as text.** Arrows and square
highlights are stored in the node comment as `[%cal]` / `[%csl]` tags, the
convention lichess and ChessBase share, so they round-trip through any PGN
tool. The panel strips those tags when building its attributed string, and
skips a comment consisting only of tags — the check has to happen *before* the
inter-token space is emitted, or the line ends up with a double space. The
comment editor likewise shows only the prose; the tags belong to the board
overlay.

## NAG glyphs

`notation.rs` is the authority. Suffix NAGs folded into the move text:

`$1` ! `$2` ? `$3` !! `$4` ?? `$5` !? `$6` ?!

Standalone evaluation glyphs:

`$7` □ `$10` = `$13` ∞ `$14` ⩲ `$15` ⩱ `$16` ± `$17` ∓ `$18` +− `$19` −+
`$22`/`$23` ⨀ `$32`/`$33` ⟳ `$36`/`$37` → `$40`/`$41` ↑ `$44`/`$45` =∞
`$132`/`$133` ⇆ `$140` ∆ `$146` N

Anything else renders as `$n`.
