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
round-trip through the same path.

**Games move between files.** Right-click ▸ Copy to ▸ *another open tab*
appends the selected games to that file and writes it back once. A game
already there — same start position, same main line, whatever the headers
say — is skipped and counted, so copying twice lands once.

**The file is watched.** If another program changes a `.pgn` while it is
open here, a banner offers **Reload** (take the file as it is now; unsaved
edits to its games are lost) or **Keep Mine** (carry on; the next save
replaces the file, with a `.pgn.bak` kept). The app's own saves do not
trigger it.

**One window per file, as tabs.** Every `.pgn` you open gets its own window,
and windows tab together the way Safari's do (drag them apart if you prefer
windows). A file is opened once: opening it again brings its tab forward. Each
tab keeps its own list, filter, selection and engine; only the front tab's
engine runs. The files that were open come back as tabs on the next launch,
each on the game you were looking at.

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
The panel's source switches between the open database and lichess's
**Masters**, **Lichess** (rating band and speeds of your choosing) and
**Player** (a lichess username's own games) explorers. lichess requires an API token
for these; it is **your own** (a read-only one, made in one click from the
panel's settings) and lives in the Keychain — the app ships none, since one
token in the binary would be one quota shared by everybody. Results are
cached on disk per position, requests are debounced while you step through
moves, and a 429 waits out lichess's `Retry-After`.

**Whole-game analysis.** Game ▸ Analyze Game… walks the main line at a fixed
depth and marks the moves that lose more than a threshold (`?!` `?` `??`),
writes what the eval did ("+2.16 → +3.27"), and inserts the engine's line as a
variation. Mark both sides or just one — a coach wants the student's mistakes,
not the opponent's — and the main line alone or every variation in the tree.
One undo step for the whole run; existing comments are appended to. A mating
move is never marked, and neither is the engine's own first choice (an eval
that drops after a forced move is the search seeing further, not the player
going wrong).

**Merging games.** Select several rows and Merge Selected Games: the first
game's tree takes the others as variations wherever they diverge, comments and
NAGs included. The result opens as a new, unsaved game.

**Diagrams and paper.** `⌘D` puts a diagram after the current move — stored as
NAG `$220`, the ChessBase convention, so it round-trips. File ▸ Print Game… and
Export Game as PDF… lay out a title block and the notation exactly as the
panel shows it, diagrams included.

**Figurines.** Letters (Nf3) by default, as ChessBase shows them; Game ▸
Figurine Notation switches the panel and print to ♘f3. The file always keeps
letters. Null moves (`--`) parse, replay, and
round-trip, so analysis PGNs from other tools open whole.

**Novelties.** With the reference panel open, a move that does not appear from
its parent position in the chosen source is called out — "N — Ke2 is not in
Masters (314,452 games from here)" — with a button that writes the ChessBase
novelty mark (`$146`) into the game. Silent when the parent position itself
is unknown to the source: leaving the book is not the same as never having
been in it.

**Filtering.** Beside the search field, a filter for result, date range and
Elo range (both players); every criterion combines with the text search and
with the reference view's position filter.

**Setup positions.** `⌥⌘N` opens a position editor (place pieces, side to move,
castling rights filtered by what is actually possible) and starts a new game
from a `[SetUp]`/`[FEN]` header. Engine analysis works at the root of such a
game, which is what makes studies and tactics puzzles usable.

## Known gaps

- **Not notarized.** The released build is ad-hoc signed, so macOS quarantines
  it on first launch. See the install notes in the README.
- **Apple Silicon only.** No Intel build.
- **A source file edited outside the app while it is closed here is taken as
  the truth.** Cache freshness is a modification-time comparison made when
  the file is opened; if the `.pgn` is newer, the cache is rebuilt from it
  and in-app edits that were never saved are gone. (While the file is open,
  the banner above catches this.)
- **No drag and drop between tabs**; copying is a menu command.
- **No cross-file search**, no player or tournament index, no position or
  material search. A search is about one file — the tab it runs in.
- **Analysis uses a fixed depth**; there is no time budget, no second
  engine, and no tablebases.
- **Printing is the notation as shown**; there is no page layout to speak of
  beyond a title block, and no HTML export.
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
