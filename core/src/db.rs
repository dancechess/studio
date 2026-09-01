use std::sync::Mutex;
use std::time::Instant;

use pgn_reader::BufferedReader;
use rusqlite::{params, Connection};
use shakmaty::fen::Fen;
use shakmaty::san::San;
use shakmaty::zobrist::{Zobrist64, ZobristHash};
use shakmaty::{CastlingMode, Chess, EnPassantMode, Position};

use crate::game::GameBuilder;
use crate::{ChessError, START_FEN};

/// Opening-tree positions are indexed for the first N plies of each game.
const TREE_MAX_PLY: usize = 60;

const RESULT_WHITE: i64 = 0;
const RESULT_DRAW: i64 = 1;
const RESULT_BLACK: i64 = 2;
const RESULT_UNKNOWN: i64 = 3;

#[derive(uniffi::Record)]
pub struct GameSummary {
    pub id: i64,
    pub white: String,
    pub black: String,
    pub white_elo: Option<u32>,
    pub black_elo: Option<u32>,
    pub result: String,
    pub round: String,
    pub event: String,
    pub date: String,
    pub eco: String,
    pub ply_count: u32,
}

#[derive(uniffi::Record)]
pub struct ImportStats {
    pub imported: u32,
    pub skipped: u32,
    pub millis: u64,
}

#[derive(uniffi::Record)]
pub struct TreeMove {
    pub san: String,
    pub games: u32,
    pub white_wins: u32,
    pub draws: u32,
    pub black_wins: u32,
}

#[derive(uniffi::Enum)]
pub enum GameSort {
    /// By id — import order, i.e. the game's position in the opened file.
    Number,
    /// Numeric on the round text, so "10" sorts after "2" and "2.1" works.
    Round,
    Date,
    White,
    Black,
    Event,
    Eco,
    WhiteElo,
}

#[derive(uniffi::Object)]
pub struct Database {
    conn: Mutex<Connection>,
}

fn db_err(e: impl std::fmt::Display) -> ChessError {
    ChessError::Database {
        reason: format!("{e}"),
    }
}

fn like_pattern(text: &str) -> String {
    let escaped = text
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_");
    format!("%{escaped}%")
}

const SUMMARY_COLS: &str =
    "id, white, black, white_elo, black_elo, result, round, event, date, eco, ply_count";

fn summary_from_row(r: &rusqlite::Row) -> rusqlite::Result<GameSummary> {
    Ok(GameSummary {
        id: r.get(0)?,
        white: r.get(1)?,
        black: r.get(2)?,
        white_elo: r.get(3)?,
        black_elo: r.get(4)?,
        result: r.get(5)?,
        round: r.get(6)?,
        event: r.get(7)?,
        date: r.get(8)?,
        eco: r.get(9)?,
        ply_count: r.get::<_, i64>(10)? as u32,
    })
}

#[uniffi::export]
impl Database {
    /// Opens (creating if needed) a database file.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Self, ChessError> {
        let conn = Connection::open(&path).map_err(db_err)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             CREATE TABLE IF NOT EXISTS games (
                 id INTEGER PRIMARY KEY,
                 white TEXT NOT NULL DEFAULT '',
                 black TEXT NOT NULL DEFAULT '',
                 white_elo INTEGER,
                 black_elo INTEGER,
                 result TEXT NOT NULL DEFAULT '*',
                 event TEXT NOT NULL DEFAULT '',
                 site TEXT NOT NULL DEFAULT '',
                 date TEXT NOT NULL DEFAULT '',
                 round TEXT NOT NULL DEFAULT '',
                 eco TEXT NOT NULL DEFAULT '',
                 ply_count INTEGER NOT NULL DEFAULT 0,
                 pgn TEXT NOT NULL
             );
             CREATE TABLE IF NOT EXISTS positions (
                 zobrist INTEGER NOT NULL,
                 game_id INTEGER NOT NULL,
                 move TEXT NOT NULL,
                 result INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS idx_positions_zobrist ON positions(zobrist);",
        )
        .map_err(db_err)?;
        Ok(Database {
            conn: Mutex::new(conn),
        })
    }

    /// Streams every game of a PGN file into the database.
    /// Unparsable games are skipped, not fatal.
    pub fn import_pgn_file(&self, path: String) -> Result<ImportStats, ChessError> {
        let started = Instant::now();
        let file = std::fs::File::open(&path).map_err(db_err)?;
        let mut reader = BufferedReader::new(file);
        let mut builder = GameBuilder::default();
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction().map_err(db_err)?;
        let mut imported = 0u32;
        let mut skipped = 0u32;
        loop {
            match reader.read_game(&mut builder) {
                Ok(Some(game)) => match insert_game(&tx, &game) {
                    Ok(_) => imported += 1,
                    Err(_) => skipped += 1,
                },
                Ok(None) => break,
                Err(_) => {
                    skipped += 1;
                    break; // stream is unrecoverable after a hard read error
                }
            }
        }
        tx.commit().map_err(db_err)?;
        Ok(ImportStats {
            imported,
            skipped,
            millis: started.elapsed().as_millis() as u64,
        })
    }

    /// Empties the database (open-PGN-replaces-list semantics). Ids restart
    /// from 1 on the next import, so game numbers match file order again.
    pub fn clear_all(&self) -> Result<(), ChessError> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction().map_err(db_err)?;
        tx.execute("DELETE FROM positions", []).map_err(db_err)?;
        tx.execute("DELETE FROM games", []).map_err(db_err)?;
        tx.commit().map_err(db_err)
    }

    pub fn game_count(&self) -> Result<u64, ChessError> {
        let conn = self.conn.lock().unwrap();
        conn.query_row("SELECT count(*) FROM games", [], |r| r.get::<_, i64>(0))
            .map(|n| n as u64)
            .map_err(db_err)
    }

    /// One page of the game list. `sort` maps to a fixed ORDER BY clause.
    pub fn list_games(
        &self,
        offset: u64,
        limit: u32,
        sort: GameSort,
        ascending: bool,
    ) -> Result<Vec<GameSummary>, ChessError> {
        let order = match sort {
            GameSort::Number => "id",
            GameSort::Round => "cast(round as real), round",
            GameSort::Date => "date",
            GameSort::White => "white",
            GameSort::Black => "black",
            GameSort::Event => "event",
            GameSort::Eco => "eco",
            GameSort::WhiteElo => "white_elo",
        };
        let dir = if ascending { "ASC" } else { "DESC" };
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {SUMMARY_COLS} FROM games
                 ORDER BY {order} {dir}, id LIMIT ?1 OFFSET ?2"
            ))
            .map_err(db_err)?;
        let rows = stmt
            .query_map(params![limit, offset as i64], summary_from_row)
            .map_err(db_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(db_err)
    }

    /// Games that reach the given position (transposition-aware, mainline
    /// first 60 plies) — the "matched games" half of the reference view.
    pub fn games_at_position(
        &self,
        fen: String,
        offset: u64,
        limit: u32,
        sort: GameSort,
        ascending: bool,
    ) -> Result<Vec<GameSummary>, ChessError> {
        let zobrist = zobrist_of_fen(&fen)?;
        let order = match sort {
            GameSort::Number => "id",
            GameSort::Round => "cast(round as real), round",
            GameSort::Date => "date",
            GameSort::White => "white",
            GameSort::Black => "black",
            GameSort::Event => "event",
            GameSort::Eco => "eco",
            GameSort::WhiteElo => "white_elo",
        };
        let dir = if ascending { "ASC" } else { "DESC" };
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {SUMMARY_COLS} FROM games
                 WHERE id IN (SELECT DISTINCT game_id FROM positions WHERE zobrist = ?1)
                 ORDER BY {order} {dir}, id LIMIT ?2 OFFSET ?3"
            ))
            .map_err(db_err)?;
        let rows = stmt
            .query_map(params![zobrist, limit, offset as i64], summary_from_row)
            .map_err(db_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(db_err)
    }

    /// Removes one game (row + tree index). Ids of other games keep their
    /// numbers (gaps close on the next cache rebuild).
    pub fn delete_game(&self, id: i64) -> Result<(), ChessError> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction().map_err(db_err)?;
        tx.execute("DELETE FROM positions WHERE game_id = ?1", [id])
            .map_err(db_err)?;
        let deleted = tx
            .execute("DELETE FROM games WHERE id = ?1", [id])
            .map_err(db_err)?;
        if deleted == 0 {
            return Err(db_err(format!("no game with id {id}")));
        }
        tx.commit().map_err(db_err)
    }

    /// Case-insensitive substring search over White / Black / Event.
    pub fn search_games(
        &self,
        text: String,
        offset: u64,
        limit: u32,
        sort: GameSort,
        ascending: bool,
    ) -> Result<Vec<GameSummary>, ChessError> {
        let order = match sort {
            GameSort::Number => "id",
            GameSort::Round => "cast(round as real), round",
            GameSort::Date => "date",
            GameSort::White => "white",
            GameSort::Black => "black",
            GameSort::Event => "event",
            GameSort::Eco => "eco",
            GameSort::WhiteElo => "white_elo",
        };
        let dir = if ascending { "ASC" } else { "DESC" };
        let pattern = like_pattern(&text);
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {SUMMARY_COLS} FROM games
                 WHERE white LIKE ?1 ESCAPE '\\' OR black LIKE ?1 ESCAPE '\\'
                    OR event LIKE ?1 ESCAPE '\\'
                 ORDER BY {order} {dir}, id LIMIT ?2 OFFSET ?3"
            ))
            .map_err(db_err)?;
        let rows = stmt
            .query_map(params![pattern, limit, offset as i64], summary_from_row)
            .map_err(db_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(db_err)
    }

    pub fn search_games_count(&self, text: String) -> Result<u64, ChessError> {
        let pattern = like_pattern(&text);
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT count(*) FROM games
             WHERE white LIKE ?1 ESCAPE '\\' OR black LIKE ?1 ESCAPE '\\'
                OR event LIKE ?1 ESCAPE '\\'",
            [pattern],
            |r| r.get::<_, i64>(0),
        )
        .map(|n| n as u64)
        .map_err(db_err)
    }

    pub fn games_at_position_count(&self, fen: String) -> Result<u64, ChessError> {
        let zobrist = zobrist_of_fen(&fen)?;
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT count(DISTINCT game_id) FROM positions WHERE zobrist = ?1",
            [zobrist],
            |r| r.get::<_, i64>(0),
        )
        .map(|n| n as u64)
        .map_err(db_err)
    }

    /// Appends one game (manual entry). Returns its id — with sequential
    /// ids this is also its number in the file after the next write-back.
    pub fn add_game(&self, pgn: String) -> Result<i64, ChessError> {
        let mut reader = BufferedReader::new(pgn.as_bytes());
        let mut builder = GameBuilder::default();
        let game = reader
            .read_game(&mut builder)
            .map_err(db_err)?
            .ok_or_else(|| db_err("empty PGN"))?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction().map_err(db_err)?;
        let id = insert_game(&tx, &game)?;
        tx.commit().map_err(db_err)?;
        Ok(id)
    }

    /// Serializes every game (id order) into a PGN file — the write-back
    /// half of "the PGN file is the source of truth". Atomic: temp + rename.
    pub fn write_pgn_file(&self, path: String) -> Result<(), ChessError> {
        use std::io::Write;
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT pgn FROM games ORDER BY id")
            .map_err(db_err)?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(db_err)?;
        let tmp = format!("{path}.dcstudio-tmp");
        let mut out = std::io::BufWriter::new(std::fs::File::create(&tmp).map_err(db_err)?);
        for row in rows {
            let pgn = row.map_err(db_err)?;
            out.write_all(pgn.as_bytes()).map_err(db_err)?;
            if !pgn.ends_with('\n') {
                out.write_all(b"\n").map_err(db_err)?;
            }
            out.write_all(b"\n").map_err(db_err)?; // blank line between games
        }
        out.flush().map_err(db_err)?;
        drop(out);
        std::fs::rename(&tmp, &path).map_err(db_err)?;
        Ok(())
    }

    /// Replaces a stored game with a re-parsed, re-normalized PGN and
    /// rebuilds its opening-tree index rows (save-on-close flow in the UI).
    pub fn update_game(&self, id: i64, pgn: String) -> Result<(), ChessError> {
        let mut reader = BufferedReader::new(pgn.as_bytes());
        let mut builder = GameBuilder::default();
        let game = reader
            .read_game(&mut builder)
            .map_err(db_err)?
            .ok_or_else(|| db_err("empty PGN"))?;
        let h = |key: &str| header(&game, key);
        let elo = |key: &str| -> Option<u32> { h(key).parse().ok() };
        let result = h("Result");
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction().map_err(db_err)?;
        let updated = tx
            .execute(
                "UPDATE games SET white=?1, black=?2, white_elo=?3, black_elo=?4, result=?5,
                 event=?6, site=?7, date=?8, round=?9, eco=?10, ply_count=?11, pgn=?12
                 WHERE id=?13",
                params![
                    h("White"),
                    h("Black"),
                    elo("WhiteElo"),
                    elo("BlackElo"),
                    if result.is_empty() { "*".into() } else { result.clone() },
                    h("Event"),
                    h("Site"),
                    h("Date"),
                    h("Round"),
                    h("ECO"),
                    game.mainline_sans().len() as i64,
                    game.write_pgn(),
                    id,
                ],
            )
            .map_err(db_err)?;
        if updated == 0 {
            return Err(db_err(format!("no game with id {id}")));
        }
        tx.execute("DELETE FROM positions WHERE game_id = ?1", [id])
            .map_err(db_err)?;
        index_positions(&tx, id, &game, result_code(&result))?;
        tx.commit().map_err(db_err)
    }

    /// Canonical PGN of one stored game (feed to `Game::from_pgn`).
    pub fn game_pgn(&self, id: i64) -> Result<String, ChessError> {
        let conn = self.conn.lock().unwrap();
        conn.query_row("SELECT pgn FROM games WHERE id = ?1", [id], |r| r.get(0))
            .map_err(db_err)
    }

    /// Opening tree: moves played from `fen` across the database,
    /// with per-move W/D/L stats, most-played first.
    pub fn opening_tree(&self, fen: String) -> Result<Vec<TreeMove>, ChessError> {
        let zobrist = zobrist_of_fen(&fen)?;
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT move, result, count(*) FROM positions
                 WHERE zobrist = ?1 GROUP BY move, result",
            )
            .map_err(db_err)?;
        let mut moves: Vec<TreeMove> = Vec::new();
        let rows = stmt
            .query_map([zobrist], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?))
            })
            .map_err(db_err)?;
        for row in rows {
            let (san, result, count) = row.map_err(db_err)?;
            let entry = match moves.iter_mut().find(|m| m.san == san) {
                Some(e) => e,
                None => {
                    moves.push(TreeMove {
                        san,
                        games: 0,
                        white_wins: 0,
                        draws: 0,
                        black_wins: 0,
                    });
                    moves.last_mut().unwrap()
                }
            };
            let count = count as u32;
            entry.games += count;
            match result {
                RESULT_WHITE => entry.white_wins += count,
                RESULT_DRAW => entry.draws += count,
                RESULT_BLACK => entry.black_wins += count,
                _ => {}
            }
        }
        moves.sort_by(|a, b| b.games.cmp(&a.games));
        Ok(moves)
    }
}

fn zobrist_of_fen(fen: &str) -> Result<i64, ChessError> {
    let fen: Fen = fen.parse().map_err(|e| ChessError::InvalidFen {
        reason: format!("{e}"),
    })?;
    let pos: Chess = fen
        .into_position(CastlingMode::Standard)
        .map_err(|e| ChessError::InvalidFen {
            reason: format!("{e}"),
        })?;
    Ok(zobrist_of(&pos))
}

fn zobrist_of(pos: &Chess) -> i64 {
    let h: Zobrist64 = pos.zobrist_hash(EnPassantMode::Legal);
    h.0 as i64
}

fn result_code(result: &str) -> i64 {
    match result {
        "1-0" => RESULT_WHITE,
        "1/2-1/2" => RESULT_DRAW,
        "0-1" => RESULT_BLACK,
        _ => RESULT_UNKNOWN,
    }
}

fn header(game: &crate::game::GameInner, key: &str) -> String {
    game.headers
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.clone())
        .unwrap_or_default()
}

fn insert_game(tx: &rusqlite::Transaction, game: &crate::game::GameInner) -> Result<i64, ChessError> {
    let h = |key: &str| header(game, key);
    let elo = |key: &str| -> Option<u32> { h(key).parse().ok() };
    let result = h("Result");
    tx.execute(
        "INSERT INTO games (white, black, white_elo, black_elo, result, event, site, date, round, eco, ply_count, pgn)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![
            h("White"),
            h("Black"),
            elo("WhiteElo"),
            elo("BlackElo"),
            if result.is_empty() { "*".into() } else { result.clone() },
            h("Event"),
            h("Site"),
            h("Date"),
            h("Round"),
            h("ECO"),
            game.mainline_sans().len() as i64,
            game.write_pgn(),
        ],
    )
    .map_err(db_err)?;
    let id = tx.last_insert_rowid();
    index_positions(tx, id, game, result_code(&result))?;
    Ok(id)
}

/// (Re)writes a game's opening-tree index rows; the caller has already
/// removed any stale ones.
fn index_positions(
    tx: &rusqlite::Transaction,
    game_id: i64,
    game: &crate::game::GameInner,
    rcode: i64,
) -> Result<(), ChessError> {
    // only games from the standard starting position are indexed
    if game.root_fen != START_FEN {
        return Ok(());
    }
    let mut pos = Chess::default();
    let mut stmt = tx
        .prepare_cached("INSERT INTO positions (zobrist, game_id, move, result) VALUES (?1, ?2, ?3, ?4)")
        .map_err(db_err)?;
    for san in game.mainline_sans().iter().take(TREE_MAX_PLY) {
        let parsed: San = match san.parse() {
            Ok(s) => s,
            Err(_) => break,
        };
        let m = match parsed.to_move(&pos) {
            Ok(m) => m,
            Err(_) => break, // corrupt movetext: keep the game, stop indexing
        };
        stmt.execute(params![zobrist_of(&pos), game_id, san, rcode])
            .map_err(db_err)?;
        pos.play_unchecked(&m);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const TWO_GAMES: &str = "\
[Event \"A\"]\n[White \"Alice\"]\n[Black \"Bob\"]\n[Result \"1-0\"]\n[WhiteElo \"1500\"]\n[Round \"2\"]\n\n1. e4 e5 2. Nf3 Nc6 1-0\n\n\
[Event \"B\"]\n[White \"Carol\"]\n[Black \"Dan\"]\n[Result \"0-1\"]\n\n1. e4 c5 2. Nf3 d6 0-1\n\n\
[Event \"C\"]\n[White \"Erin\"]\n[Black \"Frank\"]\n[Result \"1/2-1/2\"]\n\n1. d4 d5 1/2-1/2\n";

    fn unique() -> u32 {
        use std::sync::atomic::{AtomicU32, Ordering};
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        COUNTER.fetch_add(1, Ordering::Relaxed)
    }

    fn temp_db() -> (Database, std::path::PathBuf) {
        let path = std::env::temp_dir().join(format!(
            "dcstudio-test-{}-{}.db",
            std::process::id(),
            unique()
        ));
        let _ = std::fs::remove_file(&path);
        (Database::open(path.to_string_lossy().into()).unwrap(), path)
    }

    fn import_str(db: &Database, pgn: &str) -> ImportStats {
        let path = std::env::temp_dir().join(format!(
            "dcstudio-test-{}-{}.pgn",
            std::process::id(),
            unique()
        ));
        std::fs::write(&path, pgn).unwrap();
        let stats = db.import_pgn_file(path.to_string_lossy().into()).unwrap();
        let _ = std::fs::remove_file(&path);
        stats
    }

    #[test]
    fn imports_lists_and_reloads() {
        let (db, path) = temp_db();
        let stats = import_str(&db, TWO_GAMES);
        assert_eq!((stats.imported, stats.skipped), (3, 0));
        assert_eq!(db.game_count().unwrap(), 3);

        let games = db.list_games(0, 10, GameSort::White, true).unwrap();
        assert_eq!(games.len(), 3);
        assert_eq!(games[0].white, "Alice");
        assert_eq!(games[0].white_elo, Some(1500));
        assert_eq!(games[0].round, "2");
        assert_eq!(games[0].ply_count, 4);

        // stored canonical PGN parses back into the same game
        let pgn = db.game_pgn(games[0].id).unwrap();
        let game = crate::Game::from_pgn(pgn).unwrap();
        assert_eq!(game.mainline().len(), 4);
        assert_eq!(game.header("Result".into()).as_deref(), Some("1-0"));

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn opening_tree_aggregates() {
        let (db, path) = temp_db();
        import_str(&db, TWO_GAMES);

        let tree = db.opening_tree(START_FEN.into()).unwrap();
        assert_eq!(tree.len(), 2);
        assert_eq!(tree[0].san, "e4");
        assert_eq!(tree[0].games, 2);
        assert_eq!(tree[0].white_wins, 1);
        assert_eq!(tree[0].black_wins, 1);
        assert_eq!(tree[1].san, "d4");
        assert_eq!(tree[1].draws, 1);

        // after 1. e4: one e5, one c5
        let after_e4 = crate::apply_san(START_FEN.into(), "e4".into()).unwrap();
        let tree = db.opening_tree(after_e4).unwrap();
        let sans: Vec<&str> = tree.iter().map(|m| m.san.as_str()).collect();
        assert_eq!(sans.len(), 2);
        assert!(sans.contains(&"e5") && sans.contains(&"c5"));

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn search_and_delete() {
        let (db, path) = temp_db();
        import_str(&db, TWO_GAMES);

        // case-insensitive, matches white/black/event
        assert_eq!(db.search_games_count("alice".into()).unwrap(), 1);
        assert_eq!(db.search_games_count("aro".into()).unwrap(), 1); // C-arol
        let hits = db
            .search_games("B".into(), 0, 10, GameSort::Number, true)
            .unwrap(); // Bob (black) + event "B"
        assert_eq!(hits.len(), 2);

        // delete: row + tree index gone, other ids untouched
        let id = db
            .search_games("Alice".into(), 0, 1, GameSort::Number, true)
            .unwrap()[0]
            .id;
        db.delete_game(id).unwrap();
        assert_eq!(db.game_count().unwrap(), 2);
        assert_eq!(db.search_games_count("Alice".into()).unwrap(), 0);
        let tree = db.opening_tree(START_FEN.into()).unwrap();
        let e4 = tree.iter().find(|m| m.san == "e4").unwrap();
        assert_eq!(e4.games, 1); // Alice's e4 game no longer counted
        assert!(db.delete_game(id).is_err());

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn games_at_position_filters_by_reach() {
        let (db, path) = temp_db();
        import_str(&db, TWO_GAMES);

        let after_e4 = crate::apply_san(START_FEN.into(), "e4".into()).unwrap();
        assert_eq!(db.games_at_position_count(after_e4.clone()).unwrap(), 2);
        let games = db
            .games_at_position(after_e4, 0, 10, GameSort::Number, true)
            .unwrap();
        assert_eq!(games.len(), 2);
        assert!(games.iter().all(|g| g.white == "Alice" || g.white == "Carol"));

        // everyone reaches the start position
        assert_eq!(db.games_at_position_count(START_FEN.into()).unwrap(), 3);

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn add_game_and_write_back_round_trip() {
        let (db, path) = temp_db();
        import_str(&db, TWO_GAMES);

        let id = db
            .add_game("[White \"New\"]\n[Black \"Entry\"]\n[Result \"*\"]\n\n1. e4 c5 *\n".into())
            .unwrap();
        assert_eq!(id, 4); // appended after the three imported games
        assert_eq!(db.game_count().unwrap(), 4);

        // write-back: the regenerated file reimports identically
        let out = std::env::temp_dir().join(format!(
            "dcstudio-test-out-{}-{}.pgn",
            std::process::id(),
            unique()
        ));
        db.write_pgn_file(out.to_string_lossy().into()).unwrap();
        let (db2, path2) = temp_db();
        let stats = db2
            .import_pgn_file(out.to_string_lossy().into())
            .unwrap();
        assert_eq!((stats.imported, stats.skipped), (4, 0));
        let games = db2.list_games(0, 10, GameSort::Number, true).unwrap();
        assert_eq!(games[3].white, "New");
        assert_eq!(games[0].round, "2"); // headers survive the round trip

        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(path2);
        let _ = std::fs::remove_file(out);
    }

    #[test]
    fn clear_all_resets_ids_and_tree() {
        let (db, path) = temp_db();
        import_str(&db, TWO_GAMES);
        db.clear_all().unwrap();
        assert_eq!(db.game_count().unwrap(), 0);
        assert!(db.opening_tree(START_FEN.into()).unwrap().is_empty());

        // ids restart at 1, and Number sort is import order
        import_str(&db, TWO_GAMES);
        let games = db.list_games(0, 10, GameSort::Number, true).unwrap();
        assert_eq!(games.len(), 3);
        assert_eq!(games[0].id, 1);
        assert_eq!(games[0].white, "Alice"); // first game in the file
        assert_eq!(games[2].id, 3);

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn update_game_rewrites_row_and_tree_index() {
        let (db, path) = temp_db();
        import_str(&db, TWO_GAMES);
        let games = db.list_games(0, 10, GameSort::White, true).unwrap();
        let id = games[0].id; // Alice's 1. e4 game

        // extend the game and flip the result, then write it back
        let extended = "[Event \"A2\"]\n[White \"Alice\"]\n[Black \"Bob\"]\n[Result \"0-1\"]\n\n\
                        1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 0-1\n";
        db.update_game(id, extended.into()).unwrap();

        assert_eq!(db.game_count().unwrap(), 3); // updated, not appended
        let games = db.list_games(0, 10, GameSort::White, true).unwrap();
        let row = games.iter().find(|g| g.id == id).unwrap();
        assert_eq!((row.event.as_str(), row.result.as_str(), row.ply_count), ("A2", "0-1", 6));

        // stored PGN round-trips with the new mainline
        let game = crate::Game::from_pgn(db.game_pgn(id).unwrap()).unwrap();
        assert_eq!(game.mainline().len(), 6);

        // tree index rebuilt: 1.e4 now shows Alice's game as a black win
        let tree = db.opening_tree(START_FEN.into()).unwrap();
        let e4 = tree.iter().find(|m| m.san == "e4").unwrap();
        assert_eq!((e4.games, e4.white_wins, e4.black_wins), (2, 0, 2));

        // unknown id is an error, and nothing is clobbered
        assert!(db.update_game(9999, extended.into()).is_err());
        assert_eq!(db.game_count().unwrap(), 3);

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn fixture_file_imports() {
        let (db, path) = temp_db();
        let stats = db
            .import_pgn_file(
                concat!(env!("CARGO_MANIFEST_DIR"), "/../fixtures/opera_annotated.pgn").into(),
            )
            .unwrap();
        assert!(stats.imported >= 1);
        assert_eq!(stats.skipped, 0);
        let _ = std::fs::remove_file(path);
    }
}
