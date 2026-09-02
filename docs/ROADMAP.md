# Status and roadmap

DC Studio is alpha software: complete enough to prepare lessons and annotate
games with, rough enough that you should keep the `.pgn.bak` files it leaves
behind. This page says what works, what doesn't, and what is merely an idea.

The scope was fixed early and deliberately kept small: import PGN, list games,
replay and annotate them, analyze with a UCI engine, and show an opening tree.
General position and material search is explicitly **out of scope** — the
`positions` index exists only to serve the opening tree.

## What works

**Games and files.** Open any `.pgn` and its games become the list. SQLite is
only a per-file cache; saving writes back to the source file, atomically, with
a `.pgn.bak` kept from before the session's first write. New files, manual game
entry with a ChessBase-style save mask, delete, and per-game PGN export all
round-trip through the same path. Recent files and the last game you were
looking at are restored on launch.

**Board and notation.** Click or drag to move, promotion picker, a variation
chooser when a move has several continuations, board flip, coordinates. The
notation panel renders the full variation tree; see
[NOTATION-VIEW.md](NOTATION-VIEW.md) for its design and the complete key map.

**Annotation.** `!`/`?` NAGs, evaluation symbols, comments in a popover,
promote and delete variations, undo/redo over whole-game snapshots, and board
arrows and square highlights stored as `[%cal]`/`[%csl]` tags that survive a
round trip through other PGN tools.

**Engine.** `⌘E` toggles the analysis panel, which is also the on/off switch
for the engine itself. Horizontal eval bar under the board, MultiPV (default 3,
adjustable in the panel), and clicking an engine line inserts it as a
variation — one move on a plain click, the whole line with `⌥`. Stockfish is
bundled in the app.

**Reference.** `⌘T` shows opening statistics for the current position — moves,
game counts, a W/D/L bar, white's score — and filters the game list to the
games that reach it. Matching is by Zobrist hash, so transpositions count.

**Setup positions.** `⌥⌘N` opens a position editor (place pieces, side to move,
castling rights filtered by what is actually possible) and starts a new game
from a `[SetUp]`/`[FEN]` header. Engine analysis works at the root of such a
game, which is what makes studies and tactics puzzles usable.

## Known gaps

- **Not notarized.** The released build is ad-hoc signed, so macOS quarantines
  it on first launch. See the install notes in the README.
- **Apple Silicon only.** No Intel build.
- **One file at a time is the supported path.** You can open several `.pgn`
  files into one merged list, but saving is disabled for merged lists — there
  is no defined file to write back to.
- **A source file edited outside the app discards in-app edits.** Cache
  freshness is a modification-time comparison; if the `.pgn` is newer, the
  cache is rebuilt from it. Save before editing the file elsewhere.
- **Not every column sorts.** Sorting exists for #, White, Black, Event, Date,
  Round, ECO and White Elo — not for Result or Black Elo. Adding one means
  extending `GameSort` in Rust first.
- **No multi-database management**, no cross-file search, no player or
  tournament index.
- **Not sandboxed.** Sandboxing will need security-scoped bookmarks before
  write-back can survive relaunches.

## Ideas, not commitments

- Engine-correlation and game-quality analysis.
- Signing, notarization, and a Sparkle update feed.
- Deeper opening-book work (repertoire files, novelty detection).

## A note on Xcode

Full Xcode is not required and never becomes required. The Command Line Tools
carry everything the project needs: SwiftPM builds and runs the app including
its SwiftUI parts, and `codesign`, `iconutil`, `hdiutil` and even `notarytool`
ship with them. `scripts/make-app.sh` assembles a double-clickable `.app`
without touching Xcode, placing resources directly in `Contents/Resources/`
rather than in an asset catalog.

Xcode buys comfort, not capability — previews, Instruments, the view hierarchy
debugger. If you want it, `app/project.yml` still generates a project via
`xcodegen -s app/project.yml`, and the sources are shared with the SwiftPM
harness.
